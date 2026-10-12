import Foundation
@testable import NoteCore
import XCTest

final class CloudKitRecordEvidenceCacheTests: XCTestCase {
    func testExactRecordReuseBoundsAndRestart() throws {
        let note = try NoteDocument(noteID: UUID())
        let first = SyncRecord(snapshot: note.snapshot(), notebookID: UUID())
        try note.replaceAll(with: "Fictional revision")
        let second = SyncRecord(snapshot: note.snapshot(), notebookID: first.notebookID!)
        var cache = CloudKitRecordEvidenceCache<Set<String>>(maximumEntries: 1)
        var loads = 0
        func load(_ record: SyncRecord) throws -> Set<String> {
            loads += 1
            return try snapshotHistoryChangeHashes(record)
        }
        let original = try cache.value(for: first, compute: load)
        XCTAssertEqual(try cache.value(for: first, compute: load), original)
        XCTAssertEqual(loads, 1)
        _ = try cache.value(for: second, compute: load)
        _ = try cache.value(for: first, compute: load)
        XCTAssertEqual(loads, 3)
        cache.removeAll()
        _ = try cache.value(for: first, compute: load)
        XCTAssertEqual(loads, 4)
        cache = CloudKitRecordEvidenceCache()
        _ = try cache.value(for: first, compute: load)
        XCTAssertEqual(loads, 5)
    }

    func testOversizedEvidenceIsComputedWithoutRetainingPayload() throws {
        let record = SyncRecord(
            snapshot: try NoteDocument(noteID: UUID()).snapshot(), notebookID: UUID()
        )
        var cache = CloudKitRecordEvidenceCache<Set<String>>(maximumPayloadBytes: 1)
        var loads = 0
        for _ in 0..<2 {
            _ = try cache.value(for: record) {
                loads += 1
                return try snapshotHistoryChangeHashes($0)
            }
        }
        XCTAssertEqual(loads, 2)
    }

    func testSameIDChangedBytesAndIdentityCannotReuseEvidence() throws {
        let record = SyncRecord(
            snapshot: try NoteDocument(noteID: UUID()).snapshot(), notebookID: UUID()
        )
        var cache = CloudKitRecordEvidenceCache<Set<String>>()
        _ = try cache.value(for: record, compute: snapshotHistoryChangeHashes)
        for key in ["snapshot", "notebookID"] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(
                with: JSONEncoder().encode(record)
            ) as? [String: Any])
            if key == "snapshot" {
                var snapshot = try XCTUnwrap(json[key] as? [String: Any])
                snapshot["data"] = Data("corrupt".utf8).base64EncodedString()
                json[key] = snapshot
            } else {
                json[key] = UUID().uuidString
            }
            let altered = try JSONDecoder().decode(SyncRecord.self, from:
                JSONSerialization.data(withJSONObject: json))
            var calls = 0
            XCTAssertThrowsError(try cache.value(for: altered) { value in
                calls += 1
                try value.validate()
                return try snapshotHistoryChangeHashes(value)
            })
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(try cache.value(for: record, compute: snapshotHistoryChangeHashes),
                           try snapshotHistoryChangeHashes(record))
        }
    }

    func testCatalogOnlyDeletionAndNoOpDoNotLoadMarkers() throws {
        let catalog = try NotebookCatalogDocument(notebookID: UUID())
        let record = SyncRecord(catalog: catalog.snapshot())
        var state = CloudKitTransportState(
            accountRecordName: "account", zoneName: "zone", protocolVersion: 2
        )
        try state.appendToInbox(record)
        var loads = 0
        let loader: (SyncRecord) throws -> Set<UUID> = { _ in loads += 1; return [] }
        try state.resolveRemoteNoteDeletions(permanentMarkers: loader)
        state.observeRemoteDeletions([record.id], bootstrapRecordName: "bootstrap")
        try state.resolveRemoteNoteDeletions(permanentMarkers: loader)
        XCTAssertEqual(loads, 0)
        XCTAssertEqual(state.unresolvedRemoteDeletionRecordIDs, [record.id])
    }

    func testNewMarkerDuringFetchResolvesOnlyAfterNewEvidence() throws {
        let notebookID = UUID()
        let catalog = try NotebookCatalogDocument(notebookID: notebookID)
        let id = try catalog.add(kind: .note, name: "Fictional note")
        let note = SyncRecord(snapshot: try NoteDocument(noteID: id).snapshot(),
                              notebookID: notebookID)
        let first = SyncRecord(catalog: catalog.snapshot())
        var state = CloudKitTransportState(
            accountRecordName: "account", zoneName: "zone", protocolVersion: 2
        )
        try state.appendToInbox(first)
        try state.appendToInbox(note)
        state.observeRemoteDeletions([note.id], bootstrapRecordName: "bootstrap")
        var cache = CloudKitRecordEvidenceCache<Set<UUID>>()
        var loads = 0
        func load(_ record: SyncRecord) throws -> Set<UUID> {
            loads += 1
            return try catalogPermanentMarkers(record)
        }
        for _ in 0..<2 {
            try state.resolveRemoteNoteDeletions {
                try cache.value(for: $0, compute: load)
            }
        }
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(state.unresolvedRemoteDeletionRecordIDs, [note.id])
        try catalog.setTrashed(id, true)
        try catalog.markPermanentlyDeleted([id])
        try state.appendToInbox(SyncRecord(catalog: catalog.snapshot()))
        try state.resolveRemoteNoteDeletions {
            try cache.value(for: $0, compute: load)
        }
        XCTAssertEqual(loads, 2)
        XCTAssertTrue(state.unresolvedRemoteDeletionRecordIDs.isEmpty)
    }
}
