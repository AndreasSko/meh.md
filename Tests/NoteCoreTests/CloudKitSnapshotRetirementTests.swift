import Foundation
@testable import NoteCore
import XCTest

final class CloudKitSnapshotRetirementTests: XCTestCase {
    private func state() -> CloudKitTransportState {
        CloudKitTransportState(
            accountRecordName: "account", zoneName: "zone", protocolVersion: 2
        )
    }

    private func observe(_ record: SyncRecord, in state: inout CloudKitTransportState) {
        state.observeRemoteDeletions([record.id], bootstrapRecordName: "bootstrap")
    }

    func testNoteRetirementRequiresConfirmedDescendantInEitherOrder() throws {
        let notebookID = UUID()
        let note = try NoteDocument(noteID: UUID())
        let old = SyncRecord(snapshot: note.snapshot(), notebookID: notebookID)
        try note.replaceAll(with: "new text")
        let descendant = SyncRecord(snapshot: note.snapshot(), notebookID: notebookID)
        for deletionFirst in [true, false] {
            var state = state()
            try state.appendToInbox(old)
            if deletionFirst { observe(old, in: &state) }
            try state.appendToInbox(descendant)
            if !deletionFirst { observe(old, in: &state) }
            XCTAssertThrowsError(try state.validateRemoteDeletions())
            XCTAssertEqual(try state.retirementCandidates(), [descendant])
            try state.resolveSnapshotRetirements(confirmedRecords: [descendant])
            try state.validateRemoteDeletions()
            XCTAssertEqual(state.inbox, [old, descendant])
            XCTAssertTrue(state.remoteDeletedSnapshotIDs.contains(old.id))
        }
    }

    func testConcurrentHistoryMustIncludeEveryDeletedBranch() throws {
        let notebookID = UUID()
        let initial = try NoteDocument(noteID: UUID())
        let left = try NoteDocument(snapshot: initial.snapshot())
        let right = try NoteDocument(snapshot: initial.snapshot())
        try left.replaceAll(with: "left")
        try right.replaceAll(with: "right")
        let leftRecord = SyncRecord(snapshot: left.snapshot(), notebookID: notebookID)
        let rightRecord = SyncRecord(snapshot: right.snapshot(), notebookID: notebookID)
        try left.replaceAll(with: "left later")
        let partial = SyncRecord(snapshot: left.snapshot(), notebookID: notebookID)
        var state = state()
        for record in [leftRecord, rightRecord, partial] { try state.appendToInbox(record) }
        observe(leftRecord, in: &state)
        observe(rightRecord, in: &state)
        try state.resolveSnapshotRetirements(confirmedRecords: [partial])
        XCTAssertEqual(state.unresolvedRemoteDeletionRecordIDs, [rightRecord.id])
        XCTAssertThrowsError(try state.validateRemoteDeletions())
        try left.merge(right)
        let merged = SyncRecord(snapshot: left.snapshot(), notebookID: notebookID)
        try state.appendToInbox(merged)
        try state.resolveSnapshotRetirements(confirmedRecords: [merged])
        try state.validateRemoteDeletions()
    }

    func testCatalogDescendantRetiresOrdinarySnapshotInEitherOrder() throws {
        let catalog = try NotebookCatalogDocument(notebookID: UUID())
        let old = SyncRecord(catalog: catalog.snapshot())
        try catalog.add(kind: .note, name: "Fictional note")
        let descendant = SyncRecord(catalog: catalog.snapshot())
        for deletionFirst in [true, false] {
            var state = state()
            try state.appendToInbox(old)
            if deletionFirst { observe(old, in: &state) }
            try state.appendToInbox(descendant)
            if !deletionFirst { observe(old, in: &state) }
            XCTAssertFalse(state.hasUnexpectedDeletion)
            XCTAssertEqual(try state.retirementCandidates(), [descendant])
            try state.resolveSnapshotRetirements(confirmedRecords: [descendant])
            try state.validateRemoteDeletions()
            XCTAssertEqual(state.inbox, [old, descendant])
        }
    }

    func testDeletionDuringConfirmationRejectsStaleSurvivor() throws {
        let notebookID = UUID()
        let note = try NoteDocument(noteID: UUID())
        let old = SyncRecord(snapshot: note.snapshot(), notebookID: notebookID)
        try note.replaceAll(with: "later")
        let later = SyncRecord(snapshot: note.snapshot(), notebookID: notebookID)
        var state = state()
        try state.appendToInbox(old)
        try state.appendToInbox(later)
        observe(old, in: &state)
        XCTAssertEqual(try state.retirementCandidates(), [later])
        observe(later, in: &state)
        try state.resolveSnapshotRetirements(confirmedRecords: [later])
        XCTAssertEqual(state.unresolvedRemoteDeletionRecordIDs, [old.id, later.id])
    }

    func testDeletedCoveringSnapshotCannotResolveEarlierDeletion() throws {
        let notebookID = UUID()
        let note = try NoteDocument(noteID: UUID())
        let old = SyncRecord(snapshot: note.snapshot(), notebookID: notebookID)
        try note.replaceAll(with: "later")
        let later = SyncRecord(snapshot: note.snapshot(), notebookID: notebookID)
        var state = state()
        try state.appendToInbox(old)
        try state.appendToInbox(later)
        observe(old, in: &state)
        try state.resolveSnapshotRetirements(confirmedRecords: [later])
        observe(later, in: &state)
        XCTAssertTrue(try state.retirementCandidates().isEmpty)
        try state.resolveSnapshotRetirements(confirmedRecords: [later])
        XCTAssertThrowsError(try state.validateRemoteDeletions())
        XCTAssertEqual(state.remoteDeletedSnapshotIDs, [old.id, later.id])
    }

    func testWrongNotebookAndOutboxCannotCoverDeletion() throws {
        let notebookID = UUID()
        let note = try NoteDocument(noteID: UUID())
        let old = SyncRecord(snapshot: note.snapshot(), notebookID: notebookID)
        try note.replaceAll(with: "later")
        let wrongNotebook = SyncRecord(snapshot: note.snapshot(), notebookID: UUID())
        let localOnly = SyncRecord(snapshot: note.snapshot(), notebookID: notebookID)
        var state = state()
        try state.appendToInbox(old)
        try state.appendToInbox(wrongNotebook)
        state.outbox[localOnly.id] = localOnly
        observe(old, in: &state)
        XCTAssertTrue(try state.retirementCandidates().isEmpty)
        try state.resolveSnapshotRetirements(confirmedRecords: [wrongNotebook, localOnly])
        XCTAssertThrowsError(try state.validateRemoteDeletions())
    }

    func testRestartPreservesEvidenceAndCursorAndOldStateDecodes() throws {
        let note = try NoteDocument(noteID: UUID())
        let record = SyncRecord(snapshot: note.snapshot(), notebookID: UUID())
        var original = state()
        try original.appendToInbox(record)
        observe(record, in: &original)
        let cursor = try original.page(after: nil, limit: 1).cursor
        let encoded = try JSONEncoder().encode(original)
        var restored = try JSONDecoder().decode(CloudKitTransportState.self, from: encoded)
        XCTAssertEqual(restored, original)
        XCTAssertEqual(try restored.page(after: cursor, limit: 1).records, [])
        XCTAssertTrue(try restored.appendToInboxIfChanged(record))
        XCTAssertTrue(restored.remoteDeletedSnapshotIDs.isEmpty)
        XCTAssertTrue(restored.unresolvedRemoteDeletionRecordIDs.isEmpty)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "remoteDeletedSnapshotIDs")
        let legacy = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(CloudKitTransportState.self, from: legacy)
        XCTAssertTrue(decoded.remoteDeletedSnapshotIDs.isEmpty)
        XCTAssertEqual(try decoded.page(after: cursor, limit: 1).records, [])
    }
}
