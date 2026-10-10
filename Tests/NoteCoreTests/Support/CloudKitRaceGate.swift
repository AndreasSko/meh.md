import CloudKit
import Foundation

@testable import NoteCore

/// A one-shot rendezvous. Timeouts bound failures, never arrange the race.
actor CloudKitRaceGate {
    private var reached = false
    private var released = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var parked: [UUID: CheckedContinuation<Void, Error>] = [:]

    func waitUntilPaused() async throws {
        if reached { return }
        try await wait(arrival: true)
    }

    func pause() async throws {
        reached = true
        let arrivals = waiters.values
        waiters.removeAll()
        for arrival in arrivals { arrival.resume() }
        if !released { try await wait(arrival: false) }
    }

    func release() {
        released = true
        let continuations = parked.values
        parked.removeAll()
        for continuation in continuations { continuation.resume() }
    }

    private func wait(arrival: Bool) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                if arrival { waiters[id] = continuation }
                else { parked[id] = continuation }
                Task {
                    try? await Task.sleep(for: .seconds(15))
                    self.finish(id, arrival: arrival,
                                error: SyncError.unavailable("Race gate timed out"))
                }
            }
        } onCancel: {
            Task { await self.finish(id, arrival: arrival,
                                     error: CancellationError()) }
        }
    }

    private func finish(_ id: UUID, arrival: Bool, error: Error) {
        let continuation = arrival
            ? waiters.removeValue(forKey: id)
            : parked.removeValue(forKey: id)
        continuation?.resume(throwing: error)
    }
}

/// Only the selected device's direct database requests are intercepted.
struct CloudKitRaceDatabase: CloudKitDatabaseClient {
    let base: any CloudKitDatabaseClient
    var afterRead: (name: String, gate: CloudKitRaceGate)?
    var beforeDelete: (name: String, gate: CloudKitRaceGate)?
    private let attempts = CloudKitRaceDeleteAttempts()

    init(
        base: any CloudKitDatabaseClient,
        afterRead: (name: String, gate: CloudKitRaceGate)? = nil,
        beforeDelete: (name: String, gate: CloudKitRaceGate)? = nil
    ) {
        self.base = base
        self.afterRead = afterRead
        self.beforeDelete = beforeDelete
    }

    func deletionAttempts() async -> [[String]] {
        await attempts.snapshot()
    }

    func services(base services: CloudKitServices) -> CloudKitServices {
        CloudKitServices(account: services.account, database: self,
                         makeEngine: services.makeEngine)
    }

    func record(for id: CKRecord.ID) async throws -> CKRecord {
        let record = try await base.record(for: id)
        let frozen = record.copy() as! CKRecord
        if let afterRead, afterRead.name == id.recordName {
            try await afterRead.gate.pause()
        }
        return frozen
    }

    func save(_ record: CKRecord) async throws -> CKRecord {
        try await base.save(record)
    }

    func modifyRecords(
        saving records: [CKRecord], deleting ids: [CKRecord.ID],
        savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
        atomically: Bool
    ) async throws -> (
        saveResults: [CKRecord.ID: Result<CKRecord, any Error>],
        deleteResults: [CKRecord.ID: Result<Void, any Error>]
    ) {
        if let beforeDelete,
           ids.contains(where: { $0.recordName == beforeDelete.name }) {
            try await beforeDelete.gate.pause()
        }
        if !ids.isEmpty { await attempts.append(ids.map(\.recordName)) }
        return try await base.modifyRecords(saving: records, deleting: ids,
                                           savePolicy: savePolicy,
                                           atomically: atomically)
    }

    func recordZones(for ids: [CKRecordZone.ID]) async throws
        -> [CKRecordZone.ID: Result<CKRecordZone, any Error>] {
        try await base.recordZones(for: ids)
    }

    func modifyRecordZones(
        saving zones: [CKRecordZone], deleting ids: [CKRecordZone.ID]
    ) async throws -> (
        saveResults: [CKRecordZone.ID: Result<CKRecordZone, any Error>],
        deleteResults: [CKRecordZone.ID: Result<Void, any Error>]
    ) {
        try await base.modifyRecordZones(saving: zones, deleting: ids)
    }
}

private actor CloudKitRaceDeleteAttempts {
    private var batches: [[String]] = []
    func append(_ batch: [String]) { batches.append(batch) }
    func snapshot() -> [[String]] { batches }
}
