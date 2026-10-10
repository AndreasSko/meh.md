import CloudKit
import Foundation

@testable import NoteCore

/// Thrown when a fault simulates the app process dying mid-operation. The
/// caller must discard the transport and reopen it from disk.
struct FakeCloudKitCrash: Error {}

/// An in-process CloudKit private database for one account, shared by all
/// simulated devices. It follows the documented behaviour the transport
/// depends on: saving a new record over an existing one fails with
/// `serverRecordChanged` and carries the server copy, missing zones fail with
/// `zoneNotFound`, and fetches return each record's latest state since a
/// change token.
final class FakeCloudKitServer: @unchecked Sendable, CloudKitAccountClient,
    CloudKitDatabaseClient
{
    enum Fault: Sendable {
        /// Every request fails with `networkUnavailable`.
        case offline
        /// The next save of a matching record fails with this code.
        case failSave(CKError.Code, matching: @Sendable (CKRecord.ID) -> Bool)
        /// The next direct record read fails with `networkFailure`.
        case failDelete(CKError.Code, matching: @Sendable (CKRecord.ID) -> Bool)
        case omitDeleteResult(matching: @Sendable (CKRecord.ID) -> Bool)
        case crashAfterServerDelete
        case failNextRead
        /// Remove a record after fetched events, just before a direct read.
        case deleteBeforeNextRead(String)
        /// The next engine send stores its batch, then the app dies before
        /// the sent-changes event is delivered.
        case crashAfterServerSave
        /// The next engine fetch delivers one chunk of changes, then the app
        /// dies before the engine state is updated.
        case crashAfterFetchedChanges
    }

    private struct Change {
        let sequence: Int
        let recordID: CKRecord.ID
    }

    let containerIdentifier = "iCloud.test.fake"
    let zoneID = CKRecordZone.ID(zoneName: "meh-md-notebook-v2")
    private let lock = NSLock()
    private let assetDirectory: URL
    private var user = CKRecord.ID(recordName: "_fake-user")
    private var zoneExists = false
    private var records: [CKRecord.ID: CKRecord] = [:]
    private var changes: [Change] = []
    private var zoneDeletedAt: Int?
    private var sequence = 0
    private var faults: [Fault] = []
    private var isOffline = false
    private var engines: [FakeSyncEngine] = []
    private var deletedNames: [String] = []
    private var fetchedCount = 0
    private var fetchedBytes = 0

    init(directory: URL) throws {
        assetDirectory = directory.appending(path: "fake-cloudkit-assets")
        try FileManager.default.createDirectory(
            at: assetDirectory, withIntermediateDirectories: true
        )
    }

    var scope: String {
        "\(containerIdentifier)/private/\(locked { user.recordName })/"
            + zoneID.zoneName
    }

    var services: CloudKitServices {
        CloudKitServices(account: self, database: self) {
            state, transport, _ in
            let engine = try FakeSyncEngine(
                server: self, transport: transport, state: state
            )
            self.locked { self.engines.append(engine) }
            return engine
        }
    }

    /// The most recently created engine, i.e. the one of the newest transport.
    var latestEngine: FakeSyncEngine? { locked { engines.last } }

    func setOffline(_ offline: Bool) { locked { isOffline = offline } }

    var offline: Bool { locked { isOffline } }

    func inject(_ fault: Fault) { locked { faults.append(fault) } }

    func clearFaults() { locked { faults = [] } }

    func switchAccount() {
        locked { user = CKRecord.ID(recordName: "_other-\(UUID())") }
    }

    /// Simulates the user deleting the app's iCloud data.
    func deleteZone() {
        locked {
            sequence += 1
            zoneExists = false
            records = [:]
            zoneDeletedAt = sequence
        }
    }

    /// Simulates another client or a server cleanup removing one record.
    func deleteRecord(named name: String) {
        locked {
            let id = CKRecord.ID(recordName: name, zoneID: zoneID)
            guard records.removeValue(forKey: id) != nil else { return }
            sequence += 1
            changes.append(Change(sequence: sequence, recordID: id))
        }
    }

    var recordNames: Set<String> {
        locked { Set(records.keys.map(\.recordName)) }
    }

    var deletedRecordNames: [String] { locked { deletedNames } }

    var fetchMeasurements: (records: Int, assetBytes: Int) {
        locked { (fetchedCount, fetchedBytes) }
    }

    func resetFetchMeasurements() {
        locked { fetchedCount = 0; fetchedBytes = 0 }
    }

    var storedAssetBytes: Int {
        locked { records.values.reduce(0) { $0 + assetBytes(of: $1) } }
    }

    private func assetBytes(of record: CKRecord) -> Int {
        record.allKeys().reduce(0) { sum, key in
            guard let url = (record[key] as? CKAsset)?.fileURL else { return sum }
            return sum + ((try? Data(contentsOf: url).count) ?? 0)
        }
    }

    // MARK: CloudKitAccountClient

    func accountStatus() async throws -> CKAccountStatus {
        try checkReachable()
        return .available
    }

    func userRecordID() async throws -> CKRecord.ID {
        try checkReachable()
        return locked { user }
    }

    // MARK: CloudKitDatabaseClient

    func record(for recordID: CKRecord.ID) async throws -> CKRecord {
        try checkReachable()
        if case let .deleteBeforeNextRead(name)? = takeFault(where: {
            if case .deleteBeforeNextRead = $0 { return true }
            return false
        }) {
            deleteRecord(named: name)
        }
        if takeFault(where: {
            if case .failNextRead = $0 { return true }
            return false
        }) != nil {
            throw CKError(.networkFailure)
        }
        return try locked {
            guard zoneExists else { throw CKError(.zoneNotFound) }
            guard let record = records[recordID] else {
                throw CKError(.unknownItem)
            }
            return try serverCopy(of: record)
        }
    }

    func save(_ record: CKRecord) async throws -> CKRecord {
        try checkReachable()
        switch try store(record) {
        case let .success(saved): return saved
        case let .failure(error): throw error
        }
    }

    func modifyRecords(
        saving recordsToSave: [CKRecord],
        deleting recordIDsToDelete: [CKRecord.ID],
        savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
        atomically: Bool
    ) async throws -> (
        saveResults: [CKRecord.ID: Result<CKRecord, any Error>],
        deleteResults: [CKRecord.ID: Result<Void, any Error>]
    ) {
        try checkReachable()
        var saveResults: [CKRecord.ID: Result<CKRecord, any Error>] = [:]
        for record in recordsToSave {
            saveResults[record.recordID] = try store(record)
                .mapError { $0 as any Error }
        }
        var deleteResults: [CKRecord.ID: Result<Void, any Error>] = [:]
        for id in recordIDsToDelete {
            if case let .failDelete(code, _)? = takeFault(where: {
                if case let .failDelete(_, matching) = $0 { return matching(id) }
                return false
            }) {
                deleteResults[id] = .failure(CKError(code, userInfo:
                    code == .requestRateLimited
                        ? [CKErrorRetryAfterKey: 0.001] : [:]
                ))
                continue
            }
            deleteResults[id] = locked {
                guard records.removeValue(forKey: id) != nil else {
                    return .failure(CKError(.unknownItem))
                }
                deletedNames.append(id.recordName)
                sequence += 1
                changes.append(Change(sequence: sequence, recordID: id))
                return .success(())
            }
        }
        for id in recordIDsToDelete {
            if takeFault(where: {
                if case let .omitDeleteResult(matching) = $0 { return matching(id) }
                return false
            }) != nil { deleteResults.removeValue(forKey: id) }
        }
        if !recordIDsToDelete.isEmpty, takeFault(where: {
            if case .crashAfterServerDelete = $0 { return true }
            return false
        }) != nil { throw FakeCloudKitCrash() }
        return (saveResults, deleteResults)
    }

    func recordZones(
        for ids: [CKRecordZone.ID]
    ) async throws -> [CKRecordZone.ID: Result<CKRecordZone, any Error>] {
        try checkReachable()
        return locked {
            Dictionary(uniqueKeysWithValues: ids.map { id in
                (id, id == zoneID && zoneExists
                    ? .success(CKRecordZone(zoneID: id))
                    : .failure(CKError(.zoneNotFound)))
            })
        }
    }

    func modifyRecordZones(
        saving recordZonesToSave: [CKRecordZone],
        deleting recordZoneIDsToDelete: [CKRecordZone.ID]
    ) async throws -> (
        saveResults: [CKRecordZone.ID: Result<CKRecordZone, any Error>],
        deleteResults: [CKRecordZone.ID: Result<Void, any Error>]
    ) {
        try checkReachable()
        return locked {
            var saved: [CKRecordZone.ID: Result<CKRecordZone, any Error>] = [:]
            for zone in recordZonesToSave where zone.zoneID == zoneID {
                zoneExists = true
                saved[zone.zoneID] = .success(zone)
            }
            return (saved, [:])
        }
    }

    // MARK: Engine support

    func checkReachable() throws {
        try locked {
            if isOffline { throw CKError(.networkUnavailable) }
        }
    }

    func takeFault(where matches: (Fault) -> Bool) -> Fault? {
        locked {
            guard let index = faults.firstIndex(where: matches) else {
                return nil
            }
            return faults.remove(at: index)
        }
    }

    func store(_ record: CKRecord) throws -> Result<CKRecord, CKError> {
        if case let .failSave(code, _)? = takeFault(where: {
            if case let .failSave(_, matching) = $0 {
                return matching(record.recordID)
            }
            return false
        }) {
            return .failure(CKError(code))
        }
        return try locked {
            guard zoneExists, record.recordID.zoneID == zoneID else {
                return .failure(CKError(.zoneNotFound))
            }
            if let existing = records[record.recordID] {
                // The transport always sends records without system fields,
                // so an existing record is a conflict, as with CloudKit's
                // default `ifServerRecordUnchanged` policy.
                return .failure(CKError(
                    .serverRecordChanged,
                    userInfo: [
                        CKRecordChangedErrorServerRecordKey:
                            try serverCopy(of: existing)
                    ]
                ))
            }
            let stored = try retainAssets(of: record)
            records[record.recordID] = stored
            sequence += 1
            changes.append(Change(sequence: sequence, recordID: record.recordID))
            return .success(try serverCopy(of: stored))
        }
    }

    /// Latest state of every record changed after `token`, in change order.
    func changes(after token: Int) throws -> (
        zoneDeleted: Bool,
        modifications: [CKRecord],
        deletions: [CKRecord.ID],
        token: Int
    ) {
        try locked {
            let zoneDeleted = zoneDeletedAt.map { $0 > token } ?? false
            var seen = Set<CKRecord.ID>()
            var modifications: [CKRecord] = []
            var deletions: [CKRecord.ID] = []
            for change in changes.reversed() where change.sequence > token {
                guard seen.insert(change.recordID).inserted else { continue }
                if let record = records[change.recordID] {
                    fetchedCount += 1
                    fetchedBytes += assetBytes(of: record)
                    modifications.append(try serverCopy(of: record))
                } else if !zoneDeleted {
                    deletions.append(change.recordID)
                }
            }
            return (
                zoneDeleted, modifications.reversed(), deletions.reversed(),
                sequence
            )
        }
    }

    private func retainAssets(of record: CKRecord) throws -> CKRecord {
        let stored = record.copy() as! CKRecord
        for key in stored.allKeys() {
            guard let asset = stored[key] as? CKAsset,
                  let source = asset.fileURL else { continue }
            let target = assetDirectory.appending(path: UUID().uuidString)
            try FileManager.default.copyItem(at: source, to: target)
            stored[key] = CKAsset(fileURL: target)
        }
        return stored
    }

    /// CloudKit hands out fresh objects whose assets are temporary files.
    private func serverCopy(of record: CKRecord) throws -> CKRecord {
        try retainAssets(of: record)
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// Stands in for `CKSyncEngine` with `automaticallySync` off. It keeps
/// pending changes and a fetch token in its serialized state, drives the
/// transport's batch provider, removes changes that saved or failed with a
/// non-transient error, and delivers events in the documented order.
final class FakeSyncEngine: @unchecked Sendable, CloudKitSyncEngineClient {
    private struct State: Codable {
        var pendingSaves: [String] = []
        var fetchToken = 0
    }

    /// Errors CKSyncEngine documents as retried automatically.
    static let transientCodes: Set<CKError.Code> = [
        .notAuthenticated, .accountTemporarilyUnavailable, .networkFailure,
        .networkUnavailable, .requestRateLimited, .serviceUnavailable,
        .zoneBusy,
    ]

    let fetchChunkSize = 3
    private let server: FakeCloudKitServer
    private weak var transport: CloudKitSyncTransport?
    private let lock = NSLock()
    private var state: State
    private var stateChanged = false

    init(
        server: FakeCloudKitServer,
        transport: CloudKitSyncTransport,
        state data: Data?
    ) throws {
        self.server = server
        self.transport = transport
        state = try data.map {
            try JSONDecoder().decode(State.self, from: $0)
        } ?? State()
    }

    var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] {
        locked {
            state.pendingSaves.map {
                .saveRecord(CKRecord.ID(recordName: $0, zoneID: server.zoneID))
            }
        }
    }

    func add(
        pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]
    ) {
        locked {
            for case let .saveRecord(id) in changes
            where !state.pendingSaves.contains(id.recordName) {
                state.pendingSaves.append(id.recordName)
                stateChanged = true
            }
        }
    }

    func remove(
        pendingRecordZoneChanges changes: [CKSyncEngine.PendingRecordZoneChange]
    ) {
        locked {
            let names = Set(changes.compactMap { change -> String? in
                guard case let .saveRecord(id) = change else { return nil }
                return id.recordName
            })
            let before = state.pendingSaves.count
            state.pendingSaves.removeAll { names.contains($0) }
            stateChanged = stateChanged || before != state.pendingSaves.count
        }
    }

    func sendChanges(_ options: CKSyncEngine.SendChangesOptions) async throws {
        guard let transport else { return }
        try server.checkReachable()
        await deliverStateUpdate(to: transport)
        var transientError: CKError?
        for _ in 0..<100 {
            let pending = pendingRecordZoneChanges.filter {
                options.scope.contains($0)
            }
            guard !pending.isEmpty,
                  let batch = await transport.nextRecordZoneChangeBatch(
                    pending: pending, from: self
                  ),
                  !batch.recordsToSave.isEmpty else { break }
            let crashes = server.takeFault {
                if case .crashAfterServerSave = $0 { return true }
                return false
            } != nil
            var saved: [CKRecord] = []
            var failed: [CloudKitFailedRecordSave] = []
            for record in batch.recordsToSave {
                switch try server.store(record) {
                case let .success(serverRecord):
                    saved.append(serverRecord)
                    remove(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
                case let .failure(error):
                    failed.append(.init(record: record, error: error))
                    if Self.transientCodes.contains(error.code) {
                        transientError = transientError ?? error
                    } else {
                        remove(
                            pendingRecordZoneChanges: [.saveRecord(record.recordID)]
                        )
                    }
                }
            }
            if crashes { throw FakeCloudKitCrash() }
            await transport.handle(
                .sentRecordZoneChanges(saved: saved, failed: failed), from: self
            )
            await deliverStateUpdate(to: transport)
            if transientError != nil { break }
        }
        await transport.handle(.didSendChanges(scheduled: false), from: self)
        if let transientError { throw transientError }
    }

    func fetchChanges(_ options: CKSyncEngine.FetchChangesOptions) async throws {
        guard let transport else { return }
        try server.checkReachable()
        let changes = try server.changes(after: locked { state.fetchToken })
        if changes.zoneDeleted {
            await transport.handle(
                .fetchedDatabaseChanges(deletedZoneIDs: [server.zoneID]),
                from: self
            )
        }
        let crashes = server.takeFault {
            if case .crashAfterFetchedChanges = $0 { return true }
            return false
        } != nil
        var modifications = changes.modifications[...]
        var deletions = changes.deletions[...]
        repeat {
            let chunk = Array(modifications.prefix(fetchChunkSize))
            modifications = modifications.dropFirst(chunk.count)
            let removed = modifications.isEmpty ? Array(deletions) : []
            deletions = modifications.isEmpty ? [] : deletions
            if !chunk.isEmpty || !removed.isEmpty {
                await transport.handle(
                    .fetchedRecordZoneChanges(
                        modifications: chunk, deletions: removed
                    ),
                    from: self
                )
                if crashes { throw FakeCloudKitCrash() }
            }
        } while !modifications.isEmpty
        locked {
            if state.fetchToken != changes.token {
                state.fetchToken = changes.token
                stateChanged = true
            }
        }
        await deliverStateUpdate(to: transport)
        await transport.handle(
            .didFetchRecordZoneChanges(zoneID: server.zoneID, error: nil),
            from: self
        )
        await transport.handle(.didFetchChanges(scheduled: false), from: self)
    }

    func cancelOperations() async {}

    /// Delivers an arbitrary event, e.g. an account change.
    func deliver(_ event: CloudKitEngineEvent) async {
        await transport?.handle(event, from: self)
    }

    private func deliverStateUpdate(to transport: CloudKitSyncTransport) async {
        let data: Data? = locked {
            guard stateChanged else { return nil }
            stateChanged = false
            return try? JSONEncoder().encode(state)
        }
        guard let data else { return }
        await transport.handle(.stateUpdate(.success(data)), from: self)
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
