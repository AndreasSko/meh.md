import CloudKit
import Foundation

// The transport talks to CloudKit only through these protocols and events.
// CloudKit's own types conform directly; tests substitute an in-process
// server and engine, because CKSyncEngine events cannot be constructed.

protocol CloudKitAccountClient: Sendable {
    func accountStatus() async throws -> CKAccountStatus
    func userRecordID() async throws -> CKRecord.ID
}

protocol CloudKitDatabaseClient: Sendable {
    func record(for recordID: CKRecord.ID) async throws -> CKRecord
    func save(_ record: CKRecord) async throws -> CKRecord
    func modifyRecords(
        saving recordsToSave: [CKRecord],
        deleting recordIDsToDelete: [CKRecord.ID],
        savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
        atomically: Bool
    ) async throws -> (
        saveResults: [CKRecord.ID: Result<CKRecord, any Error>],
        deleteResults: [CKRecord.ID: Result<Void, any Error>]
    )
    func recordZones(
        for ids: [CKRecordZone.ID]
    ) async throws -> [CKRecordZone.ID: Result<CKRecordZone, any Error>]
    func modifyRecordZones(
        saving recordZonesToSave: [CKRecordZone],
        deleting recordZoneIDsToDelete: [CKRecordZone.ID]
    ) async throws -> (
        saveResults: [CKRecordZone.ID: Result<CKRecordZone, any Error>],
        deleteResults: [CKRecordZone.ID: Result<Void, any Error>]
    )
}

protocol CloudKitSyncEngineClient: AnyObject, Sendable {
    var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] {
        get
    }
    func add(pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange])
    func remove(
        pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange]
    )
    func sendChanges(_ options: CKSyncEngine.SendChangesOptions) async throws
    func fetchChanges(_ options: CKSyncEngine.FetchChangesOptions) async throws
    func cancelOperations() async
}

/// Creates the engine for a transport from its last persisted engine state.
typealias CloudKitSyncEngineFactory = @Sendable (
    _ state: Data?,
    _ transport: CloudKitSyncTransport,
    _ automaticallySync: Bool
) throws -> any CloudKitSyncEngineClient

struct CloudKitServices: Sendable {
    let account: any CloudKitAccountClient
    let database: any CloudKitDatabaseClient
    let makeEngine: CloudKitSyncEngineFactory

    static func system(containerIdentifier: String) -> CloudKitServices {
        let container = CKContainer(identifier: containerIdentifier)
        let database = container.privateCloudDatabase
        return CloudKitServices(
            account: container,
            database: database,
            makeEngine: CKSyncEngine.factory(database: database)
        )
    }
}

extension CKContainer: CloudKitAccountClient {}

extension CKDatabase: CloudKitDatabaseClient {}

extension CKSyncEngine: CloudKitSyncEngineClient {
    var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] {
        state.pendingRecordZoneChanges
    }

    func add(
        pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange]
    ) {
        state.add(pendingRecordZoneChanges: pendingRecordZoneChanges)
    }

    func remove(
        pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange]
    ) {
        state.remove(pendingRecordZoneChanges: pendingRecordZoneChanges)
    }

    static func factory(database: CKDatabase) -> CloudKitSyncEngineFactory {
        { state, transport, automaticallySync in
            let serialization: CKSyncEngine.State.Serialization?
            if let state {
                do {
                    serialization = try JSONDecoder().decode(
                        CKSyncEngine.State.Serialization.self, from: state
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
                delegate: transport
            )
            configuration.automaticallySync = automaticallySync
            return CKSyncEngine(configuration)
        }
    }
}

struct CloudKitFailedRecordSave: Sendable {
    let record: CKRecord
    let error: CKError
}

enum CloudKitAccountChange: Sendable {
    case signIn(CKRecord.ID)
    case signOut
    case switchAccounts
}

/// The subset of `CKSyncEngine.Event` the transport acts on.
enum CloudKitEngineEvent: Sendable {
    case stateUpdate(Result<Data, any Error>)
    case fetchedRecordZoneChanges(
        modifications: [CKRecord], deletions: [CKRecord.ID]
    )
    case sentRecordZoneChanges(
        saved: [CKRecord], failed: [CloudKitFailedRecordSave]
    )
    case accountChange(CloudKitAccountChange)
    case fetchedDatabaseChanges(deletedZoneIDs: [CKRecordZone.ID])
    case didFetchRecordZoneChanges(zoneID: CKRecordZone.ID, error: CKError?)
    case didFetchChanges(scheduled: Bool)
    case didSendChanges(scheduled: Bool)
    case other

    init(_ event: CKSyncEngine.Event) {
        switch event {
        case let .stateUpdate(update):
            self = .stateUpdate(Result {
                try JSONEncoder().encode(update.stateSerialization)
            })
        case let .fetchedRecordZoneChanges(changes):
            self = .fetchedRecordZoneChanges(
                modifications: changes.modifications.map(\.record),
                deletions: changes.deletions.map(\.recordID)
            )
        case let .sentRecordZoneChanges(changes):
            self = .sentRecordZoneChanges(
                saved: changes.savedRecords,
                failed: changes.failedRecordSaves.map {
                    CloudKitFailedRecordSave(record: $0.record, error: $0.error)
                }
            )
        case let .accountChange(change):
            switch change.changeType {
            case let .signIn(currentUser):
                self = .accountChange(.signIn(currentUser))
            case .signOut:
                self = .accountChange(.signOut)
            case .switchAccounts:
                self = .accountChange(.switchAccounts)
            @unknown default:
                self = .accountChange(.switchAccounts)
            }
        case let .fetchedDatabaseChanges(changes):
            self = .fetchedDatabaseChanges(
                deletedZoneIDs: changes.deletions.map(\.zoneID)
            )
        case let .didFetchRecordZoneChanges(completion):
            self = .didFetchRecordZoneChanges(
                zoneID: completion.zoneID, error: completion.error
            )
        case let .didFetchChanges(completion):
            self = .didFetchChanges(
                scheduled: completion.context.reason == .scheduled
            )
        case let .didSendChanges(completion):
            self = .didSendChanges(
                scheduled: completion.context.reason == .scheduled
            )
        default:
            self = .other
        }
    }

    var sentRecordIDs: (saved: [String], failed: [String])? {
        guard case let .sentRecordZoneChanges(saved, failed) = self else {
            return nil
        }
        return (
            saved.map(\.recordID.recordName),
            failed.map(\.record.recordID.recordName)
        )
    }
}
