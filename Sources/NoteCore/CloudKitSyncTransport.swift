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

    mutating func appendToInboxIfChanged(
        _ record: SyncRecord
    ) throws -> Bool {
        let priorInboxCount = inboxSlots.count
        let priorPendingDeletionIDs = pendingRemoteDeletionIDs
        let priorPurgedRecordIDs = purgedRecordIDs
        let priorUnresolvedDeletionIDs = unresolvedRemoteDeletionRecordIDs
        try appendToInbox(record)
        return inboxSlots.count != priorInboxCount
            || pendingRemoteDeletionIDs != priorPendingDeletionIDs
            || purgedRecordIDs != priorPurgedRecordIDs
            || unresolvedRemoteDeletionRecordIDs != priorUnresolvedDeletionIDs
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

    @discardableResult
    mutating func observeRemoteDeletions(
        _ recordNames: Set<String>, bootstrapRecordName: String
    ) -> Int {
        let priorUnresolved = unresolvedRemoteDeletionRecordIDs
        let previouslyUnexpected = hasUnexpectedDeletion
        pendingRemoteDeletionIDs.subtract(recordNames)
        if protocolVersion == 1 {
            hasUnexpectedDeletion = hasUnexpectedDeletion
                || !recordNames.isEmpty
            return !previouslyUnexpected && hasUnexpectedDeletion ? 1 : 0
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
        let newlyUnresolved = unresolvedRemoteDeletionRecordIDs
            .subtracting(priorUnresolved).count
        return newlyUnresolved
            + (!previouslyUnexpected && hasUnexpectedDeletion ? 1 : 0)
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
    private var isRetired = false
    nonisolated let writeHealth = CloudKitWriteHealth()
    private let writeState: @Sendable (Data, URL) throws -> Void

    init(
        directory: URL,
        accountRecordName: String,
        zoneName: String,
        protocolVersion: Int = 1,
        writeState: (@Sendable (Data, URL) throws -> Void)? = nil
    ) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        self.protocolVersion = protocolVersion
        self.writeState = writeState ?? SyncFileIO.replace
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
            try self.writeState(JSONEncoder().encode(state), fileURL)
        }
    }

    func snapshot() -> CloudKitTransportState { state }

    /// Revokes writes on this instance before a replacement opens the same
    /// state file. An update already executing in this actor finishes first.
    func retire() { isRetired = true }

    func update<Result: Sendable>(
        _ body: (inout CloudKitTransportState) throws -> Result
    ) throws -> Result {
        if let writeFailure = writeHealth.failure { throw writeFailure }
        guard !isRetired else { throw CloudKitRetiredTransportError() }
        var next = state
        let result = try body(&next)
        try next.validate(expectedProtocolVersion: protocolVersion)
        let data = try JSONEncoder().encode(next)
        do {
            try writeState(data, fileURL)
        } catch {
            let failure = CloudKitStateWriteFailure(
                underlyingError: error
            )
            writeHealth.latch(failure)
            isRetired = true
            throw failure
        }
        state = next
        return result
    }

}

actor CloudKitEventCommitter {
    private let store: CloudKitTransportStateStore
    private(set) var failure: Error?

    init(store: CloudKitTransportStateStore) { self.store = store }

    @discardableResult
    func commitFetched(
        _ records: [SyncRecord],
        deleting recordNames: Set<String> = [],
        bootstrapRecordName: String = ""
    ) async throws -> CloudKitFetchedCommit {
        guard failure == nil else { throw failure! }
        guard !records.isEmpty || !recordNames.isEmpty else {
            return CloudKitFetchedCommit()
        }
        do {
            return try await store.update { state in
                var result = CloudKitFetchedCommit()
                result.deletionCount = state.observeRemoteDeletions(
                    recordNames,
                    bootstrapRecordName: bootstrapRecordName
                )
                for record in records {
                    if try state.appendToInboxIfChanged(record) {
                        result.recordCount += 1
                    }
                }
                return result
            }
        } catch {
            failure = error
            throw error
        }
    }

    func finishFetch() async throws {
        guard failure == nil else { throw failure! }
        do {
            let current = await store.snapshot()
            if current.unresolvedRemoteDeletionRecordIDs.isEmpty {
                try current.validateRemoteDeletions()
                return
            }
            try await store.update { state in
                try state.resolveRemoteNoteDeletions()
                try state.validateRemoteDeletions()
            }
        } catch let error as CloudKitSyncTransportError
            where error == .unexpectedDeletion
        {
            // A note deletion can arrive before its permanent catalog marker.
            // Keep accepting later fetch events so that marker can resolve it.
            throw error
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

    @discardableResult
    func commitSent(
        _ records: [CloudKitAcknowledgedRecord]
    ) async throws -> Int {
        guard failure == nil else { throw failure! }
        do {
            return try await store.update { state in
                var committedCount = 0
                for record in records {
                    if let value = state.outbox.removeValue(
                        forKey: record.id
                    ) {
                        committedCount += 1
                        try state.appendToInbox(value)
                    } else if try state.appendToInboxIfChanged(record.record) {
                        committedCount += 1
                    }
                }
                return committedCount
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
        do {
            try record.snapshot.data.write(to: url, options: .atomic)
        } catch {
            throw CloudKitStateWriteFailure(underlyingError: error)
        }
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

    mutating func discardAcknowledgedAssets(recordIDs: Set<String>) {
        for id in recordIDs {
            let url = directory.appendingPathComponent(id)
            guard users[url] == nil else { continue }
            try? FileManager.default.removeItem(at: url)
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
        let unacknowledgedIDs = requestedIDs.subtracting(
            durableAcknowledgements
        )
        var failureCandidates = records.flatMap { record -> [Error] in
            guard unacknowledgedIDs.contains(record.id),
                  let failure = failures[record.id]
            else { return [] }
            return resolvedErrors(
                failure,
                unacknowledgedIDs: unacknowledgedIDs,
                appliesToRecord: true
            )
        }
        if let delegateFailure {
            failureCandidates += resolvedErrors(
                delegateFailure,
                unacknowledgedIDs: unacknowledgedIDs
            )
        }
        if !unacknowledgedIDs.isEmpty, let sendError {
            failureCandidates += resolvedErrors(
                sendError, unacknowledgedIDs: unacknowledgedIDs
            )
        }
        var error = preferred(failureCandidates)
        if error == nil, durableAcknowledgements != requestedIDs {
            error = CloudKitSyncTransportError.uploadNotAcknowledged
        }
        return SyncBatchResult(
            acknowledgedIDs: durableAcknowledgements,
            error: error
        )
    }

    private static func resolvedErrors(
        _ error: Error,
        unacknowledgedIDs: Set<String>,
        appliesToRecord: Bool = false
    ) -> [Error] {
        guard let cloudError = error as? CKError,
              cloudError.code == .partialFailure
        else { return [error] }
        let matchingErrors = leafFailures(
            in: cloudError,
            unacknowledgedIDs: unacknowledgedIDs,
            appliesToRecord: appliesToRecord,
            remainingDepth: 8
        )
        if !matchingErrors.isEmpty { return matchingErrors }
        return [partialFailureFallback]
    }

    private static func leafFailures(
        in error: Error,
        unacknowledgedIDs: Set<String>,
        appliesToRecord: Bool,
        remainingDepth: Int
    ) -> [Error] {
        guard remainingDepth > 0 else {
            return appliesToRecord ? [partialFailureFallback] : []
        }
        guard let cloudError = error as? CKError else {
            return appliesToRecord ? [error] : []
        }
        guard cloudError.code == .partialFailure else {
            return appliesToRecord
                ? [CloudKitSyncTransportError.uploadFailed(
                    code: cloudError.code.rawValue
                )]
                : []
        }
        guard let partialErrors = cloudError.partialErrorsByItemID,
              !partialErrors.isEmpty
        else {
            return appliesToRecord ? [partialFailureFallback] : []
        }
        return partialErrors.flatMap { key, child in
            let childApplies = appliesToRecord
                || recordName(for: key).map(unacknowledgedIDs.contains)
                == true
            return leafFailures(
                in: child,
                unacknowledgedIDs: unacknowledgedIDs,
                appliesToRecord: childApplies,
                remainingDepth: remainingDepth - 1
            )
        }
    }

    private static var partialFailureFallback: Error {
        CloudKitSyncTransportError.uploadFailed(
            code: CKError.partialFailure.rawValue
        )
    }

    private static func preferred(_ errors: [Error]) -> Error? {
        errors.first(where: { !NotebookSyncRetryPolicy.isTransient($0) })
            ?? errors.first
    }

    private static func recordName(for key: AnyHashable) -> String? {
        if let recordID = key.base as? CKRecord.ID {
            return recordID.recordName
        }
        return key.base as? String
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
public final actor CloudKitSyncTransport: HaltableSyncTransport {
    public nonisolated let scope: String
    public nonisolated let activity: AsyncStream<CloudKitSyncActivity>

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
    private let automaticallySync: Bool
    private var assetStaging: CloudKitAssetStaging
    private var engineAssetLeases: [String: [URL]] = [:]
    private var availabilityCooldown: CloudKitAvailabilityCooldownStore
    private var engine: CKSyncEngine!
    private var retiredEngineID: ObjectIdentifier?
    private var awaitedUploadIDs = Set<String>()
    private var acknowledgedIDs = Set<String>()
    private var failedUploads: [String: Error] = [:]
    private var delegateFailure: Error?
    private var lastReportedFailure: Error?
    private var isRetired = false
    private var unexpectedDeletionObserved = false
    private var retryThrottle = CloudKitRetryThrottle()
    private var publishInProgress = false
    private var publishWaiters: [CheckedContinuation<Void, Never>] = []
    private let activityChannel: CloudKitSyncActivityChannel
    private var activityTracker = CloudKitSyncActivityTracker()

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
            mode: .legacy,
            automaticallySync: false
        )
    }

    public static func makeNotebook(
        containerIdentifier: String,
        stateDirectory: URL,
        automaticallySync: Bool = false,
        expectedScope: String? = nil,
        expectedNotebookID: UUID? = nil
    ) async throws -> CloudKitSyncTransport {
        try await make(
            containerIdentifier: containerIdentifier,
            stateDirectory: stateDirectory,
            zoneName: CloudKitTransportMode.notebook.zoneName,
            mode: .notebook,
            automaticallySync: automaticallySync,
            expectedScope: expectedScope,
            expectedNotebookID: expectedNotebookID
        )
    }

    private static func make(
        containerIdentifier: String,
        stateDirectory: URL,
        zoneName: String,
        mode: CloudKitTransportMode,
        automaticallySync: Bool,
        expectedScope: String? = nil,
        expectedNotebookID: UUID? = nil
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
        if let expectedScope {
            let actualScope = "\(containerIdentifier)/private/"
                + "\(userRecordID.recordName)/\(zoneName)"
            guard actualScope == expectedScope else {
                throw SyncError.scopeChanged
            }
            let stateURL = stateDirectory.appendingPathComponent(
                "cloudkit-sync-state.json"
            )
            guard FileManager.default.fileExists(atPath: stateURL.path) else {
                throw CloudKitSyncTransportError.corruptState
            }
        }
        let store = try CloudKitTransportStateStore(
            directory: stateDirectory,
            accountRecordName: userRecordID.recordName,
            zoneName: zoneName,
            protocolVersion: mode.protocolVersion
        )
        if let expectedNotebookID {
            let state = await store.snapshot()
            guard state.inbox.allSatisfy({
                $0.notebookID == expectedNotebookID
            }), state.outbox.values.allSatisfy({
                $0.notebookID == expectedNotebookID
            }) else {
                throw SyncError.scopeChanged
            }
        }
        let transport = CloudKitSyncTransport(
            containerIdentifier: containerIdentifier,
            container: container,
            userRecordID: userRecordID,
            zoneName: zoneName,
            stateDirectory: stateDirectory,
            store: store,
            availabilityCooldown: availabilityCooldown,
            mode: mode,
            automaticallySync: automaticallySync
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
        mode: CloudKitTransportMode,
        automaticallySync: Bool
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
        let activityChannel = CloudKitSyncActivityChannel()
        self.activityChannel = activityChannel
        activity = activityChannel.stream
        assetDirectory = stateDirectory.appendingPathComponent("assets")
            .appendingPathComponent(UUID().uuidString)
        assetStaging = CloudKitAssetStaging(directory: assetDirectory)
        self.availabilityCooldown = availabilityCooldown
        self.automaticallySync = automaticallySync
        scope = "\(containerIdentifier)/private/\(userRecordID.recordName)/\(zoneName)"
    }

    private func initialize() async throws {
        let assetRoot = assetDirectory.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: assetRoot, withIntermediateDirectories: true
        )
        CloudKitAssetGenerationCleanup.prunePreviousProcessGenerations(
            in: assetRoot
        )
        try FileManager.default.createDirectory(
            at: assetDirectory, withIntermediateDirectories: true
        )
        let saved = await store.snapshot()
        unexpectedDeletionObserved = saved.hasUnexpectedDeletion
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
        configuration.automaticallySync = automaticallySync
        engine = CKSyncEngine(configuration)
        let queuedSaves = Set(
            engine.state.pendingRecordZoneChanges.compactMap { change in
                if case let .saveRecord(id) = change {
                    return id.recordName
                }
                return nil
            }
        )
        let missingSaves = saved.outbox.keys.filter {
            !queuedSaves.contains($0)
        }.map { name in
            CKSyncEngine.PendingRecordZoneChange.saveRecord(
                CKRecord.ID(recordName: name, zoneID: zoneID)
            )
        }
        if !missingSaves.isEmpty {
            engine.state.add(pendingRecordZoneChanges: missingSaves)
        }
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
                    assetURL,
                    uploadCompleted: uploadCompleted || isRetired
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
        try assertActive()

        var stagedAssets: [String: URL] = [:]
        var completedIDs = Set<String>()
        defer {
            for (id, assetURL) in stagedAssets {
                assetStaging.release(
                    assetURL,
                    uploadCompleted: completedIDs.contains(id)
                        || isRetired
                )
            }
        }
        for record in records {
            if stagedAssets[record.id] == nil {
                try assertActive()
                stagedAssets[record.id] = try assetStaging.retain(record)
            }
        }

        try assertActive()
        let batch = CloudKitUploadBatch(records: records, zoneID: zoneID)
        let ids = batch.ids
        let recordIDs = batch.recordIDs
        acknowledgedIDs.subtract(ids)
        for id in ids { failedUploads[id] = nil }
        awaitedUploadIDs.formUnion(ids)
        defer {
            awaitedUploadIDs.subtract(ids)
            acknowledgedIDs.subtract(ids)
            for id in ids { failedUploads[id] = nil }
        }
        engine.state.add(
            pendingRecordZoneChanges: recordIDs.map { .saveRecord($0) }
        )
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
        try assertActive()
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
        try assertActive()
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

    public func haltStatus() async -> CloudKitSyncHaltStatus? {
        if let failure = store.writeHealth.failure { latchFailure(failure) }
        if let delegateFailure {
            return CloudKitSyncHaltStatus(error: delegateFailure)
        }
        if isRetired {
            return CloudKitSyncHaltStatus(
                reason: .retired,
                underlyingError: CloudKitRetiredTransportError(),
                isRecoverable: false
            )
        }
        let hasUnexpectedDeletion = await store.snapshot().hasUnexpectedDeletion
        if let failure = store.writeHealth.failure { latchFailure(failure) }
        if let delegateFailure {
            return CloudKitSyncHaltStatus(error: delegateFailure)
        }
        if hasUnexpectedDeletion {
            return CloudKitSyncHaltStatus(
                error: CloudKitSyncTransportError.unexpectedDeletion
            )
        }
        return nil
    }

    public func lastFailure() -> (any Error)? {
        lastReportedFailure
    }

    /// The durable write fence is installed before a new instance may open
    /// this state directory. Cancellation is advisory: CK may still deliver
    /// callbacks, all of which are ignored by this retired instance.
    public func retire() async {
        guard !isRetired else {
            await store.retire()
            return
        }
        let oldEngine = engine
        retiredEngineID = oldEngine.map(ObjectIdentifier.init)
        isRetired = true
        await store.retire()
        engine = nil
        activityChannel.finish()
        let waiters = publishWaiters
        publishWaiters.removeAll()
        publishInProgress = false
        for waiter in waiters { waiter.resume() }
        if let oldEngine {
            Task.detached { await oldEngine.cancelOperations() }
        }
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
        let status = try await cloudRequest {
            try await container.accountStatus()
        }
        switch status {
        case .available:
            break
        case .noAccount:
            latchFailure(SyncError.scopeChanged)
            throw SyncError.scopeChanged
        default:
            throw CloudKitSyncTransportError.accountUnavailable
        }
        let currentUser = try await cloudRequest {
            try await container.userRecordID()
        }
        guard currentUser == expectedUserRecordID else {
            latchFailure(SyncError.scopeChanged)
            throw SyncError.scopeChanged
        }
    }

    private func cloudRequest<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        try assertActive()
        if let delegateFailure { throw delegateFailure }
        try await waitForRetryWindow()
        // Actor state can change while a cooldown suspends this request.
        try assertActive()
        if let delegateFailure { throw delegateFailure }
        do {
            let result = try await operation()
            try assertActive()
            if let delegateFailure { throw delegateFailure }
            return result
        } catch {
            try assertActive()
            if let delegateFailure { throw delegateFailure }
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
        guard !isRetired else { return }
        let delay = CloudKitRetryMetadata.seconds(in: error)
        guard retryThrottle.observe(retryAfter: delay, now: Date()) else {
            return
        }
        let deadline = retryThrottle.notBefore
        do {
            do {
                try availabilityCooldown.merge(notBefore: deadline)
            } catch {
                throw CloudKitStateWriteFailure(underlyingError: error)
            }
            try await store.update { $0.retryNotBefore = deadline }
        } catch {
            // Do not continue advancing CKSyncEngine state if the cooldown
            // cannot be made durable for a restart.
            latchFailure(error)
        }
    }

    private func assertHealthy() async throws {
        try assertActive()
        if let delegateFailure { throw delegateFailure }
        let hasUnexpectedDeletion = await store.snapshot().hasUnexpectedDeletion
        try assertActive()
        if let delegateFailure { throw delegateFailure }
        guard !hasUnexpectedDeletion else {
            let error = CloudKitSyncTransportError.unexpectedDeletion
            latchFailure(error)
            throw error
        }
    }

    private func assertActive() throws {
        guard !isRetired else { throw CloudKitRetiredTransportError() }
        if let failure = store.writeHealth.failure {
            latchFailure(failure)
            throw failure
        }
    }

    private func latchFailure(_ error: any Error) {
        if error as? SyncError == .scopeChanged {
            delegateFailure = error
        } else if delegateFailure == nil {
            delegateFailure = error
        } else {
            return
        }
        lastReportedFailure = error
        if let engine {
            Task.detached { await engine.cancelOperations() }
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

    private func yieldAfterDelegateReturns(
        _ activities: [CloudKitSyncActivity]
    ) {
        guard !activities.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            activityChannel.yield(activities)
        }
    }

    private func prepareEngineBatchRecords(
        pending: [CKSyncEngine.PendingRecordZoneChange],
        outbox: [String: SyncRecord]
    ) throws -> [String: CKRecord] {
        try assertActive()
        if let delegateFailure { throw delegateFailure }
        guard !unexpectedDeletionObserved else {
            throw CloudKitSyncTransportError.unexpectedDeletion
        }
        var records: [String: CKRecord] = [:]
        do {
            for change in pending {
                guard case let .saveRecord(recordID) = change,
                      recordID.zoneID == zoneID,
                      let value = outbox[recordID.recordName] else {
                    continue
                }
                let assetURL = try assetStaging.retain(value)
                do {
                    records[recordID.recordName] = try codec.encode(
                        value,
                        id: recordID,
                        assetURL: assetURL
                    )
                    engineAssetLeases[recordID.recordName, default: []]
                        .append(assetURL)
                } catch {
                    assetStaging.release(assetURL, uploadCompleted: false)
                    throw error
                }
            }
            return records
        } catch {
            for id in records.keys {
                releaseEngineAssetLease(for: id, uploadCompleted: false)
            }
            throw error
        }
    }

    private func releaseEngineAssetLease(
        for id: String,
        uploadCompleted: Bool
    ) {
        guard var leases = engineAssetLeases[id], !leases.isEmpty else {
            return
        }
        let assetURL = leases.removeFirst()
        engineAssetLeases[id] = leases.isEmpty ? nil : leases
        assetStaging.release(
            assetURL,
            uploadCompleted: uploadCompleted
        )
    }
}

@available(macOS 14.0, iOS 17.0, *)
extension CloudKitSyncTransport: CKSyncEngineDelegate {
    public func handleEvent(
        _ event: CKSyncEngine.Event, syncEngine: CKSyncEngine
    ) async {
        if isRetired {
            if retiredEngineID == ObjectIdentifier(syncEngine),
               case let .sentRecordZoneChanges(changes) = event {
                // CK may report a completed operation after cancellation.
                // Its asset paths belong only to this transport generation.
                for record in changes.savedRecords {
                    releaseEngineAssetLease(
                        for: record.recordID.recordName,
                        uploadCompleted: true
                    )
                }
                for failure in changes.failedRecordSaves {
                    releaseEngineAssetLease(
                        for: failure.record.recordID.recordName,
                        uploadCompleted: true
                    )
                }
            }
            return
        }
        guard syncEngine === engine else { return }
        if delegateFailure != nil {
            if case .accountChange = event {
                // Account transitions remain authoritative after a storage
                // failure and may make reconstruction unsafe.
            } else if case .sentRecordZoneChanges = event,
                  delegateFailure as? SyncError != .scopeChanged,
                  await eventCommitter.failure == nil,
                  !(await store.snapshot().hasUnexpectedDeletion),
                  delegateFailure as? SyncError != .scopeChanged,
                  !isRetired, syncEngine === engine {
                // An upload completed before the failure may still be
                // acknowledged if the committer remains healthy.
            } else {
                if case let .sentRecordZoneChanges(changes) = event {
                    for record in changes.savedRecords {
                        releaseEngineAssetLease(
                            for: record.recordID.recordName,
                            uploadCompleted: true
                        )
                    }
                    for failure in changes.failedRecordSaves {
                        releaseEngineAssetLease(
                            for: failure.record.recordID.recordName,
                            uploadCompleted: true
                        )
                    }
                }
                return
            }
        }
        var activities: [CloudKitSyncActivity] = []
        defer { yieldAfterDelegateReturns(activities) }
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
                let recordNames = Set(targetDeletions.map {
                    $0.recordID.recordName
                })
                let records = try changes.modifications
                    .map(\.record)
                    .filter { $0.recordID.zoneID == zoneID }
                    .map(decode)
                let committed = try await eventCommitter.commitFetched(
                    records,
                    deleting: recordNames,
                    bootstrapRecordName: mode.bootstrapName
                )
                activityTracker.recordFetch(
                    recordCount: committed.recordCount,
                    deletionCount: committed.deletionCount
                )
            case let .sentRecordZoneChanges(changes):
                let savedIDs = Set(changes.savedRecords.map {
                    $0.recordID.recordName
                })
                let failedIDs = Set(changes.failedRecordSaves.map {
                    $0.record.recordID.recordName
                })
                var durablyCommittedIDs = Set<String>()
                defer {
                    for id in savedIDs {
                        releaseEngineAssetLease(
                            for: id,
                            uploadCompleted: isRetired
                                || delegateFailure != nil
                                || durablyCommittedIDs.contains(id)
                        )
                    }
                    for id in failedIDs {
                        releaseEngineAssetLease(
                            for: id,
                            uploadCompleted: isRetired
                                || delegateFailure != nil
                                || durablyCommittedIDs.contains(id)
                        )
                    }
                }
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
                    let committedCount = try await eventCommitter.commitSent(
                        savedRecords
                    )
                    durablyCommittedIDs.formUnion(savedRecords.map(\.id))
                    acknowledgedIDs.formUnion(
                        Set(savedRecords.map(\.id))
                            .intersection(awaitedUploadIDs)
                    )
                    assetStaging.discardAcknowledgedAssets(
                        recordIDs: Set(savedRecords.map(\.id))
                    )
                    activityTracker.recordAcknowledgements(
                        committedCount
                    )
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
                            let committed = try await store.update { state in
                                let pending = state.outbox.removeValue(
                                    forKey: id
                                )
                                let changed = try state.appendToInboxIfChanged(
                                    pending ?? value
                                )
                                return pending != nil || changed
                            }
                            durablyCommittedIDs.insert(id)
                            syncEngine.state.remove(
                                pendingRecordZoneChanges: [
                                    .saveRecord(failure.record.recordID)
                                ]
                            )
                            if awaitedUploadIDs.contains(id) {
                                acknowledgedIDs.insert(id)
                            }
                            assetStaging.discardAcknowledgedAssets(
                                recordIDs: [id]
                            )
                            if committed {
                                activityTracker.recordAcknowledgements(1)
                            }
                        } catch {
                            lastReportedFailure = error
                            if awaitedUploadIDs.contains(id) {
                                failedUploads[id] = error
                            }
                            activities.append(.failed(
                                error.localizedDescription
                            ))
                        }
                    } else {
                        let error = CloudKitSyncTransportError
                            .uploadFailed(code: failure.error.code.rawValue)
                        if awaitedUploadIDs.contains(id) {
                            failedUploads[id] = error
                        }
                        lastReportedFailure = failure.error
                        activities.append(.failed(
                            error.localizedDescription
                        ))
                    }
                }
            case let .accountChange(change):
                switch change.changeType {
                case let .signIn(currentUser)
                    where currentUser == expectedUserRecordID:
                    break
                case .signIn, .signOut, .switchAccounts:
                    latchFailure(SyncError.scopeChanged)
                @unknown default:
                    latchFailure(SyncError.scopeChanged)
                }
                activities.append(.accountChanged)
            case let .fetchedDatabaseChanges(changes):
                if changes.deletions.contains(where: { $0.zoneID == zoneID }) {
                    unexpectedDeletionObserved = true
                    latchFailure(CloudKitSyncTransportError.unexpectedDeletion)
                    try await store.update { $0.hasUnexpectedDeletion = true }
                    lastReportedFailure =
                        CloudKitSyncTransportError.unexpectedDeletion
                    activities.append(.failed(
                        CloudKitSyncTransportError.unexpectedDeletion
                            .localizedDescription
                    ))
                }
            case let .didFetchRecordZoneChanges(completion):
                if completion.zoneID == zoneID, let error = completion.error {
                    await observeRetryAfter(error)
                    if let delegateFailure { throw delegateFailure }
                    lastReportedFailure = error
                    activities.append(.failed(error.localizedDescription))
                }
            case let .didFetchChanges(completion):
                do {
                    try await eventCommitter.finishFetch()
                    let reason: CloudKitSyncReason =
                        completion.context.reason == .scheduled
                        ? .scheduled
                        : .manual
                    if let activity = activityTracker.finishFetch(
                        reason: reason
                    ) {
                        activities.append(activity)
                    }
                } catch let error as CloudKitSyncTransportError
                    where error == .unexpectedDeletion
                {
                    // A peer's permanent marker may arrive in a later fetch.
                    // Surface this pass without poisoning future delegate work.
                    lastReportedFailure = error
                    activities.append(.failed(error.localizedDescription))
                }
            case let .didSendChanges(completion):
                if let activity = activityTracker.finishSend(
                    wasScheduled: completion.context.reason == .scheduled
                ) {
                    activities.append(activity)
                }
            default:
                break
            }
        } catch {
            guard !isRetired else { return }
            latchFailure(error)
            lastReportedFailure = error
            activities.append(.failed(error.localizedDescription))
            if case let .sentRecordZoneChanges(changes) = event {
                for record in changes.savedRecords {
                    let id = record.recordID.recordName
                    if awaitedUploadIDs.contains(id) {
                        failedUploads[id] = error
                    }
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
        do {
            let prepared = try await CloudKitOutgoingBatchPreparer.assemble(
                allowed: { await self.canOfferOutgoingBatch(syncEngine) },
                readOutbox: { await self.store.snapshot().outbox },
                stage: { outbox in
                    guard await self.canOfferOutgoingBatch(syncEngine)
                        else { return [:] }
                    return try await self.prepareEngineBatchRecords(
                        pending: pending,
                        outbox: outbox
                    )
                },
                construct: { records in
                    await CKSyncEngine.RecordZoneChangeBatch(
                        pendingChanges: pending
                    ) { recordID in
                        records[recordID.recordName]
                    }
                },
                release: { ids in
                    await self.releaseOutgoingBatchLeases(ids)
                }
            )
            guard let prepared else { return nil }
            guard !isRetired, delegateFailure == nil,
                  store.writeHealth.failure == nil,
                  !unexpectedDeletionObserved,
                  syncEngine === engine else {
                releaseOutgoingBatchLeases(prepared.leasedIDs)
                return nil
            }
            return prepared.batch
        } catch {
            guard !isRetired else { return nil }
            latchFailure(error)
            lastReportedFailure = error
            yieldAfterDelegateReturns([.failed(error.localizedDescription)])
            return nil
        }
    }

    private func canOfferOutgoingBatch(_ syncEngine: CKSyncEngine)
        async -> Bool
    {
        if let failure = store.writeHealth.failure { latchFailure(failure) }
        guard !isRetired, delegateFailure == nil,
              !unexpectedDeletionObserved,
              syncEngine === engine else { return false }
        let unexpectedDeletion = await store.snapshot().hasUnexpectedDeletion
        if let failure = store.writeHealth.failure { latchFailure(failure) }
        guard !isRetired, delegateFailure == nil,
              !unexpectedDeletionObserved,
              syncEngine === engine else { return false }
        if unexpectedDeletion {
            latchFailure(CloudKitSyncTransportError.unexpectedDeletion)
            return false
        }
        return true
    }

    private func releaseOutgoingBatchLeases(_ ids: Set<String>) {
        for id in ids {
            releaseEngineAssetLease(for: id, uploadCompleted: false)
        }
    }
}
