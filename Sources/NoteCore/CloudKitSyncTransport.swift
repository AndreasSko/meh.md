import CloudKit
import Darwin
import Foundation

public enum CloudKitSyncTransportError: Error, Equatable, LocalizedError {
    case accountUnavailable
    case corruptState
    case unrecoverableRetryDelay
    case invalidRemoteRecord
    case unexpectedDeletion
    case uploadFailed(code: Int)
    case uploadNotAcknowledged
    case snapshotTooLarge(
        documentID: UUID, kind: SyncDocumentKind = .note,
        displayName: String? = nil
    )

    public var errorDescription: String? {
        switch self {
        case .accountUnavailable: "An iCloud account is required for sync."
        case .corruptState: "The saved CloudKit sync state is corrupt."
        case .unrecoverableRetryDelay:
            "The saved CloudKit retry delay cannot be recovered safely. "
                + "Sync is paused to avoid bypassing server throttling."
        case .invalidRemoteRecord: "CloudKit returned an invalid snapshot."
        case .unexpectedDeletion:
            "A remote snapshot was deleted. Sync is paused to preserve history."
        case let .uploadFailed(code):
            "CloudKit upload failed (CKError code \(code))."
        case .uploadNotAcknowledged:
            "CloudKit did not acknowledge the requested snapshot."
        case let .snapshotTooLarge(documentID, _, displayName):
            "The snapshot for \(displayName ?? documentID.uuidString) exceeds the app's 64 MiB iCloud sync limit."
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
    var recoveredInvalidRetryDeadline = false

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
        do {
            retryNotBefore = try values.decodeIfPresent(
                Date.self, forKey: .retryNotBefore
            )
        } catch is DecodingError {
            retryNotBefore = nil
            recoveredInvalidRetryDeadline = true
        }
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
        try CloudKitSnapshotSizeLimit.validate(record)
        try record.validate()
        try appendValidatedRecord(record)
    }

    mutating func appendToInbox(
        _ validated: CloudKitValidatedBootstrapRecord
    ) throws {
        guard validated.mode.protocolVersion == protocolVersion else {
            throw SyncError.invalidRecord
        }
        try CloudKitSnapshotSizeLimit.validate(validated.record)
        try appendValidatedRecord(validated.record)
    }

    private mutating func appendValidatedRecord(
        _ record: SyncRecord
    ) throws {
        guard record.protocolVersion == protocolVersion else {
            throw SyncError.invalidRecord
        }
        try CloudKitSnapshotSizeLimit.validate(record)
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
        try validate(expectedProtocolVersion: expectedProtocolVersion, reusing: nil)
    }

    /// Only the store's last successfully persisted state may supply trust.
    /// Exact record equality includes bytes, heads, and identity; IDs alone
    /// cannot establish that a record has already passed validation.
    fileprivate func validate(
        expectedProtocolVersion: Int,
        reusing previous: CloudKitTransportState?
    ) throws {
        guard protocolVersion == expectedProtocolVersion else {
            throw SyncError.scopeChanged
        }
        for (index, slot) in inboxSlots.enumerated() {
            guard let record = slot else { continue }
            let unchanged = previous.map {
                $0.inboxSlots.indices.contains(index)
                    && $0.inboxSlots[index] == record
            } ?? false
            if !unchanged { try record.validate() }
            guard record.protocolVersion == protocolVersion else {
                throw SyncError.invalidRecord
            }
        }
        for (id, record) in outbox {
            if previous?.outbox[id] != record { try record.validate() }
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
        // The closure still validates incoming records, and retired/failed
        // writers were rejected above. Identical state is already durable.
        if next == state { return result }
        try next.validate(expectedProtocolVersion: protocolVersion, reusing: state)
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
    static let maximumAssetSize = CloudKitSnapshotSizeLimit.maximumBytes

    static func validateSnapshotID(_ id: String) throws {
        guard id.count == 64,
              id.utf8.allSatisfy({
                  ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
              }) else {
            throw CloudKitSyncTransportError.invalidRemoteRecord
        }
    }
}

enum CloudKitSnapshotSizeLimit {
    static let maximumBytes = 64 * 1024 * 1024

    static func validate(
        _ record: SyncRecord, limit: Int? = nil
    ) throws {
        guard let maximum = maximumBytes(
            for: record.protocolVersion
        ) else {
            throw SyncError.invalidRecord
        }
        guard record.snapshot.data.count <= min(limit ?? maximum, maximum) else {
            throw CloudKitSyncTransportError.snapshotTooLarge(
                documentID: record.snapshot.noteID, kind: record.kind
            )
        }
    }

    static func validateAssetSize(
        _ bytes: UInt64, protocolVersion: Int
    ) throws {
        guard let maximum = maximumBytes(for: protocolVersion),
              bytes <= UInt64(maximum) else {
            throw CloudKitSyncTransportError.invalidRemoteRecord
        }
    }

    static func partition(
        _ records: [SyncRecord], limit: Int? = nil
    ) throws -> (admitted: [SyncRecord], rejected: [SyncRecord]) {
        var admitted: [SyncRecord] = []
        var rejected: [SyncRecord] = []
        for record in records {
            do {
                try validate(record, limit: limit)
                admitted.append(record)
            } catch let error as CloudKitSyncTransportError {
                guard case .snapshotTooLarge = error else { throw error }
                rejected.append(record)
            }
        }
        return (admitted, rejected)
    }

    static func partitionPendingSaves(
        _ pending: [CKSyncEngine.PendingRecordZoneChange],
        outbox: [String: SyncRecord], zoneID: CKRecordZone.ID,
        limit: Int? = nil
    ) throws -> (
        admitted: [CKSyncEngine.PendingRecordZoneChange],
        rejected: [CKSyncEngine.PendingRecordZoneChange]
    ) {
        var admitted: [CKSyncEngine.PendingRecordZoneChange] = []
        var rejected: [CKSyncEngine.PendingRecordZoneChange] = []
        for change in pending {
            if case let .saveRecord(id) = change,
               id.zoneID == zoneID,
               let record = outbox[id.recordName] {
                do {
                    try validate(record, limit: limit)
                } catch let error as CloudKitSyncTransportError {
                    guard case .snapshotTooLarge = error else { throw error }
                    rejected.append(change)
                    continue
                }
            }
            admitted.append(change)
        }
        return (admitted, rejected)
    }

    private static func maximumBytes(for protocolVersion: Int) -> Int? {
        switch protocolVersion {
        case 1, 2: maximumBytes
        default: nil
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
        try CloudKitSnapshotSizeLimit.validate(record)
        try record.validate()
        guard record.protocolVersion == protocolVersion else {
            throw SyncError.invalidRecord
        }
        if self == .notebook, bootstrap, record.kind != .catalog {
            throw SyncError.invalidRecord
        }
    }
}

/// A token can only be created by the bootstrap validation cache after a full
/// validation or an exact match with a retained, previously validated value.
struct CloudKitValidatedBootstrapRecord: Sendable {
    let record: SyncRecord
    let mode: CloudKitTransportMode

    fileprivate init(
        validating record: SyncRecord,
        mode: CloudKitTransportMode
    ) throws {
        try mode.validate(record, bootstrap: true)
        self.record = record
        self.mode = mode
    }
}

/// Retains at most the proposal and canonical bootstrap values. Equality is
/// full SyncRecord equality, including snapshot bytes, heads, and identity.
struct CloudKitBootstrapValidationCache {
    private struct Entry {
        let validated: CloudKitValidatedBootstrapRecord
        let retainedBytes: Int
    }

    private static let maximumEntries = 2
    private static let defaultMaximumRetainedBytes = 16 * 1024 * 1024
    private let maximumRetainedBytes: Int
    private var entries: [Entry] = []
    private var retainedBytes = 0

    init(
        maximumRetainedBytes: Int = Self.defaultMaximumRetainedBytes
    ) {
        self.maximumRetainedBytes = max(0, maximumRetainedBytes)
    }

    var cachedRecordCount: Int { entries.count }
    var retainedPayloadByteCount: Int { retainedBytes }

    mutating func validate(
        _ record: SyncRecord,
        mode: CloudKitTransportMode
    ) throws -> CloudKitValidatedBootstrapRecord {
        if let index = entries.firstIndex(where: {
            $0.validated.mode == mode && $0.validated.record == record
        }) {
            let entry = entries.remove(at: index)
            entries.append(entry)
            return entry.validated
        }

        let token = try CloudKitValidatedBootstrapRecord(
            validating: record, mode: mode
        )
        let payloadBytes = Self.payloadBytes(for: record)
        guard payloadBytes <= maximumRetainedBytes else { return token }
        while entries.count >= Self.maximumEntries
            || retainedBytes > maximumRetainedBytes - payloadBytes
        {
            let removed = entries.removeFirst()
            retainedBytes -= removed.retainedBytes
        }
        entries.append(Entry(
            validated: token, retainedBytes: payloadBytes
        ))
        retainedBytes += payloadBytes
        return token
    }

    private static func payloadBytes(for record: SyncRecord) -> Int {
        let headBytes = record.snapshot.heads.reduce(into: 0) { total, head in
            total += head.utf8.count + 128
        }
        let metadataBytes = record.id.utf8.count + 256
        let (withHeads, firstOverflow) = record.snapshot.data.count
            .addingReportingOverflow(headBytes)
        let (total, secondOverflow) = withHeads
            .addingReportingOverflow(metadataBytes)
        guard !firstOverflow, !secondOverflow else {
            return Int.max
        }
        return total
    }
}

/// A separate CloudKit zone and local state for one fictional sync lab run.
/// The caller supplies an identity, never an arbitrary CloudKit zone name.
enum CloudKitNotebookLabScope {
    private static let zonePrefix = "meh-md-notebook-lab-v2-"
    private static let directoryPrefix = "notebook-lab-"

    static func zoneName(runID: UUID) -> String {
        zonePrefix + runID.uuidString.lowercased()
    }

    static func stateDirectory(base: URL, runID: UUID) -> URL {
        base.appendingPathComponent(
            directoryPrefix + runID.uuidString.lowercased(),
            isDirectory: true
        )
    }

    static func validate(zoneName: String, runID: UUID) throws {
        guard zoneName == self.zoneName(runID: runID),
            zoneName != CloudKitTransportMode.notebook.zoneName
        else { throw SyncError.scopeChanged }
    }
}

/// An existing zone needs only its canonical record read. Resolve a zone
/// exactly when CloudKit says it is missing, then retry that operation once.
enum CloudKitBootstrapZoneRetry {
    static func perform<T>(
        isolation: isolated (any Actor)? = #isolation,
        _ operation: () async throws -> T,
        ensureZone: () async throws -> Void
    ) async throws -> T {
        do {
            return try await operation()
        } catch let error as CKError where error.code == .zoneNotFound {
            try await ensureZone()
            return try await operation()
        }
    }
}

struct CloudKitRecordCodec: @unchecked Sendable {
    let mode: CloudKitTransportMode
    let zoneID: CKRecordZone.ID
    let maximumSupportedFormatVersion: UInt64

    init(
        mode: CloudKitTransportMode,
        zoneID: CKRecordZone.ID,
        maximumSupportedFormatVersion: UInt64 =
            NotebookSyncFormat.supportedVersion
    ) {
        self.mode = mode
        self.zoneID = zoneID
        self.maximumSupportedFormatVersion = maximumSupportedFormatVersion
    }

    func encode(
        _ value: SyncRecord,
        id: CKRecord.ID,
        assetURL: URL
    ) throws -> CKRecord {
        if mode == .notebook, value.kind == .catalog,
           maximumSupportedFormatVersion <
                NotebookSyncFormat.supportedVersion {
            let version = try NotebookSyncFormat.version(of: value)
            if version > maximumSupportedFormatVersion {
                throw SyncError.updateRequired(requiredVersion: version)
            }
        }
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
        } catch let error as SyncError {
            if case .updateRequired = error { throw error }
            throw CloudKitSyncTransportError.invalidRemoteRecord
        } catch {
            throw CloudKitSyncTransportError.invalidRemoteRecord
        }
    }

    func decodeBootstrap(
        _ record: CKRecord,
        using cache: inout CloudKitBootstrapValidationCache
    ) throws -> CloudKitValidatedBootstrapRecord {
        do {
            guard record.recordID.recordName == mode.bootstrapName else {
                throw CloudKitSyncTransportError.invalidRemoteRecord
            }
            let value = try decodeRemoteRecord(
                record, validateSnapshot: false
            )
            return try cache.validate(value, mode: mode)
        } catch let error as SyncError {
            if case .updateRequired = error { throw error }
            throw CloudKitSyncTransportError.invalidRemoteRecord
        } catch {
            throw CloudKitSyncTransportError.invalidRemoteRecord
        }
    }

    private func decodeRemoteRecord(
        _ record: CKRecord,
        validateSnapshot: Bool = true
    ) throws -> SyncRecord {
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
        guard let size = attributes[.size] as? NSNumber
        else { throw CloudKitSyncTransportError.invalidRemoteRecord }
        try CloudKitSnapshotSizeLimit.validateAssetSize(
            size.uint64Value, protocolVersion: version
        )
        let data = try Data(contentsOf: source)
        try CloudKitSnapshotSizeLimit.validateAssetSize(
            UInt64(data.count), protocolVersion: version
        )
        let snapshot = NoteSnapshot(
            data: data,
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
        if mode == .notebook, value.kind == .catalog,
           maximumSupportedFormatVersion <
                NotebookSyncFormat.supportedVersion {
            let version = try NotebookSyncFormat.version(of: value)
            if version > maximumSupportedFormatVersion {
                throw SyncError.updateRequired(requiredVersion: version)
            }
        }
        if validateSnapshot {
            do {
                try mode.validate(
                    value,
                    bootstrap: record.recordID.recordName == mode.bootstrapName
                )
            } catch let error as SyncError {
                if case .updateRequired = error { throw error }
                throw CloudKitSyncTransportError.invalidRemoteRecord
            } catch {
                throw CloudKitSyncTransportError.invalidRemoteRecord
            }
        }
        return value
    }
}

struct CloudKitAssetStaging {
    let directory: URL
    private var users: [URL: Int] = [:]
    private var completedUploads = Set<URL>()

    mutating func retain(_ record: SyncRecord) throws -> URL {
        try CloudKitSnapshotSizeLimit.validate(record)
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

enum CloudKitBootIdentity {
    static func current() -> String? {
        // KERN_BOOTTIME is a public boot marker on both iOS and macOS.
        // Calendar steps can change it, which conservatively restarts the
        // delay once. Do not infer boot identity from Date minus uptime.
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        let result = sysctlbyname(
            "kern.boottime", &bootTime, &size, nil, 0
        )
        guard result == 0, size == MemoryLayout<timeval>.size,
              bootTime.tv_sec > 0, bootTime.tv_usec >= 0,
              bootTime.tv_usec < 1_000_000 else { return nil }
        return "boottime:\(bootTime.tv_sec):\(bootTime.tv_usec)"
    }
}

struct CloudKitRetryThrottle {
    struct Anchor: Codable {
        var duration: TimeInterval
        var uptime: TimeInterval
        var bootID: String? = nil
    }

    private let bootID: String?
    private(set) var anchor: Anchor?

    init(
        anchor: Anchor? = nil,
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
        bootID: String? = CloudKitBootIdentity.current()
    ) {
        self.bootID = bootID?.isEmpty == false ? bootID : nil
        if let anchor, anchor.duration.isFinite, anchor.duration > 0,
           anchor.uptime.isFinite, anchor.uptime >= 0 {
            if let currentBootID = self.bootID,
               anchor.bootID == currentBootID, anchor.uptime <= uptime {
                // Relaunches during this boot share the same monotonic clock.
                self.anchor = anchor
            } else {
                // Unknown or changed boot identity cannot establish elapsed
                // time, even when the new uptime exceeds the saved value.
                self.anchor = Anchor(
                    duration: anchor.duration, uptime: uptime,
                    bootID: self.bootID
                )
            }
        }
    }

    var notBefore: Date? { deadline(at: Date()) }

    func deadline(
        at now: Date,
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Date? {
        remaining(at: now, uptime: uptime).map { now.addingTimeInterval($0) }
    }

    mutating func observe(
        retryAfter seconds: Double?, now: Date,
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        guard let seconds, seconds.isFinite, seconds > 0,
              seconds > (remaining(at: now, uptime: uptime) ?? 0) else {
            return false
        }
        anchor = Anchor(duration: seconds, uptime: uptime, bootID: bootID)
        return true
    }

    func remaining(
        at now: Date,
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> TimeInterval? {
        guard let anchor else { return nil }
        let elapsed = max(0, uptime - anchor.uptime)
        let interval = anchor.duration - elapsed
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
        if let scope = errors.first(where: {
            $0 as? SyncError == .scopeChanged
        }) { return scope }
        if let update = errors.first(where: {
            guard let sync = $0 as? SyncError else { return false }
            if case .updateRequired = sync { return true }
            return false
        }) { return update }
        return errors.first(where: {
            !NotebookSyncRetryPolicy.isTransient($0)
        })
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
    private struct State: Codable {
        var retryNotBefore: Date?
        var anchor: CloudKitRetryThrottle.Anchor?
        var completed: Bool?
        var recoveredInvalidRetryDeadline = false

        private enum CodingKeys: String, CodingKey {
            case retryNotBefore, anchor, completed
        }

        init(
            retryNotBefore: Date?, anchor: CloudKitRetryThrottle.Anchor?,
            completed: Bool?
        ) {
            self.retryNotBefore = retryNotBefore
            self.anchor = anchor
            self.completed = completed
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            anchor = try values.decodeIfPresent(
                CloudKitRetryThrottle.Anchor.self, forKey: .anchor
            )
            completed = try values.decodeIfPresent(Bool.self, forKey: .completed)
            do {
                retryNotBefore = try values.decodeIfPresent(
                    Date.self, forKey: .retryNotBefore
                )
            } catch let error as DecodingError {
                // The anchor independently preserves the server's wait.
                // Its validity is checked before using or persisting it.
                guard anchor != nil else { throw error }
                retryNotBefore = nil
                recoveredInvalidRetryDeadline = true
            }
        }
    }

    private let fileURL: URL
    private let bootID: String?
    private(set) var throttle: CloudKitRetryThrottle
    private(set) var completed = false
    private(set) var recoveredRetryMetadata = false

    // The old file was atomically renamed shortly after the retry was
    // observed. Its modification time therefore preserves the old clock's
    // era, even if the device calendar has since been corrected.
    private static let legacyWriteMargin: TimeInterval = 60
    private static let maximumLegacyDelay: TimeInterval = 7 * 24 * 60 * 60

    init(
        directory: URL, now: Date = Date(),
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
        persistOnLoad: Bool = true,
        bootIDProvider: () -> String? = CloudKitBootIdentity.current
    ) throws {
        bootID = bootIDProvider()
        fileURL = directory.appendingPathComponent(
            "cloudkit-availability-retry.json"
        )
        var needsPersistence = false
        do {
            let state = try JSONDecoder().decode(
                State.self, from: Data(contentsOf: fileURL)
            )
            if let anchor = state.anchor,
               !anchor.duration.isFinite || anchor.duration <= 0
                || !anchor.uptime.isFinite || anchor.uptime < 0 {
                throw CloudKitSyncTransportError.unrecoverableRetryDelay
            }
            if state.completed == true,
               state.anchor != nil || state.retryNotBefore != nil {
                throw CloudKitSyncTransportError.corruptState
            }
            let recoveredAnchor: CloudKitRetryThrottle.Anchor?
            if state.anchor == nil, let deadline = state.retryNotBefore {
                let attributes = try? FileManager.default.attributesOfItem(
                    atPath: fileURL.path
                )
                recoveredAnchor = try Self.recoverLegacyAnchor(
                    deadline: deadline,
                    writeDate: attributes?[.modificationDate] as? Date,
                    uptime: uptime
                )
            } else {
                recoveredAnchor = state.anchor
            }
            throttle = CloudKitRetryThrottle(
                anchor: recoveredAnchor, uptime: uptime, bootID: bootID
            )
            completed = state.completed == true
            recoveredRetryMetadata = state.recoveredInvalidRetryDeadline
            needsPersistence = !completed && persistOnLoad
        } catch CocoaError.fileReadNoSuchFile {
            throttle = CloudKitRetryThrottle(bootID: bootID)
        } catch is DecodingError {
            throttle = CloudKitRetryThrottle(bootID: bootID)
            completed = true
            recoveredRetryMetadata = true
            needsPersistence = persistOnLoad
        } catch is CloudKitSyncTransportError {
            // This file contains only retry metadata. Recover it without
            // discarding any of the account-bound transport state.
            throttle = CloudKitRetryThrottle(bootID: bootID)
            completed = true
            recoveredRetryMetadata = true
            needsPersistence = persistOnLoad
        } catch {
            throw CloudKitSyncTransportError.corruptState
        }
        if needsPersistence { try persist(now: now, uptime: uptime) }
    }

    static func recoverLegacyAnchor(
        deadline: Date, writeDate: Date?, uptime: TimeInterval
    ) throws -> CloudKitRetryThrottle.Anchor {
        guard let writeDate else {
            throw CloudKitSyncTransportError.unrecoverableRetryDelay
        }
        let elapsed = deadline.timeIntervalSince(writeDate)
        guard elapsed.isFinite, elapsed > 0,
              uptime.isFinite, uptime >= 0,
              elapsed <= maximumLegacyDelay else {
            throw CloudKitSyncTransportError.unrecoverableRetryDelay
        }
        return .init(duration: elapsed + legacyWriteMargin, uptime: uptime)
    }

    var notBefore: Date? { throttle.notBefore }

    mutating func reconciledDeadline(
        saved: Date?, now: Date,
        uptime: TimeInterval
    ) throws -> Date? {
        if throttle.anchor == nil, saved != nil, !completed {
            // Mark recovery durably before clearing the duplicate deadline.
            // If that second write fails, a relaunch can finish the repair.
            try SyncFileIO.replace(
                JSONEncoder().encode(State(
                    retryNotBefore: nil, anchor: nil, completed: true
                )),
                at: fileURL
            )
            completed = true
            recoveredRetryMetadata = true
        }
        return throttle.deadline(at: now, uptime: uptime)
    }

    mutating func wait() async throws {
        try await wait(
            now: { Date() },
            uptime: { ProcessInfo.processInfo.systemUptime },
            sleep: { try await Task.sleep(for: .seconds($0)) }
        )
    }

    mutating func wait(
        now: () -> Date,
        uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: (TimeInterval) async throws -> Void
    ) async throws {
        while let remaining = throttle.remaining(
            at: now(), uptime: uptime()
        ) {
            try await sleep(remaining)
        }
        try completeIfElapsed(now: now(), uptime: uptime())
    }

    mutating func completeIfElapsed(
        now: Date = Date(),
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) throws {
        guard throttle.anchor != nil,
              throttle.remaining(at: now, uptime: uptime) == nil else {
            return
        }
        try SyncFileIO.replace(
            JSONEncoder().encode(State(
                retryNotBefore: nil, anchor: nil, completed: true
            )),
            at: fileURL
        )
        throttle = CloudKitRetryThrottle(bootID: bootID)
        completed = true
    }

    mutating func observe(_ error: Error, now: Date = Date()) throws {
        try merge(
            retryAfter: CloudKitRetryMetadata.seconds(in: error), now: now
        )
    }

    mutating func merge(
        retryAfter: Double?, now: Date,
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) throws {
        guard throttle.observe(
            retryAfter: retryAfter, now: now, uptime: uptime
        ) else { return }
        completed = false
        try persist(now: now, uptime: uptime)
    }

    private func persist(
        now: Date = Date(),
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) throws {
        try SyncFileIO.replace(
            JSONEncoder().encode(State(
                retryNotBefore: throttle.deadline(at: now, uptime: uptime),
                anchor: throttle.anchor, completed: completed
            )),
            at: fileURL
        )
    }
}

@available(macOS 14.0, iOS 17.0, *)
public final actor CloudKitSyncTransport: HaltableSyncTransport {
    public nonisolated let scope: String
    public nonisolated let notebookZoneName: String
    public nonisolated let activity: AsyncStream<CloudKitSyncActivity>
    public private(set) var recoveredRetryMetadata = false

    private static let pageSize = 100

    private let account: any CloudKitAccountClient
    private let database: any CloudKitDatabaseClient
    private let engineFactory: CloudKitSyncEngineFactory
    private let expectedUserRecordID: CKRecord.ID
    private let zoneID: CKRecordZone.ID
    private let mode: CloudKitTransportMode
    private let maximumSupportedFormatVersion: UInt64
    private let codec: CloudKitRecordCodec
    private let store: CloudKitTransportStateStore
    private let eventCommitter: CloudKitEventCommitter
    private let assetDirectory: URL
    private let automaticallySync: Bool
    private var assetStaging: CloudKitAssetStaging
    private var engineAssetLeases: [String: [URL]] = [:]
    private var batchStagingFailure: Error?
    private var availabilityCooldown: CloudKitAvailabilityCooldownStore
    private var engine: (any CloudKitSyncEngineClient)!
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
    private var bootstrapValidationCache = CloudKitBootstrapValidationCache()
    #if DEBUG
    private var labRequestTimingSamples: [String: [Double]]?
    #endif

    public static func persistedRetryNotBefore(
        stateDirectory: URL
    ) throws -> Date? {
        try CloudKitAvailabilityCooldownStore(
            directory: stateDirectory, persistOnLoad: false
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

    #if DEBUG
    /// Opt-in, fictional-data CloudKit lab. The signed caller must be verified
    /// as using the Development environment before invoking this factory.
    /// Lab state is nested below the supplied base directory and never shares
    /// the canonical notebook's CloudKit state file.
    @_spi(SyncLab)
    public static func makeIsolatedNotebookLab(
        containerIdentifier: String,
        stateDirectory: URL,
        runID: UUID
    ) async throws -> CloudKitSyncTransport {
        try await make(
            containerIdentifier: containerIdentifier,
            stateDirectory: CloudKitNotebookLabScope.stateDirectory(
                base: stateDirectory, runID: runID
            ),
            zoneName: CloudKitNotebookLabScope.zoneName(runID: runID),
            mode: .notebook,
            automaticallySync: false,
            labRunID: runID
        )
    }
    #endif

    /// Notebook transport over substitute CloudKit services, for tests.
    static func makeNotebook(
        services: CloudKitServices,
        containerIdentifier: String,
        stateDirectory: URL,
        maximumSupportedFormatVersion: UInt64 =
            NotebookSyncFormat.supportedVersion
    ) async throws -> CloudKitSyncTransport {
        try await make(
            containerIdentifier: containerIdentifier,
            stateDirectory: stateDirectory,
            zoneName: CloudKitTransportMode.notebook.zoneName,
            mode: .notebook,
            automaticallySync: false,
            maximumSupportedFormatVersion: maximumSupportedFormatVersion,
            services: services
        )
    }

    private static func make(
        containerIdentifier: String,
        stateDirectory: URL,
        zoneName: String,
        mode: CloudKitTransportMode,
        automaticallySync: Bool,
        expectedScope: String? = nil,
        expectedNotebookID: UUID? = nil,
        labRunID: UUID? = nil,
        maximumSupportedFormatVersion: UInt64 =
            NotebookSyncFormat.supportedVersion,
        services: CloudKitServices? = nil
    ) async throws -> CloudKitSyncTransport {
        if let labRunID {
            guard mode == .notebook else { throw SyncError.scopeChanged }
            try CloudKitNotebookLabScope.validate(
                zoneName: zoneName, runID: labRunID
            )
        } else {
            try mode.validate(zoneName: zoneName)
        }
        var availabilityCooldown = try CloudKitAvailabilityCooldownStore(
            directory: stateDirectory
        )
        try await availabilityCooldown.wait()
        let services = services
            ?? .system(containerIdentifier: containerIdentifier)
        let accountStatus: CKAccountStatus
        do {
            accountStatus = try await services.account.accountStatus()
        } catch {
            try availabilityCooldown.observe(error)
            throw error
        }
        guard accountStatus == .available else {
            throw CloudKitSyncTransportError.accountUnavailable
        }
        let userRecordID: CKRecord.ID
        do {
            userRecordID = try await services.account.userRecordID()
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
            services: services,
            userRecordID: userRecordID,
            zoneName: zoneName,
            stateDirectory: stateDirectory,
            store: store,
            availabilityCooldown: availabilityCooldown,
            mode: mode,
            automaticallySync: automaticallySync,
            maximumSupportedFormatVersion: maximumSupportedFormatVersion
        )
        try await transport.initialize()
        #if DEBUG
        if labRunID != nil { await transport.enableLabRequestTimings() }
        #endif
        return transport
    }

    #if DEBUG
    private func enableLabRequestTimings() {
        labRequestTimingSamples = [:]
    }

    /// Elapsed milliseconds per lab request. Each sample includes any retry
    /// cooldown wait, the CloudKit call, and error cooldown persistence. A
    /// failed request is recorded too. Requests not explicitly named use
    /// `other`; no account identity or record contents are retained.
    @_spi(SyncLab)
    public func labRequestTimings() -> [String: [Double]] {
        labRequestTimingSamples ?? [:]
    }
    #endif

    private init(
        containerIdentifier: String,
        services: CloudKitServices,
        userRecordID: CKRecord.ID,
        zoneName: String,
        stateDirectory: URL,
        store: CloudKitTransportStateStore,
        availabilityCooldown: CloudKitAvailabilityCooldownStore,
        mode: CloudKitTransportMode,
        automaticallySync: Bool,
        maximumSupportedFormatVersion: UInt64
    ) {
        account = services.account
        database = services.database
        engineFactory = services.makeEngine
        expectedUserRecordID = userRecordID
        let zoneID = CKRecordZone.ID(zoneName: zoneName)
        self.zoneID = zoneID
        notebookZoneName = zoneName
        self.mode = mode
        self.maximumSupportedFormatVersion = maximumSupportedFormatVersion
        codec = CloudKitRecordCodec(
            mode: mode, zoneID: zoneID,
            maximumSupportedFormatVersion: maximumSupportedFormatVersion
        )
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
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        retryThrottle = availabilityCooldown.throttle
        let deadline = try availabilityCooldown.reconciledDeadline(
            saved: saved.retryNotBefore, now: now, uptime: uptime
        )
        recoveredRetryMetadata = availabilityCooldown.recoveredRetryMetadata
            || saved.recoveredInvalidRetryDeadline
        if saved.retryNotBefore != deadline || saved.recoveredInvalidRetryDeadline {
            try await store.update {
                $0.retryNotBefore = deadline
                $0.recoveredInvalidRetryDeadline = false
            }
        }
        engine = try engineFactory(
            saved.engineState, self, automaticallySync
        )
        let oversizedOutbox = try CloudKitSnapshotSizeLimit.partition(
            Array(saved.outbox.values)
        ).rejected
        let oversizedIDs = Set(oversizedOutbox.map(\.id))
        if !oversizedIDs.isEmpty {
            // Preserve the durable records: an older build may have staged
            // unique history. Only retire their CK save requests so they
            // cannot block smaller records after this transport restarts.
            let queuedOversizedSaves = engine.pendingRecordZoneChanges
                .filter { change in
                    guard case let .saveRecord(id) = change else {
                        return false
                    }
                    return oversizedIDs.contains(id.recordName)
                }
            engine.remove(
                pendingRecordZoneChanges: queuedOversizedSaves
            )
            if let record = oversizedOutbox.first {
                let error = CloudKitSyncTransportError.snapshotTooLarge(
                    documentID: record.snapshot.noteID, kind: record.kind
                )
                lastReportedFailure = error
                activityChannel.yield([.failed(error.localizedDescription)])
            }
        }
        let queuedSaves = Set(
            engine.pendingRecordZoneChanges.compactMap { change in
                if case let .saveRecord(id) = change {
                    return id.recordName
                }
                return nil
            }
        )
        let missingSaves = saved.outbox.keys.filter {
            !queuedSaves.contains($0) && !oversizedIDs.contains($0)
        }.map { name in
            CKSyncEngine.PendingRecordZoneChange.saveRecord(
                CKRecord.ID(recordName: name, zoneID: zoneID)
            )
        }
        if !missingSaves.isEmpty {
            engine.add(pendingRecordZoneChanges: missingSaves)
        }
        if mode == .notebook, !saved.outbox.isEmpty {
            engine.add(pendingRecordZoneChanges: [
                .saveRecord(CKRecord.ID(
                    recordName: mode.bootstrapName, zoneID: zoneID
                ))
            ])
        }
    }

    public func bootstrap(proposing record: SyncRecord) async throws -> SyncRecord {
        try await assertHealthy()
        let proposal = try bootstrapValidationCache.validate(
            record, mode: mode
        )
        if mode == .notebook,
           maximumSupportedFormatVersion <
                NotebookSyncFormat.supportedVersion {
            let version = try NotebookSyncFormat.version(
                of: proposal.record
            )
            if version > maximumSupportedFormatVersion {
                throw SyncError.updateRequired(requiredVersion: version)
            }
        }
        try await verifyAccount()
        let recordID = CKRecord.ID(
            recordName: mode.bootstrapName, zoneID: zoneID
        )
        do {
            let existing = try await CloudKitBootstrapZoneRetry.perform {
                try await cloudRequest(labLabel: "bootstrap.readCanonical") {
                    try await database.record(for: recordID)
                }
            } ensureZone: {
                try await ensureZone()
            }
            if mode == .notebook {
                do {
                    try CloudKitNotebookFormatGate.read(existing)
                        .requireSupported(
                            maximumVersion: maximumSupportedFormatVersion
                        )
                } catch let error as SyncError {
                    latchFailure(error)
                    throw error
                }
            }
            let canonical = try codec.decodeBootstrap(
                existing, using: &bootstrapValidationCache
            )
            try await store.update { try $0.appendToInbox(canonical) }
            return canonical.record
        } catch let error as CKError where error.code == .unknownItem {
            let proposalFormatVersion = try NotebookSyncFormat.version(
                of: proposal.record
            )
            let assetURL = try assetStaging.retain(proposal.record)
            var uploadCompleted = false
            defer {
                assetStaging.release(
                    assetURL,
                    uploadCompleted: uploadCompleted || isRetired
                )
            }
            let cloudRecord = try makeCloudRecord(
                proposal.record, id: recordID, assetURL: assetURL
            )
            if mode == .notebook {
                try CloudKitNotebookFormatGate(
                    minimumReaderVersion: 1,
                    minimumWriterVersion: 1,
                    catalogFormatVersion: 1,
                    migrationSnapshotID: nil
                ).publish(
                    on: cloudRecord,
                    catalogVersion: proposalFormatVersion,
                    snapshotID: proposalFormatVersion > 1
                        ? proposal.record.id : nil,
                    maximumVersion: maximumSupportedFormatVersion
                )
            }
            do {
                _ = try await CloudKitBootstrapZoneRetry.perform {
                    try await cloudRequest(labLabel: "bootstrap.saveCanonical") {
                        try await database.save(cloudRecord)
                    }
                } ensureZone: {
                    try await ensureZone()
                }
                try await store.update { try $0.appendToInbox(proposal) }
                uploadCompleted = true
                return proposal.record
            } catch let conflict as CKError
                where conflict.code == .serverRecordChanged {
                await observeRetryAfter(conflict)
                let server = try await cloudRequest(labLabel: "bootstrap.readCanonical") {
                    try await database.record(for: recordID)
                }
                if mode == .notebook {
                    do {
                        try CloudKitNotebookFormatGate.read(server)
                            .requireSupported(
                                maximumVersion: maximumSupportedFormatVersion
                            )
                    } catch let error as SyncError {
                        latchFailure(error)
                        throw error
                    }
                }
                let canonical = try codec.decodeBootstrap(
                    server, using: &bootstrapValidationCache
                )
                try await store.update { try $0.appendToInbox(canonical) }
                uploadCompleted = true
                return canonical.record
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
        for record in records {
            try record.validate()
            guard record.protocolVersion == mode.protocolVersion else {
                throw SyncError.invalidRecord
            }
            if mode == .notebook, record.kind == .catalog,
               maximumSupportedFormatVersion <
                    NotebookSyncFormat.supportedVersion {
                let version = try NotebookSyncFormat.version(of: record)
                if version > maximumSupportedFormatVersion {
                    throw SyncError.updateRequired(
                        requiredVersion: version
                    )
                }
            }
        }
        try await verifyAccount()
        let deletedNoteIDs = await store.snapshot().deletedNoteIDs
        let suppressedIDs = Set(records.compactMap { record in
            record.kind == .note
                && deletedNoteIDs.contains(record.snapshot.noteID)
                ? record.id : nil
        })
        let activeRecords = records.filter {
            !suppressedIDs.contains($0.id)
        }
        let partition = try CloudKitSnapshotSizeLimit.partition(activeRecords)
        let records = partition.admitted
        let oversizedError = partition.rejected.first.map {
            CloudKitSyncTransportError.snapshotTooLarge(
                documentID: $0.snapshot.noteID, kind: $0.kind
            )
        }
        guard !records.isEmpty else {
            return SyncBatchResult(
                acknowledgedIDs: suppressedIDs, error: oversizedError
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
        engine.add(
            pendingRecordZoneChanges: recordIDs.map { .saveRecord($0) }
        )
        let scopedRecordIDs: [CKRecord.ID]
        if mode == .notebook {
            let canonicalID = CKRecord.ID(
                recordName: mode.bootstrapName, zoneID: zoneID
            )
            engine.add(pendingRecordZoneChanges: [
                .saveRecord(canonicalID)
            ])
            scopedRecordIDs = recordIDs + [canonicalID]
        } else {
            scopedRecordIDs = recordIDs
        }
        let sendError: Error?
        do {
            try await cloudRequest(labLabel: "publish.engineSend") {
                try await engine.sendChanges(
                    .init(scope: .recordIDs(scopedRecordIDs))
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
            error: result.error ?? oversizedError
        )
    }

    public func fetch(after cursor: String?) async throws -> SyncPage {
        try await assertHealthy()
        try await verifyAccount()
        if mode == .notebook {
            _ = try await currentNotebookGate()
        }
        let current = await store.snapshot()
        if current.unresolvedRemoteDeletionRecordIDs.isEmpty {
            if let buffered = try current.bufferedPage(
                after: cursor,
                limit: Self.pageSize
            ) {
                return buffered
            }
        }
        try await cloudRequest(labLabel: "fetch.engineFetch") {
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
        _ = try await currentNotebookGate()
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
            try await cloudRequest(labLabel: "purge.engineFetch") {
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
        engine.remove(pendingRecordZoneChanges: changes)
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
            let completed = try await deleteBatchWithFence(ids)
            if !completed.isEmpty {
                try await store.update {
                    $0.pendingRemoteDeletionIDs.subtract(completed)
                }
            }
        }
    }

    public func retryNotBefore() async -> Date? {
        retryThrottle.notBefore
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
        let status = try await cloudRequest(labLabel: "verifyAccount.accountStatus") {
            try await account.accountStatus()
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
        let currentUser = try await cloudRequest(labLabel: "verifyAccount.userRecordID") {
            try await account.userRecordID()
        }
        guard currentUser == expectedUserRecordID else {
            latchFailure(SyncError.scopeChanged)
            throw SyncError.scopeChanged
        }
    }

    private func cloudRequest<T>(
        labLabel: String = "other",
        _ operation: () async throws -> T
    ) async throws -> T {
        #if DEBUG
        let started = labRequestTimingSamples == nil ? nil : ContinuousClock.now
        defer {
            if let started, labRequestTimingSamples != nil {
                let duration = started.duration(to: .now).components
                let milliseconds = Double(duration.seconds) * 1_000
                    + Double(duration.attoseconds) / 1_000_000_000_000_000
                labRequestTimingSamples?[labLabel, default: []].append(
                    milliseconds
                )
            }
        }
        #endif
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
        try availabilityCooldown.completeIfElapsed()
        retryThrottle = availabilityCooldown.throttle
    }

    private func observeRetryAfter(_ error: Error) async {
        guard !isRetired else { return }
        let delay = CloudKitRetryMetadata.seconds(in: error)
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        guard retryThrottle.observe(
            retryAfter: delay, now: now, uptime: uptime
        ) else {
            return
        }
        let deadline = retryThrottle.deadline(at: now, uptime: uptime)
        do {
            do {
                try availabilityCooldown.merge(
                    retryAfter: delay, now: now, uptime: uptime
                )
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

    private func haltForDeletedZone() async throws {
        unexpectedDeletionObserved = true
        latchFailure(CloudKitSyncTransportError.unexpectedDeletion)
        try await store.update { $0.hasUnexpectedDeletion = true }
        lastReportedFailure = CloudKitSyncTransportError.unexpectedDeletion
    }

    private func ensureZone() async throws {
        let result = try await cloudRequest(labLabel: "ensureZone.recordZones") {
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
        // Only a first join may create the zone. Once this device has joined,
        // a missing zone means the cloud data was deleted; re-creating it
        // would silently re-seed iCloud before anyone decided to.
        guard await store.snapshot().inbox.isEmpty else {
            try await haltForDeletedZone()
            throw CloudKitSyncTransportError.unexpectedDeletion
        }
        let saved = try await cloudRequest(labLabel: "ensureZone.createZone") {
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

    private func currentNotebookGate() async throws ->
        CloudKitNotebookFormatGate {
        let id = CKRecord.ID(
            recordName: mode.bootstrapName, zoneID: zoneID
        )
        let record: CKRecord
        do {
            record = try await cloudRequest(
                labLabel: "format.readCanonical"
            ) { try await database.record(for: id) }
        } catch let error as CKError where
            error.code == .unknownItem || error.code == .zoneNotFound {
            try await haltForDeletedZone()
            throw CloudKitSyncTransportError.unexpectedDeletion
        }
        do {
            let gate = try CloudKitNotebookFormatGate.read(record)
            try gate.requireSupported(
                maximumVersion: maximumSupportedFormatVersion
            )
            return gate
        } catch {
            latchFailure(error)
            throw error
        }
    }

    /// Fetches the live canonical record for each notebook publication. Its
    /// server change tag is submitted with the snapshots in one atomic zone
    /// batch, so a competing format migration invalidates this publication.
    private func fencedNotebookBatch(
        _ records: [CKRecord], outbox: [String: SyncRecord]
    ) async throws -> CKSyncEngine.RecordZoneChangeBatch {
        let canonicalID = CKRecord.ID(
            recordName: mode.bootstrapName, zoneID: zoneID
        )
        try await verifyAccount()
        let canonical: CKRecord
        do {
            canonical = try await cloudRequest(
                labLabel: "publication.readCanonical"
            ) {
                try await database.record(for: canonicalID)
            }
        } catch let error as CKError where
            error.code == .unknownItem || error.code == .zoneNotFound {
            try await haltForDeletedZone()
            throw CloudKitSyncTransportError.unexpectedDeletion
        }
        let gate = try CloudKitNotebookFormatGate.read(canonical)
        try gate.requireSupported(
            maximumVersion: maximumSupportedFormatVersion
        )
        // Retain the seed CKAsset before CloudKit reclaims its temporary URL.
        let seed = try codec.decode(canonical)
        let seedURL = try assetStaging.retain(seed)
        do {
            canonical["document"] = CKAsset(fileURL: seedURL)
            let candidate = try records.compactMap { cloud ->
                (version: UInt64, id: String)? in
                guard let value = outbox[cloud.recordID.recordName],
                      value.kind == .catalog else { return nil }
                return (try NotebookSyncFormat.version(of: value), value.id)
            }.max { $0.version < $1.version }
            try gate.publish(
                on: canonical,
                catalogVersion: candidate?.version,
                snapshotID: candidate?.id,
                maximumVersion: maximumSupportedFormatVersion
            )
            try await verifyAccount()
            engineAssetLeases[canonicalID.recordName, default: []]
                .append(seedURL)
            return CKSyncEngine.RecordZoneChangeBatch(
                recordsToSave: records + [canonical],
                recordIDsToDelete: [], atomicByZone: true
            )
        } catch {
            assetStaging.release(seedURL, uploadCompleted: true)
            throw error
        }
    }

    private func deleteBatchWithFence(
        _ ids: [CKRecord.ID]
    ) async throws -> Set<String> {
        var remaining = ids
        var completed = Set<String>()
        for _ in 0..<3 {
            guard !remaining.isEmpty else { return completed }
            let control = try await fencedNotebookBatch([], outbox: [:])
            defer {
                releaseEngineAssetLease(
                    for: mode.bootstrapName, uploadCompleted: true
                )
            }
            let results = try await cloudRequest(
                labLabel: "purge.atomicDelete"
            ) {
                try await database.modifyRecords(
                    saving: control.recordsToSave,
                    deleting: remaining,
                    savePolicy: .ifServerRecordUnchanged,
                    atomically: true
                )
            }
            let canonicalID = control.recordsToSave[0].recordID
            if case let .failure(error)? =
                results.saveResults[canonicalID] {
                if let cloud = error as? CKError,
                   cloud.code == .serverRecordChanged,
                   let server = cloud.serverRecord {
                    do {
                        try CloudKitNotebookFormatGate.read(server)
                            .requireSupported(
                                maximumVersion: maximumSupportedFormatVersion
                            )
                    } catch {
                        latchFailure(error)
                        throw error
                    }
                } else if let cloud = error as? CKError,
                          cloud.code == .batchRequestFailed {
                    // An already-deleted record can fail the atomic batch.
                    // Inspect the deletion results and retry the rest.
                } else {
                    throw error
                }
            }
            var retry: [CKRecord.ID] = []
            var firstFailure: Error?
            for id in remaining {
                switch results.deleteResults[id] {
                case .success(_)? :
                    completed.insert(id.recordName)
                case .failure(let error as CKError)?
                    where error.code == .unknownItem:
                    completed.insert(id.recordName)
                case .failure(let error)? :
                    retry.append(id)
                    if let cloud = error as? CKError,
                       cloud.code == .batchRequestFailed {
                        continue
                    }
                    firstFailure = firstFailure ?? error
                case nil:
                    retry.append(id)
                    firstFailure = firstFailure ??
                        CloudKitSyncTransportError.uploadNotAcknowledged
                }
            }
            if let firstFailure { throw firstFailure }
            remaining = retry
        }
        throw CloudKitSyncTransportError.uploadNotAcknowledged
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

    private func outgoingRecords(
        pending: [CKSyncEngine.PendingRecordZoneChange],
        outbox: [String: SyncRecord]
    ) throws -> [String: SyncRecord] {
        try assertActive()
        if let delegateFailure { throw delegateFailure }
        guard !unexpectedDeletionObserved else {
            throw CloudKitSyncTransportError.unexpectedDeletion
        }
        let partition = try CloudKitSnapshotSizeLimit.partitionPendingSaves(
            pending, outbox: outbox, zoneID: zoneID
        )
        if !partition.rejected.isEmpty {
            // Recheck every batch: CK may restore a save request after startup.
            // Retire only the request, keeping its unique durable history.
            engine.remove(pendingRecordZoneChanges: partition.rejected)
            if case let .saveRecord(id) = partition.rejected[0],
               let value = outbox[id.recordName] {
                let error = CloudKitSyncTransportError.snapshotTooLarge(
                    documentID: value.snapshot.noteID, kind: value.kind
                )
                lastReportedFailure = error
                yieldAfterDelegateReturns([.failed(error.localizedDescription)])
            }
        }
        var records: [String: SyncRecord] = [:]
        for change in partition.admitted {
            guard case let .saveRecord(recordID) = change,
                  recordID.zoneID == zoneID,
                  let value = outbox[recordID.recordName] else {
                continue
            }
            records[recordID.recordName] = value
        }
        return records
    }

    /// Stages one record the batch includes. The batch provider cannot
    /// throw, so the first failure is kept and reported once it is built.
    private func stageEngineRecord(
        _ value: SyncRecord, id: CKRecord.ID
    ) -> CKRecord? {
        guard batchStagingFailure == nil else { return nil }
        do {
            let assetURL = try assetStaging.retain(value)
            do {
                let record = try codec.encode(value, id: id, assetURL: assetURL)
                engineAssetLeases[id.recordName, default: []].append(assetURL)
                return record
            } catch {
                assetStaging.release(assetURL, uploadCompleted: false)
                throw error
            }
        } catch {
            batchStagingFailure = error
            return nil
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
        await handle(CloudKitEngineEvent(event), from: syncEngine)
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0)
        }
        return await nextRecordZoneChangeBatch(
            pending: pending, from: syncEngine
        )
    }
}

extension CloudKitSyncTransport {
    func handle(
        _ event: CloudKitEngineEvent,
        from syncEngine: any CloudKitSyncEngineClient
    ) async {
        if isRetired {
            if retiredEngineID == ObjectIdentifier(syncEngine),
               let sent = event.sentRecordIDs {
                // CK may report a completed operation after cancellation.
                // Its asset paths belong only to this transport generation.
                for id in sent.saved + sent.failed {
                    releaseEngineAssetLease(for: id, uploadCompleted: true)
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
                if let sent = event.sentRecordIDs {
                    for id in sent.saved + sent.failed {
                        releaseEngineAssetLease(
                            for: id, uploadCompleted: true
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
                let data = try update.get()
                try await eventCommitter.commitEngineState(data)
            case let .fetchedRecordZoneChanges(modifications, deletions):
                if mode == .notebook {
                    for canonical in modifications where
                        canonical.recordID.zoneID == zoneID &&
                        canonical.recordID.recordName == mode.bootstrapName {
                        try CloudKitNotebookFormatGate.read(canonical)
                            .requireSupported(
                                maximumVersion: maximumSupportedFormatVersion
                            )
                    }
                }
                let targetDeletions = deletions.filter {
                    $0.zoneID == zoneID
                }
                let recordNames = Set(targetDeletions.map(\.recordName))
                let records = try modifications
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
            case let .sentRecordZoneChanges(savedCloudRecords, failedSaves):
                let savedIDs = Set(savedCloudRecords.map {
                    $0.recordID.recordName
                })
                let failedIDs = Set(failedSaves.map {
                    $0.record.recordID.recordName
                })
                var durablyCommittedIDs = Set<String>()
                if mode == .notebook,
                   savedIDs.contains(mode.bootstrapName) {
                    durablyCommittedIDs.insert(mode.bootstrapName)
                }
                defer {
                    for id in savedIDs {
                        releaseEngineAssetLease(
                            for: id,
                            uploadCompleted: id == mode.bootstrapName
                                || isRetired
                                || delegateFailure != nil
                                || durablyCommittedIDs.contains(id)
                        )
                    }
                    for id in failedIDs {
                        releaseEngineAssetLease(
                            for: id,
                            uploadCompleted: id == mode.bootstrapName
                                || isRetired
                                || delegateFailure != nil
                                || durablyCommittedIDs.contains(id)
                        )
                    }
                }
                let savedRecords = try savedCloudRecords.filter { record in
                    mode != .notebook ||
                        record.recordID.recordName != mode.bootstrapName
                }.map { record in
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
                if mode == .notebook,
                   savedIDs.contains(mode.bootstrapName),
                   !(await store.snapshot().outbox.isEmpty) {
                    syncEngine.add(pendingRecordZoneChanges: [
                        .saveRecord(CKRecord.ID(
                            recordName: mode.bootstrapName, zoneID: zoneID
                        ))
                    ])
                }
                for failure in failedSaves {
                    await observeRetryAfter(failure.error)
                    if let delegateFailure { throw delegateFailure }
                    let id = failure.record.recordID.recordName
                    if mode == .notebook && id == mode.bootstrapName {
                        if failure.error.code == .serverRecordChanged,
                           let server = failure.error.serverRecord {
                            let gate = try CloudKitNotebookFormatGate
                                .read(server)
                            try gate.requireSupported(
                                maximumVersion: maximumSupportedFormatVersion
                            )
                            // An ordinary competing publication is benign.
                            // Keep the durable outbox for a fresh CAS batch.
                            syncEngine.add(pendingRecordZoneChanges: [
                                .saveRecord(failure.record.recordID)
                            ])
                            for other in failedSaves where
                                other.record.recordID.recordName != id {
                                syncEngine.add(pendingRecordZoneChanges: [
                                    .saveRecord(other.record.recordID)
                                ])
                            }
                        } else if failure.error.code == .zoneNotFound {
                            try await haltForDeletedZone()
                        } else {
                            lastReportedFailure = failure.error
                        }
                        continue
                    }
                    if failure.error.code == .serverRecordChanged {
                        do {
                            // CloudKit attaches the conflicting record; never
                            // make a request from inside an engine callback.
                            guard let server = failure.error.serverRecord else {
                                throw CloudKitSyncTransportError
                                    .invalidRemoteRecord
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
                            syncEngine.remove(
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
                    } else if failure.error.code == .zoneNotFound {
                        // Uploads only follow a join, so the zone was
                        // deleted remotely. Never re-create it here.
                        try await haltForDeletedZone()
                        if awaitedUploadIDs.contains(id) {
                            failedUploads[id] =
                                CloudKitSyncTransportError.unexpectedDeletion
                        }
                        activities.append(.failed(
                            CloudKitSyncTransportError.unexpectedDeletion
                                .localizedDescription
                        ))
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
                switch change {
                case let .signIn(currentUser)
                    where currentUser == expectedUserRecordID:
                    break
                case .signIn, .signOut, .switchAccounts:
                    latchFailure(SyncError.scopeChanged)
                }
                activities.append(.accountChanged)
            case let .fetchedDatabaseChanges(deletedZoneIDs):
                if deletedZoneIDs.contains(zoneID) {
                    try await haltForDeletedZone()
                    activities.append(.failed(
                        CloudKitSyncTransportError.unexpectedDeletion
                            .localizedDescription
                    ))
                }
            case let .didFetchRecordZoneChanges(completedZoneID, error):
                if completedZoneID == zoneID, let error {
                    await observeRetryAfter(error)
                    if let delegateFailure { throw delegateFailure }
                    lastReportedFailure = error
                    activities.append(.failed(error.localizedDescription))
                }
            case let .didFetchChanges(scheduled):
                do {
                    try await eventCommitter.finishFetch()
                    let reason: CloudKitSyncReason =
                        scheduled ? .scheduled : .manual
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
            case let .didSendChanges(scheduled):
                if let activity = activityTracker.finishSend(
                    wasScheduled: scheduled
                ) {
                    activities.append(activity)
                }
            case .other:
                break
            }
        } catch {
            guard !isRetired else { return }
            latchFailure(error)
            lastReportedFailure = error
            activities.append(.failed(error.localizedDescription))
            if let sent = event.sentRecordIDs {
                for id in sent.saved where awaitedUploadIDs.contains(id) {
                    failedUploads[id] = error
                }
            }
        }
    }

    func nextRecordZoneChangeBatch(
        pending: [CKSyncEngine.PendingRecordZoneChange],
        from syncEngine: any CloudKitSyncEngineClient
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        do {
            if mode == .notebook {
                let canonicalID = CKRecord.ID(
                    recordName: mode.bootstrapName, zoneID: zoneID
                )
                guard pending.contains(where: { change in
                    if case let .saveRecord(id) = change { return id == canonicalID }
                    return false
                }) else {
                    // A scoped engine retry may omit the control record.
                    // Request a new cycle that can offer the complete fence.
                    if !pending.isEmpty {
                        syncEngine.add(pendingRecordZoneChanges: [
                            .saveRecord(canonicalID)
                        ])
                    }
                    return nil
                }
            }
            let prepared = try await CloudKitOutgoingBatchPreparer.assemble(
                allowed: { await self.canOfferOutgoingBatch(syncEngine) },
                readOutbox: { await self.store.snapshot().outbox },
                stage: { outbox in
                    guard await self.canOfferOutgoingBatch(syncEngine)
                        else { return [:] }
                    return try await self.outgoingRecords(
                        pending: pending,
                        outbox: outbox
                    )
                },
                construct: { (records: [String: SyncRecord]) in
                    // The batch asks only for the records that fit in one
                    // request, so only those are written to disk.
                    await CKSyncEngine.RecordZoneChangeBatch(
                        pendingChanges: pending
                    ) { recordID in
                        guard let value = records[recordID.recordName] else {
                            return nil
                        }
                        return await self.stageEngineRecord(value, id: recordID)
                    }
                },
                leased: { batch in
                    Set(batch.recordsToSave.map { $0.recordID.recordName })
                },
                release: { ids in
                    await self.releaseOutgoingBatchLeases(ids)
                }
            )
            let stagingFailure = batchStagingFailure
            batchStagingFailure = nil
            guard let prepared else {
                if let stagingFailure { throw stagingFailure }
                if mode == .notebook,
                   !pending.contains(where: { change in
                       if case let .saveRecord(id) = change {
                           return id.recordName != mode.bootstrapName
                       }
                       return false
                   }) {
                    syncEngine.remove(pendingRecordZoneChanges: [
                        .saveRecord(CKRecord.ID(
                            recordName: mode.bootstrapName, zoneID: zoneID
                        ))
                    ])
                }
                return nil
            }
            if let stagingFailure {
                releaseOutgoingBatchLeases(prepared.leasedIDs)
                throw stagingFailure
            }
            guard !isRetired, delegateFailure == nil,
                  store.writeHealth.failure == nil,
                  !unexpectedDeletionObserved,
                  syncEngine === engine else {
                releaseOutgoingBatchLeases(prepared.leasedIDs)
                return nil
            }
            guard mode == .notebook,
                  !prepared.batch.recordsToSave.isEmpty else {
                if mode == .notebook {
                    syncEngine.remove(pendingRecordZoneChanges: [
                        .saveRecord(CKRecord.ID(
                            recordName: mode.bootstrapName, zoneID: zoneID
                        ))
                    ])
                }
                return prepared.batch
            }
            do {
                // CKSyncEngine allows at most 250 changes in one batch.
                // Reserve one slot for the canonical control record.
                let snapshots = Array(
                    prepared.batch.recordsToSave.prefix(249)
                )
                let selected = Set(snapshots.map {
                    $0.recordID.recordName
                })
                releaseOutgoingBatchLeases(
                    prepared.leasedIDs.subtracting(selected)
                )
                let batch = try await fencedNotebookBatch(
                    snapshots,
                    outbox: await store.snapshot().outbox
                )
                guard await canOfferOutgoingBatch(syncEngine) else {
                    releaseOutgoingBatchLeases(selected)
                    releaseEngineAssetLease(
                        for: mode.bootstrapName, uploadCompleted: true
                    )
                    return nil
                }
                return batch
            } catch {
                releaseOutgoingBatchLeases(prepared.leasedIDs)
                throw error
            }
        } catch {
            guard !isRetired else { return nil }
            if error is CancellationError { return nil }
            if let cloud = error as? CKError,
               Self.transientCloudCodes.contains(cloud.code) {
                await observeRetryAfter(cloud)
                lastReportedFailure = cloud
                yieldAfterDelegateReturns([
                    .failed(cloud.localizedDescription)
                ])
                return nil
            }
            latchFailure(error)
            lastReportedFailure = error
            yieldAfterDelegateReturns([.failed(error.localizedDescription)])
            return nil
        }
    }

    private func canOfferOutgoingBatch(
        _ syncEngine: any CloudKitSyncEngineClient
    ) async -> Bool
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

    private static let transientCloudCodes: Set<CKError.Code> = [
        .notAuthenticated, .accountTemporarilyUnavailable,
        .networkFailure, .networkUnavailable, .requestRateLimited,
        .serverResponseLost, .serviceUnavailable, .zoneBusy
    ]

    private func releaseOutgoingBatchLeases(_ ids: Set<String>) {
        for id in ids {
            releaseEngineAssetLease(for: id, uploadCompleted: false)
        }
    }
}
