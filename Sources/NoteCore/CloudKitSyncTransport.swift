import CloudKit
import Foundation

public enum CloudKitSyncTransportError: Error, Equatable, LocalizedError {
    case accountUnavailable
    case corruptState
    case invalidRemoteRecord
    case unexpectedDeletion
    case uploadNotAcknowledged

    public var errorDescription: String? {
        switch self {
        case .accountUnavailable: "An iCloud account is required for sync."
        case .corruptState: "The saved CloudKit sync state is corrupt."
        case .invalidRemoteRecord: "CloudKit returned an invalid snapshot."
        case .unexpectedDeletion:
            "A remote snapshot was deleted. Sync is paused to preserve history."
        case .uploadNotAcknowledged:
            "CloudKit did not acknowledge the requested snapshot."
        }
    }
}

struct CloudKitTransportState: Codable, Equatable {
    var accountRecordName: String
    var inboxGeneration: UUID
    var engineState: Data?
    var inbox: [SyncRecord]
    var outbox: [String: SyncRecord]
    var hasUnexpectedDeletion: Bool

    init(accountRecordName: String) {
        self.accountRecordName = accountRecordName
        inboxGeneration = UUID()
        engineState = nil
        inbox = []
        outbox = [:]
        hasUnexpectedDeletion = false
    }

    mutating func appendToInbox(_ record: SyncRecord) throws {
        try record.validate()
        guard !inbox.contains(where: { $0.id == record.id }) else { return }
        inbox.append(record)
    }

    func page(after cursor: String?, limit: Int) throws -> SyncPage {
        let offset: Int
        if let cursor {
            let prefix = "v2:\(inboxGeneration.uuidString):"
            guard cursor.hasPrefix(prefix),
                  let parsed = Int(cursor.dropFirst(prefix.count)),
                  parsed >= 0, parsed <= inbox.count else {
                throw SyncError.invalidCursor
            }
            offset = parsed
        } else {
            offset = 0
        }
        let end = min(offset + max(1, limit), inbox.count)
        return SyncPage(
            records: Array(inbox[offset..<end]),
            cursor: "v2:\(inboxGeneration.uuidString):\(end)",
            hasMore: end < inbox.count
        )
    }
}

actor CloudKitTransportStateStore {
    private let fileURL: URL
    private var state: CloudKitTransportState

    init(directory: URL, accountRecordName: String) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        fileURL = directory.appendingPathComponent("cloudkit-sync-state.json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                state = try JSONDecoder().decode(
                    CloudKitTransportState.self,
                    from: Data(contentsOf: fileURL)
                )
            } catch {
                throw CloudKitSyncTransportError.corruptState
            }
            do {
                for record in state.inbox { try record.validate() }
                for record in state.outbox.values { try record.validate() }
            } catch {
                throw CloudKitSyncTransportError.corruptState
            }
            guard state.accountRecordName == accountRecordName else {
                throw SyncError.scopeChanged
            }
        } else {
            state = CloudKitTransportState(
                accountRecordName: accountRecordName
            )
            try Self.write(state, to: fileURL)
        }
    }

    func snapshot() -> CloudKitTransportState { state }

    func update(_ body: (inout CloudKitTransportState) throws -> Void) throws {
        var next = state
        try body(&next)
        try Self.write(next, to: fileURL)
        state = next
    }

    private static func write(
        _ state: CloudKitTransportState, to destination: URL
    ) throws {
        try SyncFileIO.replace(JSONEncoder().encode(state), at: destination)
    }
}

actor CloudKitEventCommitter {
    private let store: CloudKitTransportStateStore
    private(set) var failure: Error?

    init(store: CloudKitTransportStateStore) { self.store = store }

    func commitFetched(_ records: [SyncRecord]) async throws {
        guard failure == nil else { throw failure! }
        do {
            try await store.update { state in
                for record in records { try state.appendToInbox(record) }
            }
        } catch {
            failure = error
            throw error
        }
    }

    func commitEngineState(_ data: Data) async throws {
        guard failure == nil else { throw failure! }
        do {
            try await store.update { $0.engineState = data }
        } catch {
            failure = error
            throw error
        }
    }
}

enum CloudKitRemoteRecordValidator {
    static let maximumAssetSize = 64 * 1024 * 1024

    static func validateSnapshotID(_ id: String) throws {
        guard id.count == 64,
              id.utf8.allSatisfy({
                  ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
              }) else {
            throw CloudKitSyncTransportError.invalidRemoteRecord
        }
    }
}

struct CloudKitAssetStaging {
    let directory: URL
    private var users: [URL: Int] = [:]
    private var completedUploads = Set<URL>()

    mutating func retain(_ record: SyncRecord) throws -> URL {
        let url = directory.appendingPathComponent(record.id)
        try record.snapshot.data.write(to: url, options: .atomic)
        users[url, default: 0] += 1
        return url
    }

    mutating func release(_ url: URL, uploadCompleted: Bool) {
        guard let count = users[url] else { return }
        if uploadCompleted { completedUploads.insert(url) }
        if count > 1 {
            users[url] = count - 1
            return
        }
        users[url] = nil
        guard completedUploads.remove(url) != nil else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

@available(macOS 14.0, iOS 17.0, *)
public final actor CloudKitSyncTransport: SyncTransport {
    public nonisolated let scope: String

    private static let recordType = "AutomergeSnapshotV1"
    private static let zoneName = "meh-md-sync-v1"
    private static let bootstrapName = "canonical-seed-v1"
    private static let pageSize = 100

    private let container: CKContainer
    private let database: CKDatabase
    private let expectedUserRecordID: CKRecord.ID
    private let zoneID: CKRecordZone.ID
    private let store: CloudKitTransportStateStore
    private let eventCommitter: CloudKitEventCommitter
    private let assetDirectory: URL
    private var assetStaging: CloudKitAssetStaging
    private var engine: CKSyncEngine!
    private var acknowledgedIDs = Set<String>()
    private var failedUploads: [String: Error] = [:]
    private var delegateFailure: Error?

    public static func make(
        containerIdentifier: String,
        stateDirectory: URL
    ) async throws -> CloudKitSyncTransport {
        let container = CKContainer(identifier: containerIdentifier)
        guard try await container.accountStatus() == .available else {
            throw CloudKitSyncTransportError.accountUnavailable
        }
        let userRecordID = try await container.userRecordID()
        let store = try CloudKitTransportStateStore(
            directory: stateDirectory,
            accountRecordName: userRecordID.recordName
        )
        let transport = CloudKitSyncTransport(
            containerIdentifier: containerIdentifier,
            container: container,
            userRecordID: userRecordID,
            stateDirectory: stateDirectory,
            store: store
        )
        try await transport.initialize()
        return transport
    }

    private init(
        containerIdentifier: String,
        container: CKContainer,
        userRecordID: CKRecord.ID,
        stateDirectory: URL,
        store: CloudKitTransportStateStore
    ) {
        self.container = container
        database = container.privateCloudDatabase
        expectedUserRecordID = userRecordID
        zoneID = CKRecordZone.ID(zoneName: Self.zoneName)
        self.store = store
        eventCommitter = CloudKitEventCommitter(store: store)
        assetDirectory = stateDirectory.appendingPathComponent("assets")
        assetStaging = CloudKitAssetStaging(directory: assetDirectory)
        scope = "\(containerIdentifier)/private/\(userRecordID.recordName)"
    }

    private func initialize() async throws {
        try FileManager.default.createDirectory(
            at: assetDirectory, withIntermediateDirectories: true
        )
        let saved = await store.snapshot()
        let serialization: CKSyncEngine.State.Serialization?
        if let data = saved.engineState {
            do {
                serialization = try JSONDecoder().decode(
                    CKSyncEngine.State.Serialization.self, from: data
                )
            } catch {
                throw CloudKitSyncTransportError.corruptState
            }
        } else {
            serialization = nil
        }
        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: serialization,
            delegate: self
        )
        configuration.automaticallySync = false
        engine = CKSyncEngine(configuration)
    }

    public func bootstrap(proposing record: SyncRecord) async throws -> SyncRecord {
        try await assertHealthy()
        try await verifyAccount()
        try record.validate()
        try await ensureZone()
        let recordID = CKRecord.ID(
            recordName: Self.bootstrapName, zoneID: zoneID
        )
        do {
            let existing = try await database.record(for: recordID)
            let canonical = try decode(existing)
            try await store.update { try $0.appendToInbox(canonical) }
            return canonical
        } catch let error as CKError where error.code == .unknownItem {
            let assetURL = try assetStaging.retain(record)
            var uploadCompleted = false
            defer {
                assetStaging.release(
                    assetURL, uploadCompleted: uploadCompleted
                )
            }
            let cloudRecord = try makeCloudRecord(
                record, id: recordID, assetURL: assetURL
            )
            do {
                _ = try await database.save(cloudRecord)
                try await store.update { try $0.appendToInbox(record) }
                uploadCompleted = true
                return record
            } catch let conflict as CKError
                where conflict.code == .serverRecordChanged {
                guard let server = conflict.serverRecord else { throw conflict }
                let canonical = try decode(server)
                try await store.update { try $0.appendToInbox(canonical) }
                uploadCompleted = true
                return canonical
            }
        }
    }

    public func publish(_ record: SyncRecord) async throws {
        try await assertHealthy()
        try await verifyAccount()
        try record.validate()
        let recordID = CKRecord.ID(recordName: record.id, zoneID: zoneID)
        try await store.update { $0.outbox[record.id] = record }
        let assetURL = try assetStaging.retain(record)
        var uploadCompleted = false
        defer {
            assetStaging.release(
                assetURL, uploadCompleted: uploadCompleted
            )
        }
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        acknowledgedIDs.remove(record.id)
        failedUploads[record.id] = nil
        try await engine.sendChanges(
            .init(scope: .recordIDs([recordID]))
        )
        if let delegateFailure {
            throw delegateFailure
        }
        if let failure = failedUploads.removeValue(forKey: record.id) {
            throw failure
        }
        guard acknowledgedIDs.remove(record.id) != nil else {
            throw CloudKitSyncTransportError.uploadNotAcknowledged
        }
        uploadCompleted = true
    }

    public func fetch(after cursor: String?) async throws -> SyncPage {
        try await assertHealthy()
        try await verifyAccount()
        try await engine.fetchChanges(.init(scope: .zoneIDs([zoneID])))
        if let delegateFailure {
            throw delegateFailure
        }
        let state = await store.snapshot()
        guard !state.hasUnexpectedDeletion else {
            throw CloudKitSyncTransportError.unexpectedDeletion
        }
        return try state.page(after: cursor, limit: Self.pageSize)
    }

    private func verifyAccount() async throws {
        guard try await container.accountStatus() == .available,
              try await container.userRecordID() == expectedUserRecordID else {
            throw SyncError.scopeChanged
        }
    }

    private func assertHealthy() async throws {
        if let delegateFailure { throw delegateFailure }
        guard !(await store.snapshot().hasUnexpectedDeletion) else {
            throw CloudKitSyncTransportError.unexpectedDeletion
        }
    }

    private func ensureZone() async throws {
        let result = try await database.recordZones(for: [zoneID])
        guard let zoneResult = result[zoneID] else {
            throw CloudKitSyncTransportError.invalidRemoteRecord
        }
        switch zoneResult {
        case .success:
            return
        case let .failure(error):
            guard let cloudError = error as? CKError,
                  cloudError.code == .unknownItem
                    || cloudError.code == .zoneNotFound else {
                throw error
            }
        }
        let saved = try await database.modifyRecordZones(
            saving: [CKRecordZone(zoneID: zoneID)], deleting: []
        ).saveResults[zoneID]
        guard let saved else {
            throw CloudKitSyncTransportError.invalidRemoteRecord
        }
        _ = try saved.get()
    }

    private func makeCloudRecord(
        _ value: SyncRecord, id: CKRecord.ID, assetURL: URL
    ) throws -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: id)
        record["snapshotID"] = value.id
        record["noteID"] = value.snapshot.noteID.uuidString
        record["heads"] = try JSONEncoder().encode(value.snapshot.heads)
        record["document"] = CKAsset(fileURL: assetURL)
        return record
    }

    private func decode(_ record: CKRecord) throws -> SyncRecord {
        guard record.recordType == Self.recordType,
              let id: String = record["snapshotID"],
              let noteIDString: String = record["noteID"],
              let noteID = UUID(uuidString: noteIDString),
              let headsData: Data = record["heads"],
              let asset: CKAsset = record["document"],
              let source = asset.fileURL else {
            throw CloudKitSyncTransportError.invalidRemoteRecord
        }
        try CloudKitRemoteRecordValidator.validateSnapshotID(id)
        guard record.recordID.zoneID == zoneID,
              record.recordID.recordName == id
                || record.recordID.recordName == Self.bootstrapName else {
            throw CloudKitSyncTransportError.invalidRemoteRecord
        }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: source.path
        )
        guard let size = attributes[.size] as? NSNumber,
              size.intValue <= CloudKitRemoteRecordValidator.maximumAssetSize
        else { throw CloudKitSyncTransportError.invalidRemoteRecord }
        let snapshot = NoteSnapshot(
            data: try Data(contentsOf: source),
            heads: try JSONDecoder().decode(Set<String>.self, from: headsData),
            noteID: noteID
        )
        let value = SyncRecord(snapshot: snapshot)
        guard value.id == id else {
            throw CloudKitSyncTransportError.invalidRemoteRecord
        }
        try value.validate()
        return value
    }
}

@available(macOS 14.0, iOS 17.0, *)
extension CloudKitSyncTransport: CKSyncEngineDelegate {
    public func handleEvent(
        _ event: CKSyncEngine.Event, syncEngine: CKSyncEngine
    ) async {
        do {
            switch event {
            case let .stateUpdate(update):
                guard delegateFailure == nil else { return }
                let data = try JSONEncoder().encode(update.stateSerialization)
                try await eventCommitter.commitEngineState(data)
            case let .fetchedRecordZoneChanges(changes):
                guard changes.deletions.isEmpty else {
                    try await store.update { $0.hasUnexpectedDeletion = true }
                    return
                }
                let records = try changes.modifications.map { try decode($0.record) }
                try await eventCommitter.commitFetched(records)
            case let .sentRecordZoneChanges(changes):
                for record in changes.savedRecords {
                    let id = record.recordID.recordName
                    acknowledgedIDs.insert(id)
                    try await store.update { state in
                        if let value = state.outbox.removeValue(forKey: id) {
                            try state.appendToInbox(value)
                        }
                    }
                }
                for failure in changes.failedRecordSaves {
                    let id = failure.record.recordID.recordName
                    if failure.error.code == .serverRecordChanged,
                       let server = failure.error.serverRecord,
                       let value = try? decode(server), value.id == id {
                        acknowledgedIDs.insert(id)
                        try await store.update { state in
                            if let pending = state.outbox.removeValue(forKey: id) {
                                try state.appendToInbox(pending)
                            }
                        }
                    } else {
                        failedUploads[id] = failure.error
                    }
                }
            case .accountChange:
                delegateFailure = SyncError.scopeChanged
            case let .fetchedDatabaseChanges(changes):
                if changes.deletions.contains(where: { $0.zoneID == zoneID }) {
                    try await store.update { $0.hasUnexpectedDeletion = true }
                }
            default:
                break
            }
        } catch {
            delegateFailure = error
            if case let .sentRecordZoneChanges(changes) = event {
                for record in changes.savedRecords {
                    failedUploads[record.recordID.recordName] = error
                }
            }
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0)
        }
        let outbox = await store.snapshot().outbox
        return await CKSyncEngine.RecordZoneChangeBatch(
            pendingChanges: pending
        ) { [assetDirectory, zoneID] recordID in
            guard recordID.zoneID == zoneID,
                  let value = outbox[recordID.recordName] else { return nil }
            let assetURL = assetDirectory.appendingPathComponent(value.id)
            if !FileManager.default.fileExists(atPath: assetURL.path) {
                guard (try? value.snapshot.data.write(
                    to: assetURL, options: .atomic
                )) != nil else { return nil }
            }
            let record = CKRecord(recordType: Self.recordType, recordID: recordID)
            record["snapshotID"] = value.id
            record["noteID"] = value.snapshot.noteID.uuidString
            record["heads"] = try? JSONEncoder().encode(value.snapshot.heads)
            record["document"] = CKAsset(fileURL: assetURL)
            return record
        }
    }
}
