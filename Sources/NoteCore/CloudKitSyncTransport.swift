import CloudKit
import Foundation

public enum CloudKitSyncTransportError: Error, Equatable, LocalizedError {
    case accountUnavailable
    case corruptState
    case invalidRemoteRecord
    case unexpectedDeletion
    case uploadFailed(code: Int)
    case uploadNotAcknowledged

    public var errorDescription: String? {
        switch self {
        case .accountUnavailable: "An iCloud account is required for sync."
        case .corruptState: "The saved CloudKit sync state is corrupt."
        case .invalidRemoteRecord: "CloudKit returned an invalid snapshot."
        case .unexpectedDeletion:
            "A remote snapshot was deleted. Sync is paused to preserve history."
        case let .uploadFailed(code):
            "CloudKit upload failed (CKError code \(code))."
        case .uploadNotAcknowledged:
            "CloudKit did not acknowledge the requested snapshot."
        }
    }
}

struct CloudKitTransportState: Codable, Equatable {
    var accountRecordName: String
    var zoneName: String
    var protocolVersion: Int
    var inboxGeneration: UUID
    var engineState: Data?
    private var inboxSlots: [SyncRecord?]
    var outbox: [String: SyncRecord]
    var deletedNoteIDs: Set<UUID>
    var purgedRecordIDs: Set<String>
    var pendingRemoteDeletionIDs: Set<String>
    var scannedDeletedNoteIDs: Set<UUID>
    var unresolvedRemoteDeletionRecordIDs: Set<String>
    var hasUnexpectedDeletion: Bool
    var retryNotBefore: Date?

    init(
        accountRecordName: String,
        zoneName: String,
        protocolVersion: Int = 1
    ) {
        self.accountRecordName = accountRecordName
        self.zoneName = zoneName
        self.protocolVersion = protocolVersion
        inboxGeneration = UUID()
        engineState = nil
        inboxSlots = []
        outbox = [:]
        deletedNoteIDs = []
        purgedRecordIDs = []
        pendingRemoteDeletionIDs = []
        scannedDeletedNoteIDs = []
        unresolvedRemoteDeletionRecordIDs = []
        hasUnexpectedDeletion = false
        retryNotBefore = nil
    }

    private enum CodingKeys: String, CodingKey {
        case accountRecordName, zoneName, protocolVersion, inboxGeneration
        case engineState, inbox, outbox, deletedNoteIDs, purgedRecordIDs
        case pendingRemoteDeletionIDs, scannedDeletedNoteIDs
        case unresolvedRemoteDeletionRecordIDs
        case hasUnexpectedDeletion, retryNotBefore
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accountRecordName = try values.decode(String.self, forKey: .accountRecordName)
        zoneName = try values.decode(String.self, forKey: .zoneName)
        protocolVersion = try values.decodeIfPresent(
            Int.self, forKey: .protocolVersion
        ) ?? 1
        inboxGeneration = try values.decode(UUID.self, forKey: .inboxGeneration)
        engineState = try values.decodeIfPresent(Data.self, forKey: .engineState)
        inboxSlots = try values.decode([SyncRecord?].self, forKey: .inbox)
        outbox = try values.decode([String: SyncRecord].self, forKey: .outbox)
        deletedNoteIDs = try values.decodeIfPresent(
            Set<UUID>.self, forKey: .deletedNoteIDs
        ) ?? []
        purgedRecordIDs = try values.decodeIfPresent(
            Set<String>.self, forKey: .purgedRecordIDs
        ) ?? []
        pendingRemoteDeletionIDs = try values.decodeIfPresent(
            Set<String>.self, forKey: .pendingRemoteDeletionIDs
        ) ?? purgedRecordIDs
        scannedDeletedNoteIDs = try values.decodeIfPresent(
            Set<UUID>.self, forKey: .scannedDeletedNoteIDs
        ) ?? []
        unresolvedRemoteDeletionRecordIDs = try values.decodeIfPresent(
            Set<String>.self,
            forKey: .unresolvedRemoteDeletionRecordIDs
        ) ?? []
        hasUnexpectedDeletion = try values.decode(
            Bool.self, forKey: .hasUnexpectedDeletion
        )
        retryNotBefore = try values.decodeIfPresent(
            Date.self, forKey: .retryNotBefore
        )
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(accountRecordName, forKey: .accountRecordName)
        try values.encode(zoneName, forKey: .zoneName)
        try values.encode(protocolVersion, forKey: .protocolVersion)
        try values.encode(inboxGeneration, forKey: .inboxGeneration)
        try values.encodeIfPresent(engineState, forKey: .engineState)
        try values.encode(inboxSlots, forKey: .inbox)
        try values.encode(outbox, forKey: .outbox)
        try values.encode(deletedNoteIDs, forKey: .deletedNoteIDs)
        try values.encode(purgedRecordIDs, forKey: .purgedRecordIDs)
        try values.encode(
            pendingRemoteDeletionIDs,
            forKey: .pendingRemoteDeletionIDs
        )
        try values.encode(
            scannedDeletedNoteIDs, forKey: .scannedDeletedNoteIDs
        )
        try values.encode(
            unresolvedRemoteDeletionRecordIDs,
            forKey: .unresolvedRemoteDeletionRecordIDs
        )
        try values.encode(hasUnexpectedDeletion, forKey: .hasUnexpectedDeletion)
        try values.encodeIfPresent(retryNotBefore, forKey: .retryNotBefore)
    }

    var inbox: [SyncRecord] { inboxSlots.compactMap { $0 } }

    mutating func appendToInbox(_ record: SyncRecord) throws {
        try record.validate()
        guard record.protocolVersion == protocolVersion else {
            throw SyncError.invalidRecord
        }
        unresolvedRemoteDeletionRecordIDs.remove(record.id)
        if purgedRecordIDs.contains(record.id) {
            if record.protocolVersion == 2, record.kind == .note,
               deletedNoteIDs.contains(record.snapshot.noteID) {
                pendingRemoteDeletionIDs.insert(record.id)
            }
            return
        }
        guard !inboxSlots.contains(where: { $0?.id == record.id }) else {
            return
        }
        if record.protocolVersion == 2, record.kind == .note,
           deletedNoteIDs.contains(record.snapshot.noteID) {
            inboxSlots.append(nil)
            purgedRecordIDs.insert(record.id)
            pendingRemoteDeletionIDs.insert(record.id)
        } else {
            inboxSlots.append(record)
        }
    }

    mutating func purgeDeletedNotes(
        _ noteIDs: Set<UUID>, notebookID: UUID
    ) throws -> Set<String> {
        guard protocolVersion == 2 else {
            throw SyncError.unavailable(
                "Permanent body cleanup requires notebook sync."
            )
        }
        guard inbox.contains(where: {
            $0.kind == .catalog && $0.notebookID == notebookID
        }) else { throw SyncError.invalidRecord }
        for record in inbox where record.notebookID != notebookID {
            throw SyncError.invalidRecord
        }
        for record in outbox.values where record.notebookID != notebookID {
            throw SyncError.invalidRecord
        }
        deletedNoteIDs.formUnion(noteIDs)
        for index in inboxSlots.indices {
            guard let record = inboxSlots[index], record.kind == .note,
                  deletedNoteIDs.contains(record.snapshot.noteID) else {
                continue
            }
            purgedRecordIDs.insert(record.id)
            pendingRemoteDeletionIDs.insert(record.id)
            inboxSlots[index] = nil
        }
        let outboxIDsToRemove = outbox.values.compactMap { record in
            record.kind == .note
                && deletedNoteIDs.contains(record.snapshot.noteID)
                ? record.id : nil
        }
        for id in outboxIDsToRemove {
            purgedRecordIDs.insert(id)
            pendingRemoteDeletionIDs.insert(id)
            outbox[id] = nil
        }
        return pendingRemoteDeletionIDs
    }

    mutating func observeRemoteDeletions(
        _ recordNames: Set<String>, bootstrapRecordName: String
    ) {
        pendingRemoteDeletionIDs.subtract(recordNames)
        if protocolVersion == 1 {
            hasUnexpectedDeletion = hasUnexpectedDeletion
                || !recordNames.isEmpty
            return
        }
        let catalogRecordIDs = Set(inbox.lazy.filter {
            $0.kind == .catalog
        }.map(\.id))
        let knownNoteRecordIDs = Set(inbox.lazy.filter {
            $0.kind == .note
        }.map(\.id))
        let unexpectedNoteRecordIDs = recordNames
            .intersection(knownNoteRecordIDs)
            .subtracting(purgedRecordIDs)
        unresolvedRemoteDeletionRecordIDs.formUnion(
            unexpectedNoteRecordIDs
        )
        hasUnexpectedDeletion = hasUnexpectedDeletion
            || recordNames.contains(bootstrapRecordName)
            || !catalogRecordIDs.isDisjoint(with: recordNames)
    }

    mutating func resolveRemoteNoteDeletions() throws {
        unresolvedRemoteDeletionRecordIDs.subtract(purgedRecordIDs)
        guard !unresolvedRemoteDeletionRecordIDs.isEmpty else { return }
        let permanentlyDeletedIDs = try inbox.reduce(
            into: Set<UUID>()
        ) { result, record in
            guard record.kind == .catalog,
                  let snapshot = record.catalogSnapshot else { return }
            let catalog = try NotebookCatalogDocument(snapshot: snapshot)
            result.formUnion(try catalog.items().lazy.filter {
                $0.isPermanentlyDeleted
            }.map(\.id))
        }
        let resolvedRecordIDs = Set(inbox.lazy.filter { record in
            record.kind == .note
                && permanentlyDeletedIDs.contains(record.snapshot.noteID)
        }.map(\.id))
        unresolvedRemoteDeletionRecordIDs.subtract(resolvedRecordIDs)
    }

    func validateRemoteDeletions() throws {
        guard !hasUnexpectedDeletion,
              unresolvedRemoteDeletionRecordIDs.isEmpty else {
            throw CloudKitSyncTransportError.unexpectedDeletion
        }
    }

    func validate(expectedProtocolVersion: Int) throws {
        guard protocolVersion == expectedProtocolVersion else {
            throw SyncError.scopeChanged
        }
        for record in inbox {
            try record.validate()
            guard record.protocolVersion == protocolVersion else {
                throw SyncError.invalidRecord
            }
        }
        for (id, record) in outbox {
            try record.validate()
            guard id == record.id,
                  record.protocolVersion == protocolVersion else {
                throw SyncError.invalidRecord
            }
        }
        guard purgedRecordIDs.allSatisfy({ id in
            id.count == 64 && id.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
            }
        }) else { throw SyncError.invalidRecord }
        guard pendingRemoteDeletionIDs.isSubset(of: purgedRecordIDs),
              scannedDeletedNoteIDs.isSubset(of: deletedNoteIDs) else {
            throw SyncError.invalidRecord
        }
        try unresolvedRemoteDeletionRecordIDs.forEach {
            try CloudKitRemoteRecordValidator.validateSnapshotID($0)
        }
        guard !inbox.contains(where: {
            $0.kind == .note && deletedNoteIDs.contains($0.snapshot.noteID)
        }), !outbox.values.contains(where: {
            $0.kind == .note && deletedNoteIDs.contains($0.snapshot.noteID)
        }) else { throw SyncError.invalidRecord }
    }

    func page(after cursor: String?, limit: Int) throws -> SyncPage {
        let offset: Int
        if let cursor {
            let prefix = "v2:\(inboxGeneration.uuidString):"
            guard cursor.hasPrefix(prefix),
                  let parsed = Int(cursor.dropFirst(prefix.count)),
                  parsed >= 0, parsed <= inboxSlots.count else {
                throw SyncError.invalidCursor
            }
            offset = parsed
        } else {
            offset = 0
        }
        let end = min(offset + max(1, limit), inboxSlots.count)
        return SyncPage(
            records: inboxSlots[offset..<end].compactMap { $0 },
            cursor: "v2:\(inboxGeneration.uuidString):\(end)",
            hasMore: end < inboxSlots.count
        )
    }

    func bufferedPage(after cursor: String?, limit: Int) throws -> SyncPage? {
        let page = try page(after: cursor, limit: limit)
        guard !page.records.isEmpty || page.hasMore else { return nil }
        return SyncPage(
            records: page.records,
            cursor: page.cursor,
            hasMore: true
        )
    }
}

actor CloudKitTransportStateStore {
    private let fileURL: URL
    private let protocolVersion: Int
    private var state: CloudKitTransportState

    init(
        directory: URL,
        accountRecordName: String,
        zoneName: String,
        protocolVersion: Int = 1
    ) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        self.protocolVersion = protocolVersion
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
                try state.validate(expectedProtocolVersion: protocolVersion)
            } catch {
                if error as? SyncError == .scopeChanged { throw error }
                throw CloudKitSyncTransportError.corruptState
            }
            guard state.accountRecordName == accountRecordName,
                  state.zoneName == zoneName else {
                throw SyncError.scopeChanged
            }
        } else {
            state = CloudKitTransportState(
                accountRecordName: accountRecordName,
                zoneName: zoneName,
                protocolVersion: protocolVersion
            )
            try Self.write(state, to: fileURL)
        }
    }

    func snapshot() -> CloudKitTransportState { state }

    func update(_ body: (inout CloudKitTransportState) throws -> Void) throws {
        var next = state
        try body(&next)
        try next.validate(expectedProtocolVersion: protocolVersion)
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

    func commitSent(_ records: [CloudKitAcknowledgedRecord]) async throws {
        guard failure == nil else { throw failure! }
        do {
            try await store.update { state in
                for record in records {
                    let value = state.outbox.removeValue(
                        forKey: record.id
                    ) ?? record.record
                    try state.appendToInbox(value)
                }
            }
        } catch {
            failure = error
            throw error
        }
    }
}

struct CloudKitAcknowledgedRecord: Sendable {
    let id: String
    let record: SyncRecord
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

enum CloudKitTransportMode: Equatable, Sendable {
    case legacy
    case notebook

    var protocolVersion: Int { self == .legacy ? 1 : 2 }
    var zoneName: String {
        self == .legacy ? "meh-md-sync-v1" : "meh-md-notebook-v2"
    }
    var recordType: String {
        self == .legacy
            ? "AutomergeSnapshotV1"
            : "AutomergeNotebookSnapshotV2"
    }
    var bootstrapName: String {
        self == .legacy ? "canonical-seed-v1" : "canonical-notebook-v2"
    }

    func validate(zoneName: String) throws {
        switch self {
        case .legacy:
            guard zoneName != CloudKitTransportMode.notebook.zoneName else {
                throw SyncError.scopeChanged
            }
        case .notebook:
            guard zoneName == self.zoneName else {
                throw SyncError.scopeChanged
            }
        }
    }

    func validate(_ record: SyncRecord, bootstrap: Bool = false) throws {
        try record.validate()
        guard record.protocolVersion == protocolVersion else {
            throw SyncError.invalidRecord
        }
        if self == .notebook, bootstrap, record.kind != .catalog {
            throw SyncError.invalidRecord
        }
    }
}

struct CloudKitRecordCodec: @unchecked Sendable {
    let mode: CloudKitTransportMode
    let zoneID: CKRecordZone.ID

    func encode(
        _ value: SyncRecord,
        id: CKRecord.ID,
        assetURL: URL
    ) throws -> CKRecord {
        try mode.validate(
            value,
            bootstrap: id.recordName == mode.bootstrapName
        )
        guard id.zoneID == zoneID,
              id.recordName == value.id
                || id.recordName == mode.bootstrapName else {
            throw CloudKitSyncTransportError.invalidRemoteRecord
        }
        let record = CKRecord(recordType: mode.recordType, recordID: id)
        record["snapshotID"] = value.id
        if mode == .legacy {
            record["noteID"] = value.snapshot.noteID.uuidString
        } else {
            record["protocolVersion"] = NSNumber(value: value.protocolVersion)
            record["kind"] = value.kind.rawValue
            record["notebookID"] = value.notebookID?.uuidString
            record["documentID"] = value.snapshot.noteID.uuidString
        }
        record["heads"] = try JSONEncoder().encode(value.snapshot.heads)
        record["document"] = CKAsset(fileURL: assetURL)
        return record
    }

    func decode(_ record: CKRecord) throws -> SyncRecord {
        do {
            return try decodeRemoteRecord(record)
        } catch {
            throw CloudKitSyncTransportError.invalidRemoteRecord
        }
    }

    private func decodeRemoteRecord(_ record: CKRecord) throws -> SyncRecord {
        guard record.recordType == mode.recordType,
              record.recordID.zoneID == zoneID,
              let id: String = record["snapshotID"],
              let headsData: Data = record["heads"],
              let asset: CKAsset = record["document"],
              let source = asset.fileURL else {
            throw CloudKitSyncTransportError.invalidRemoteRecord
        }
        try CloudKitRemoteRecordValidator.validateSnapshotID(id)
        guard record.recordID.recordName == id
                || record.recordID.recordName == mode.bootstrapName else {
            throw CloudKitSyncTransportError.invalidRemoteRecord
        }
        let documentID: UUID
        let version: Int
        let kind: SyncDocumentKind
        let notebookID: UUID?
        switch mode {
        case .legacy:
            guard record["protocolVersion"] == nil,
                  record["kind"] == nil,
                  record["notebookID"] == nil,
                  record["documentID"] == nil,
                  let noteIDString: String = record["noteID"],
                  let noteID = UUID(uuidString: noteIDString) else {
                throw CloudKitSyncTransportError.invalidRemoteRecord
            }
            documentID = noteID
            version = 1
            kind = .note
            notebookID = nil
        case .notebook:
            guard record["noteID"] == nil,
                  let number: NSNumber = record["protocolVersion"],
                  number.intValue == 2,
                  number.doubleValue == 2,
                  let kindValue: String = record["kind"],
                  let decodedKind = SyncDocumentKind(rawValue: kindValue),
                  let notebookIDString: String = record["notebookID"],
                  let decodedNotebookID = UUID(uuidString: notebookIDString),
                  let documentIDString: String = record["documentID"],
                  let decodedDocumentID = UUID(uuidString: documentIDString)
            else { throw CloudKitSyncTransportError.invalidRemoteRecord }
            documentID = decodedDocumentID
            version = number.intValue
            kind = decodedKind
            notebookID = decodedNotebookID
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
            noteID: documentID
        )
        let value: SyncRecord
        if version == 1 {
            value = SyncRecord(snapshot: snapshot)
        } else if kind == .note, let notebookID {
            value = SyncRecord(snapshot: snapshot, notebookID: notebookID)
        } else if kind == .catalog, let notebookID,
                  snapshot.noteID == notebookID {
            value = SyncRecord(catalog: NotebookCatalogSnapshot(
                data: snapshot.data,
                heads: snapshot.heads,
                notebookID: notebookID
            ))
        } else {
            throw CloudKitSyncTransportError.invalidRemoteRecord
        }
        guard value.id == id else {
            throw CloudKitSyncTransportError.invalidRemoteRecord
        }
        do {
            try mode.validate(
                value,
                bootstrap: record.recordID.recordName == mode.bootstrapName
            )
        } catch {
            throw CloudKitSyncTransportError.invalidRemoteRecord
        }
        return value
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

    mutating func purge(recordIDs: Set<String>) throws {
        for id in recordIDs {
            let url = directory.appendingPathComponent(id)
            guard users[url] == nil else {
                throw SyncError.unavailable(
                    "A snapshot is still being staged for upload."
                )
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                continue
            }
            try FileManager.default.removeItem(at: url)
            completedUploads.remove(url)
        }
    }
}

struct CloudKitRetryThrottle {
    private(set) var notBefore: Date?

    init(notBefore: Date? = nil) { self.notBefore = notBefore }

    mutating func observe(retryAfter seconds: Double?, now: Date) -> Bool {
        guard let seconds, seconds.isFinite, seconds > 0 else { return false }
        return merge(notBefore: now.addingTimeInterval(seconds))
    }

    mutating func merge(notBefore proposed: Date) -> Bool {
        guard notBefore.map({ proposed > $0 }) ?? true else { return false }
        notBefore = proposed
        return true
    }

    func remaining(at now: Date) -> TimeInterval? {
        guard let notBefore else { return nil }
        let interval = notBefore.timeIntervalSince(now)
        return interval > 0 ? interval : nil
    }
}

struct CloudKitUploadBatch {
    let ids: Set<String>
    let recordIDs: [CKRecord.ID]

    init(records: [SyncRecord], zoneID: CKRecordZone.ID) {
        ids = Set(records.map(\.id))
        recordIDs = ids.map {
            CKRecord.ID(recordName: $0, zoneID: zoneID)
        }
    }
}

enum CloudKitBatchResultResolver {
    static func resolve(
        records: [SyncRecord],
        acknowledgedIDs: Set<String>,
        failures: [String: Error],
        delegateFailure: Error?,
        sendError: Error?
    ) -> SyncBatchResult {
        let requestedIDs = Set(records.map(\.id))
        let durableAcknowledgements = acknowledgedIDs.intersection(requestedIDs)
        var error = records.lazy.compactMap { failures[$0.id] }.first
        if error == nil { error = delegateFailure }
        if error == nil { error = sendError }
        if error == nil, durableAcknowledgements != requestedIDs {
            error = CloudKitSyncTransportError.uploadNotAcknowledged
        }
        return SyncBatchResult(
            acknowledgedIDs: durableAcknowledgements,
            error: error
        )
    }
}

enum CloudKitRetryMetadata {
    static let fallbackSeconds = 30.0

    static func seconds(in error: Error) -> Double? {
        guard let cloudError = error as? CKError else { return nil }
        var delays: [Double] = []
        if let value = cloudError.retryAfterSeconds,
           value.isFinite, value > 0 {
            delays.append(value)
        }
        if let partialErrors = cloudError.partialErrorsByItemID {
            delays += partialErrors.values.compactMap(seconds)
        }
        if delays.isEmpty,
           cloudError.code == .requestRateLimited
            || cloudError.code == .serviceUnavailable {
            return fallbackSeconds
        }
        return delays.max()
    }
}

struct CloudKitAvailabilityCooldownStore {
    private struct State: Codable { var retryNotBefore: Date? }

    private let fileURL: URL
    private(set) var throttle: CloudKitRetryThrottle

    init(directory: URL) throws {
        fileURL = directory.appendingPathComponent(
            "cloudkit-availability-retry.json"
        )
        do {
            let state = try JSONDecoder().decode(
                State.self, from: Data(contentsOf: fileURL)
            )
            throttle = CloudKitRetryThrottle(notBefore: state.retryNotBefore)
        } catch CocoaError.fileReadNoSuchFile {
            throttle = CloudKitRetryThrottle()
        } catch {
            throw CloudKitSyncTransportError.corruptState
        }
    }

    var notBefore: Date? { throttle.notBefore }

    func wait() async throws {
        try await wait(
            now: { Date() },
            sleep: { try await Task.sleep(for: .seconds($0)) }
        )
    }

    func wait(
        now: () -> Date,
        sleep: (TimeInterval) async throws -> Void
    ) async throws {
        while let remaining = throttle.remaining(at: now()) {
            try await sleep(remaining)
        }
    }

    mutating func observe(_ error: Error, now: Date = Date()) throws {
        try merge(
            retryAfter: CloudKitRetryMetadata.seconds(in: error), now: now
        )
    }

    mutating func merge(notBefore: Date?) throws {
        guard let notBefore, throttle.merge(notBefore: notBefore) else { return }
        try persist()
    }

    mutating func merge(retryAfter: Double?, now: Date) throws {
        guard throttle.observe(retryAfter: retryAfter, now: now) else { return }
        try persist()
    }

    private func persist() throws {
        try SyncFileIO.replace(
            JSONEncoder().encode(State(retryNotBefore: throttle.notBefore)),
            at: fileURL
        )
    }
}

@available(macOS 14.0, iOS 17.0, *)
public final actor CloudKitSyncTransport: SyncTransport {
    public nonisolated let scope: String

    private static let pageSize = 100

    private let container: CKContainer
    private let database: CKDatabase
    private let expectedUserRecordID: CKRecord.ID
    private let zoneID: CKRecordZone.ID
    private let mode: CloudKitTransportMode
    private let codec: CloudKitRecordCodec
    private let store: CloudKitTransportStateStore
    private let eventCommitter: CloudKitEventCommitter
    private let assetDirectory: URL
    private var assetStaging: CloudKitAssetStaging
    private var availabilityCooldown: CloudKitAvailabilityCooldownStore
    private var engine: CKSyncEngine!
    private var acknowledgedIDs = Set<String>()
    private var failedUploads: [String: Error] = [:]
    private var delegateFailure: Error?
    private var retryThrottle = CloudKitRetryThrottle()
    private var publishInProgress = false
    private var publishWaiters: [CheckedContinuation<Void, Never>] = []

    public static func persistedRetryNotBefore(
        stateDirectory: URL
    ) throws -> Date? {
        try CloudKitAvailabilityCooldownStore(
            directory: stateDirectory
        ).notBefore
    }

    public static func make(
        containerIdentifier: String,
        stateDirectory: URL,
        zoneName: String = "meh-md-sync-v1"
    ) async throws -> CloudKitSyncTransport {
        try await make(
            containerIdentifier: containerIdentifier,
            stateDirectory: stateDirectory,
            zoneName: zoneName,
            mode: .legacy
        )
    }

    public static func makeNotebook(
        containerIdentifier: String,
        stateDirectory: URL
    ) async throws -> CloudKitSyncTransport {
        try await make(
            containerIdentifier: containerIdentifier,
            stateDirectory: stateDirectory,
            zoneName: CloudKitTransportMode.notebook.zoneName,
            mode: .notebook
        )
    }

    private static func make(
        containerIdentifier: String,
        stateDirectory: URL,
        zoneName: String,
        mode: CloudKitTransportMode
    ) async throws -> CloudKitSyncTransport {
        try mode.validate(zoneName: zoneName)
        var availabilityCooldown = try CloudKitAvailabilityCooldownStore(
            directory: stateDirectory
        )
        try await availabilityCooldown.wait()
        let container = CKContainer(identifier: containerIdentifier)
        let accountStatus: CKAccountStatus
        do {
            accountStatus = try await container.accountStatus()
        } catch {
            try availabilityCooldown.observe(error)
            throw error
        }
        guard accountStatus == .available else {
            throw CloudKitSyncTransportError.accountUnavailable
        }
        let userRecordID: CKRecord.ID
        do {
            userRecordID = try await container.userRecordID()
        } catch {
            try availabilityCooldown.observe(error)
            throw error
        }
        let store = try CloudKitTransportStateStore(
            directory: stateDirectory,
            accountRecordName: userRecordID.recordName,
            zoneName: zoneName,
            protocolVersion: mode.protocolVersion
        )
        let transport = CloudKitSyncTransport(
            containerIdentifier: containerIdentifier,
            container: container,
            userRecordID: userRecordID,
            zoneName: zoneName,
            stateDirectory: stateDirectory,
            store: store,
            availabilityCooldown: availabilityCooldown,
            mode: mode
        )
        try await transport.initialize()
        return transport
    }

    private init(
        containerIdentifier: String,
        container: CKContainer,
        userRecordID: CKRecord.ID,
        zoneName: String,
        stateDirectory: URL,
        store: CloudKitTransportStateStore,
        availabilityCooldown: CloudKitAvailabilityCooldownStore,
        mode: CloudKitTransportMode
    ) {
        self.container = container
        database = container.privateCloudDatabase
        expectedUserRecordID = userRecordID
        let zoneID = CKRecordZone.ID(zoneName: zoneName)
        self.zoneID = zoneID
        self.mode = mode
        codec = CloudKitRecordCodec(mode: mode, zoneID: zoneID)
        self.store = store
        eventCommitter = CloudKitEventCommitter(store: store)
        assetDirectory = stateDirectory.appendingPathComponent("assets")
        assetStaging = CloudKitAssetStaging(directory: assetDirectory)
        self.availabilityCooldown = availabilityCooldown
        scope = "\(containerIdentifier)/private/\(userRecordID.recordName)/\(zoneName)"
    }

    private func initialize() async throws {
        try FileManager.default.createDirectory(
            at: assetDirectory, withIntermediateDirectories: true
        )
        let saved = await store.snapshot()
        let deadline = [saved.retryNotBefore, availabilityCooldown.notBefore]
            .compactMap { $0 }.max()
        retryThrottle = CloudKitRetryThrottle(notBefore: deadline)
        try availabilityCooldown.merge(notBefore: deadline)
        if saved.retryNotBefore != deadline {
            try await store.update { $0.retryNotBefore = deadline }
        }
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
        try mode.validate(record, bootstrap: true)
        try await verifyAccount()
        try await ensureZone()
        let recordID = CKRecord.ID(
            recordName: mode.bootstrapName, zoneID: zoneID
        )
        do {
            let existing = try await cloudRequest {
                try await database.record(for: recordID)
            }
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
                _ = try await cloudRequest {
                    try await database.save(cloudRecord)
                }
                try await store.update { try $0.appendToInbox(record) }
                uploadCompleted = true
                return record
            } catch let conflict as CKError
                where conflict.code == .serverRecordChanged {
                await observeRetryAfter(conflict)
                let server = try await cloudRequest {
                    try await database.record(for: recordID)
                }
                let canonical = try decode(server)
                try await store.update { try $0.appendToInbox(canonical) }
                uploadCompleted = true
                return canonical
            }
        }
    }

    public func publish(_ record: SyncRecord) async throws {
        let result = try await publishBatch([record])
        if let error = result.error { throw error }
        guard result.acknowledgedIDs == [record.id] else {
            throw CloudKitSyncTransportError.uploadNotAcknowledged
        }
    }

    public func publishBatch(
        _ records: [SyncRecord]
    ) async throws -> SyncBatchResult {
        guard !records.isEmpty else {
            return SyncBatchResult(acknowledgedIDs: [], error: nil)
        }
        await acquirePublishLease()
        defer { releasePublishLease() }
        try await assertHealthy()
        for record in records { try mode.validate(record) }
        try await verifyAccount()
        let deletedNoteIDs = await store.snapshot().deletedNoteIDs
        let suppressedIDs = Set(records.compactMap { record in
            record.kind == .note
                && deletedNoteIDs.contains(record.snapshot.noteID)
                ? record.id : nil
        })
        let records = records.filter { !suppressedIDs.contains($0.id) }
        guard !records.isEmpty else {
            return SyncBatchResult(
                acknowledgedIDs: suppressedIDs, error: nil
            )
        }
        try await store.update { state in
            for record in records { state.outbox[record.id] = record }
        }

        var stagedAssets: [String: URL] = [:]
        var completedIDs = Set<String>()
        defer {
            for (id, assetURL) in stagedAssets {
                assetStaging.release(
                    assetURL,
                    uploadCompleted: completedIDs.contains(id)
                )
            }
        }
        for record in records {
            if stagedAssets[record.id] == nil {
                stagedAssets[record.id] = try assetStaging.retain(record)
            }
        }

        let batch = CloudKitUploadBatch(records: records, zoneID: zoneID)
        let ids = batch.ids
        let recordIDs = batch.recordIDs
        engine.state.add(
            pendingRecordZoneChanges: recordIDs.map { .saveRecord($0) }
        )
        acknowledgedIDs.subtract(ids)
        for id in ids { failedUploads[id] = nil }
        let sendError: Error?
        do {
            try await cloudRequest {
                try await engine.sendChanges(
                    .init(scope: .recordIDs(recordIDs))
                )
            }
            sendError = nil
        } catch {
            sendError = error
        }
        let result = CloudKitBatchResultResolver.resolve(
            records: records,
            acknowledgedIDs: acknowledgedIDs,
            failures: failedUploads,
            delegateFailure: delegateFailure,
            sendError: sendError
        )
        completedIDs = result.acknowledgedIDs
        acknowledgedIDs.subtract(ids)
        for id in ids { failedUploads[id] = nil }
        return SyncBatchResult(
            acknowledgedIDs: result.acknowledgedIDs.union(suppressedIDs),
            error: result.error
        )
    }

    public func fetch(after cursor: String?) async throws -> SyncPage {
        try await assertHealthy()
        try await verifyAccount()
        let current = await store.snapshot()
        if current.unresolvedRemoteDeletionRecordIDs.isEmpty {
            if let buffered = try current.bufferedPage(
                after: cursor,
                limit: Self.pageSize
            ) {
                return buffered
            }
        }
        try await cloudRequest {
            try await engine.fetchChanges(.init(scope: .zoneIDs([zoneID])))
        }
        if let delegateFailure {
            throw delegateFailure
        }
        let fetched = await store.snapshot()
        if !fetched.unresolvedRemoteDeletionRecordIDs.isEmpty {
            try await store.update {
                try $0.resolveRemoteNoteDeletions()
            }
        }
        let state = await store.snapshot()
        try state.validateRemoteDeletions()
        return try state.page(after: cursor, limit: Self.pageSize)
    }

    public func purgeDeletedNotes(
        _ noteIDs: Set<UUID>, notebookID: UUID
    ) async throws {
        guard mode == .notebook else {
            throw SyncError.unavailable(
                "Permanent body cleanup requires notebook sync."
            )
        }
        await acquirePublishLease()
        defer { releasePublishLease() }
        try await assertHealthy()
        var state = await store.snapshot()
        guard state.inbox.contains(where: {
            $0.kind == .catalog && $0.notebookID == notebookID
        }) else { throw SyncError.identityConflict }
        if !noteIDs.isSubset(of: state.deletedNoteIDs) {
            try await store.update { state in
                _ = try state.purgeDeletedNotes(
                    noteIDs, notebookID: notebookID
                )
            }
            state = await store.snapshot()
        }
        let requiresScan = !noteIDs.isSubset(
            of: state.scannedDeletedNoteIDs
        )
        let requiresFetch = requiresScan
            || !state.unresolvedRemoteDeletionRecordIDs.isEmpty
        if state.pendingRemoteDeletionIDs.isEmpty && !requiresFetch {
            return
        }

        try await verifyAccount()
        try await ensureZone()
        if requiresFetch {
            try await cloudRequest {
                try await engine.fetchChanges(
                    .init(scope: .zoneIDs([zoneID]))
                )
            }
            if let delegateFailure { throw delegateFailure }
            let fetched = await store.snapshot()
            if !fetched.unresolvedRemoteDeletionRecordIDs.isEmpty
                || requiresScan {
                try await store.update {
                    if !$0.unresolvedRemoteDeletionRecordIDs.isEmpty {
                        try $0.resolveRemoteNoteDeletions()
                    }
                    if requiresScan {
                        $0.scannedDeletedNoteIDs.formUnion(noteIDs)
                    }
                }
            }
            state = await store.snapshot()
            try state.validateRemoteDeletions()
        }

        let pendingIDs = state.pendingRemoteDeletionIDs
        let changes = pendingIDs.map {
            CKSyncEngine.PendingRecordZoneChange.saveRecord(
                CKRecord.ID(recordName: $0, zoneID: zoneID)
            )
        }
        engine.state.remove(pendingRecordZoneChanges: changes)
        try assetStaging.purge(recordIDs: pendingIDs)

        let sortedPendingIDs = pendingIDs.sorted()
        for start in stride(
            from: 0, to: sortedPendingIDs.count, by: 200
        ) {
            let batch = sortedPendingIDs[
                start..<min(start + 200, sortedPendingIDs.count)
            ]
            let ids = batch.map {
                CKRecord.ID(recordName: $0, zoneID: zoneID)
            }
            let results = try await cloudRequest {
                try await database.modifyRecords(
                    saving: [],
                    deleting: ids,
                    atomically: false
                ).deleteResults
            }
            var completed = Set<String>()
            var failure: Error?
            for id in ids {
                guard let result = results[id] else {
                    failure = failure
                        ?? CloudKitSyncTransportError.uploadNotAcknowledged
                    continue
                }
                switch result {
                case .success:
                    completed.insert(id.recordName)
                case .failure(let error as CKError)
                    where error.code == .unknownItem:
                    completed.insert(id.recordName)
                case .failure(let error):
                    await observeRetryAfter(error)
                    failure = failure ?? error
                }
            }
            if !completed.isEmpty {
                try await store.update {
                    $0.pendingRemoteDeletionIDs.subtract(completed)
                }
            }
            if let failure { throw failure }
        }
    }

    public func retryNotBefore() async -> Date? {
        [retryThrottle.notBefore, availabilityCooldown.notBefore]
            .compactMap { $0 }
            .max()
    }

    private func acquirePublishLease() async {
        if !publishInProgress {
            publishInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            publishWaiters.append(continuation)
        }
    }

    private func releasePublishLease() {
        guard !publishWaiters.isEmpty else {
            publishInProgress = false
            return
        }
        publishWaiters.removeFirst().resume()
    }

    private func verifyAccount() async throws {
        guard try await cloudRequest({
                  try await container.accountStatus()
              }) == .available,
              try await cloudRequest({
                  try await container.userRecordID()
              })
                == expectedUserRecordID else {
            throw SyncError.scopeChanged
        }
    }

    private func cloudRequest<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        if let delegateFailure { throw delegateFailure }
        try await waitForRetryWindow()
        // Actor state can change while a cooldown suspends this request.
        if let delegateFailure { throw delegateFailure }
        do {
            return try await operation()
        } catch {
            await observeRetryAfter(error)
            throw error
        }
    }

    private func waitForRetryWindow() async throws {
        while let remaining = retryThrottle.remaining(at: Date()) {
            try await Task.sleep(for: .seconds(remaining))
        }
    }

    private func observeRetryAfter(_ error: Error) async {
        let delay = CloudKitRetryMetadata.seconds(in: error)
        guard retryThrottle.observe(retryAfter: delay, now: Date()) else {
            return
        }
        let deadline = retryThrottle.notBefore
        do {
            try availabilityCooldown.merge(notBefore: deadline)
            try await store.update { $0.retryNotBefore = deadline }
        } catch {
            // Do not continue advancing CKSyncEngine state if the cooldown
            // cannot be made durable for a restart.
            delegateFailure = error
        }
    }

    private func assertHealthy() async throws {
        if let delegateFailure { throw delegateFailure }
        guard !(await store.snapshot().hasUnexpectedDeletion) else {
            throw CloudKitSyncTransportError.unexpectedDeletion
        }
    }

    private func ensureZone() async throws {
        let result = try await cloudRequest {
            try await database.recordZones(for: [zoneID])
        }
        guard let zoneResult = result[zoneID] else {
            throw CloudKitSyncTransportError.invalidRemoteRecord
        }
        switch zoneResult {
        case .success:
            return
        case let .failure(error):
            await observeRetryAfter(error)
            guard let cloudError = error as? CKError,
                  cloudError.code == .unknownItem
                    || cloudError.code == .zoneNotFound else {
                throw error
            }
        }
        let saved = try await cloudRequest {
            try await database.modifyRecordZones(
                saving: [CKRecordZone(zoneID: zoneID)], deleting: []
            )
        }.saveResults[zoneID]
        guard let saved else {
            throw CloudKitSyncTransportError.invalidRemoteRecord
        }
        do {
            _ = try saved.get()
        } catch {
            await observeRetryAfter(error)
            throw error
        }
    }

    private func makeCloudRecord(
        _ value: SyncRecord, id: CKRecord.ID, assetURL: URL
    ) throws -> CKRecord {
        try codec.encode(value, id: id, assetURL: assetURL)
    }

    private func decode(_ record: CKRecord) throws -> SyncRecord {
        try codec.decode(record)
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
                let targetDeletions = changes.deletions.filter {
                    $0.recordID.zoneID == zoneID
                }
                if !targetDeletions.isEmpty {
                    let recordNames = Set(targetDeletions.map {
                        $0.recordID.recordName
                    })
                    let bootstrapRecordName = mode.bootstrapName
                    try await store.update { state in
                        state.observeRemoteDeletions(
                            recordNames,
                            bootstrapRecordName: bootstrapRecordName
                        )
                    }
                }
                let records = try changes.modifications
                    .map(\.record)
                    .filter { $0.recordID.zoneID == zoneID }
                    .map(decode)
                try await eventCommitter.commitFetched(records)
            case let .sentRecordZoneChanges(changes):
                let savedRecords = try changes.savedRecords.map { record in
                    let id = record.recordID.recordName
                    let saved = try decode(record)
                    guard saved.id == id else {
                        throw CloudKitSyncTransportError.invalidRemoteRecord
                    }
                    return CloudKitAcknowledgedRecord(
                        id: id,
                        record: saved
                    )
                }
                if !savedRecords.isEmpty {
                    try await eventCommitter.commitSent(savedRecords)
                    acknowledgedIDs.formUnion(savedRecords.map(\.id))
                }
                for failure in changes.failedRecordSaves {
                    await observeRetryAfter(failure.error)
                    if let delegateFailure { throw delegateFailure }
                    let id = failure.record.recordID.recordName
                    if failure.error.code == .serverRecordChanged {
                        do {
                            let server = try await cloudRequest {
                                try await database.record(
                                    for: failure.record.recordID
                                )
                            }
                            let value = try decode(server)
                            guard value.id == id else {
                                throw CloudKitSyncTransportError
                                    .invalidRemoteRecord
                            }
                            try await store.update { state in
                                let pending = state.outbox.removeValue(
                                    forKey: id
                                ) ?? value
                                try state.appendToInbox(pending)
                            }
                            syncEngine.state.remove(
                                pendingRecordZoneChanges: [
                                    .saveRecord(failure.record.recordID)
                                ]
                            )
                            acknowledgedIDs.insert(id)
                        } catch {
                            failedUploads[id] = error
                        }
                    } else {
                        failedUploads[id] = CloudKitSyncTransportError
                            .uploadFailed(code: failure.error.code.rawValue)
                    }
                }
            case let .accountChange(change):
                switch change.changeType {
                case let .signIn(currentUser)
                    where currentUser == expectedUserRecordID:
                    break
                case .signIn, .signOut, .switchAccounts:
                    delegateFailure = SyncError.scopeChanged
                @unknown default:
                    delegateFailure = SyncError.scopeChanged
                }
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
        let codec = codec
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
            return try? codec.encode(value, id: recordID, assetURL: assetURL)
        }
    }
}
