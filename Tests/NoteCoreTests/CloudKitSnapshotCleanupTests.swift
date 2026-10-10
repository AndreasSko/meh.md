import Automerge
import Foundation
@testable import NoteCore
import XCTest

final class CloudKitSnapshotCleanupTests: XCTestCase {
    private func state(_ records: [SyncRecord]) throws -> CloudKitTransportState {
        var state = CloudKitTransportState(
            accountRecordName: "account", zoneName: "zone", protocolVersion: 2)
        for record in records { try state.appendToInbox(record) }
        return state
    }

    private func chain() throws -> [SyncRecord] {
        let note = try NoteDocument(noteID: UUID())
        let notebook = UUID()
        var records = [SyncRecord(snapshot: note.snapshot(), notebookID: notebook)]
        for text in ["fictional first", "fictional final"] {
            try note.replaceAll(with: text)
            records.append(SyncRecord(snapshot: note.snapshot(), notebookID: notebook))
        }
        return records
    }

    func testAllVictimsUseMaximalSurvivorInEitherObservationOrder() throws {
        let records = try chain()
        for order in [records, records.reversed().map { $0 }] {
            var state = try state(order)
            let plans = try state.proposedSnapshotCleanupPlans()
            XCTAssertEqual(Set(plans.map(\.victimID)), Set(records.prefix(2).map(\.id)))
            XCTAssertEqual(Set(plans.map(\.survivorID)), [records[2].id])
            try state.persistSnapshotCleanupPlans(plans)
            XCTAssertEqual(state.pendingSnapshotCleanup.count, 2)
            for plan in plans {
                XCTAssertNotNil(try state.snapshotCleanupRecords(for: plan))
                state.completeSnapshotCleanup(plan)
            }
            XCTAssertEqual(state.inbox, order)
            XCTAssertTrue(try state.proposedSnapshotCleanupPlans().isEmpty)
        }
    }

    func testConcurrentBranchesRequireMergedHistory() throws {
        let notebook = UUID()
        let base = try NoteDocument(noteID: UUID())
        let left = try NoteDocument(snapshot: base.snapshot())
        let right = try NoteDocument(snapshot: base.snapshot())
        try left.replaceAll(with: "fictional left")
        try right.replaceAll(with: "fictional right")
        let branches = [SyncRecord(snapshot: left.snapshot(), notebookID: notebook),
                        SyncRecord(snapshot: right.snapshot(), notebookID: notebook)]
        var state = try state(branches)
        XCTAssertTrue(try state.proposedSnapshotCleanupPlans().isEmpty)
        try left.merge(right)
        let merged = SyncRecord(snapshot: left.snapshot(), notebookID: notebook)
        try state.appendToInbox(merged)
        let plans = try state.proposedSnapshotCleanupPlans()
        XCTAssertEqual(Set(plans.map(\.victimID)), Set(branches.map(\.id)))
        XCTAssertEqual(Set(plans.map(\.survivorID)), [merged.id])
    }

    func testOutboxAndDeletionEvidenceExcludeBothRoles() throws {
        let records = try chain()
        for excluded in [records[0], records[2]] {
            var state = try state(records)
            state.outbox[excluded.id] = excluded
            XCTAssertFalse(try state.proposedSnapshotCleanupPlans().contains {
                $0.victimID == excluded.id || $0.survivorID == excluded.id
            })
            state.outbox = [:]
            state.remoteDeletedSnapshotIDs.insert(excluded.id)
            XCTAssertFalse(try state.proposedSnapshotCleanupPlans().contains {
                $0.victimID == excluded.id || $0.survivorID == excluded.id
            })
            state.remoteDeletedSnapshotIDs = []
            state.unresolvedRemoteDeletionRecordIDs.insert(excluded.id)
            XCTAssertFalse(try state.proposedSnapshotCleanupPlans().contains {
                $0.victimID == excluded.id || $0.survivorID == excluded.id
            })
            state.unresolvedRemoteDeletionRecordIDs = []
            state.purgedRecordIDs.insert(excluded.id)
            XCTAssertFalse(try state.proposedSnapshotCleanupPlans().contains {
                $0.victimID == excluded.id || $0.survivorID == excluded.id
            })
        }
    }

    func testIdentityProtocolAndCanonicalRecordCannotBecomeVictims() throws {
        let records = try chain()
        let wrongNotebook = SyncRecord(snapshot: records[2].snapshot, notebookID: UUID())
        let wrongDocument = SyncRecord(
            snapshot: try NoteDocument(noteID: UUID()).snapshot(),
            notebookID: try XCTUnwrap(records[0].notebookID))
        let state = try state([records[0], wrongNotebook, wrongDocument])
        XCTAssertTrue(try state.proposedSnapshotCleanupPlans().isEmpty)
        var legacy = CloudKitTransportState(accountRecordName: "a", zoneName: "z")
        try legacy.appendToInbox(SyncRecord(snapshot: records[0].snapshot))
        XCTAssertTrue(try legacy.proposedSnapshotCleanupPlans().isEmpty)
        var invalid = state
        invalid.pendingSnapshotCleanup["bootstrap"] = .init(
            victimID: "bootstrap", survivorID: records[0].id)
        XCTAssertThrowsError(try invalid.validateSnapshotCleanupPlans())
    }

    func testRestartRevalidatesRacesWithoutMovingCursor() throws {
        let records = try chain()
        var original = try state(records)
        let before = try original.page(after: nil, limit: 1)
        try original.persistSnapshotCleanupPlans(original.proposedSnapshotCleanupPlans())
        let encoded = try JSONEncoder().encode(original)
        var olderJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        olderJSON.removeValue(forKey: "pendingSnapshotCleanup")
        let older = try JSONDecoder().decode(
            CloudKitTransportState.self,
            from: JSONSerialization.data(withJSONObject: olderJSON)
        )
        XCTAssertTrue(older.pendingSnapshotCleanup.isEmpty)
        XCTAssertEqual(older.inbox, original.inbox)
        XCTAssertEqual(try older.page(after: before.cursor, limit: 1).records, [records[1]])
        var restored = try JSONDecoder().decode(CloudKitTransportState.self, from: encoded)
        XCTAssertEqual(original, restored)
        XCTAssertEqual(try restored.page(after: before.cursor, limit: 1).records, [records[1]])
        let plan = try XCTUnwrap(restored.pendingSnapshotCleanup[records[0].id])
        XCTAssertNotNil(try restored.snapshotCleanupRecords(for: plan))
        restored.remoteDeletedSnapshotIDs.insert(plan.survivorID)
        XCTAssertNil(try restored.snapshotCleanupRecords(for: plan))
        XCTAssertNoThrow(try restored.validateSnapshotCleanupPlans())
        restored.dropSnapshotCleanup(plan)
        XCTAssertNil(restored.pendingSnapshotCleanup[plan.victimID])
        XCTAssertEqual(restored.inbox, original.inbox)
        XCTAssertNil(try restored.snapshotCleanupRecords(for: .init(
            victimID: String(repeating: "0", count: 64), survivorID: records[2].id)))
    }

    func testIndependentCleanerChainAlwaysAdvancesHistory() throws {
        let records = try chain()
        var first = try state(Array(records.prefix(2)))
        let firstPlan = try XCTUnwrap(first.proposedSnapshotCleanupPlans().first)
        try first.persistSnapshotCleanupPlans([firstPlan])
        let second = try state(Array(records.suffix(2)))
        let secondPlan = try XCTUnwrap(second.proposedSnapshotCleanupPlans().first)
        XCTAssertEqual(firstPlan.survivorID, secondPlan.victimID)
        XCTAssertEqual(secondPlan.survivorID, records[2].id)
        first.remoteDeletedSnapshotIDs.insert(secondPlan.victimID)
        XCTAssertNil(try first.snapshotCleanupRecords(for: firstPlan))
    }

    func testCachedProofRechecksCurrentOutboxAndDeletionEvidence() throws {
        let records = try chain()
        var state = try state(records)
        let plans = try state.proposedSnapshotCleanupPlans()
        try state.persistSnapshotCleanupPlans(plans)
        let plan = try XCTUnwrap(plans.first)
        let proofs = try state.snapshotCleanupRecords(for: plans)
        let proof = try XCTUnwrap(proofs[plan.victimID])
        XCTAssertNotNil(state.snapshotCleanupRecords(for: plan, reusing: proof))
        state.outbox[plan.survivorID] = proof.survivor
        XCTAssertNil(state.snapshotCleanupRecords(for: plan, reusing: proof))
        state.outbox = [:]
        state.remoteDeletedSnapshotIDs.insert(plan.survivorID)
        XCTAssertNil(state.snapshotCleanupRecords(for: plan, reusing: proof))
    }

    func testEqualHistoryUsesImmutableIDOrder() throws {
        let latest = try chain()[2]
        let document = try Document(latest.snapshot.data)
        let changes = try document.encodeChangesSince(heads: [])
        let alternate = SyncRecord(snapshot: NoteSnapshot(
            data: changes, heads: latest.snapshot.heads,
            noteID: latest.snapshot.noteID), notebookID: try XCTUnwrap(latest.notebookID))
        try alternate.validate()
        XCTAssertNotEqual(latest.id, alternate.id)
        let lower = latest.id < alternate.id ? latest : alternate
        let greater = latest.id < alternate.id ? alternate : latest
        for records in [[lower, greater], [greater, lower]] {
            let plans = try state(records).proposedSnapshotCleanupPlans()
            XCTAssertEqual(plans, [.init(victimID: lower.id, survivorID: greater.id)])
        }
    }

    func testCatalogCleanupUsesCatalogHistory() throws {
        let catalog = try NotebookCatalogDocument(notebookID: UUID())
        let old = SyncRecord(catalog: catalog.snapshot())
        try catalog.add(kind: .note, name: "Fictional note")
        let latest = SyncRecord(catalog: catalog.snapshot())
        let plans = try state([old, latest]).proposedSnapshotCleanupPlans()
        XCTAssertEqual(plans, [.init(victimID: old.id, survivorID: latest.id)])
    }
}
