import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class NotebookHistoryCheckerTests: XCTestCase {
    func testUnchangedSnapshotsReuseHistoryAndChangedNoteIsRechecked() async throws {
        let checker = NotebookHistoryChecker()
        let catalog = try NotebookCatalogDocument()
        let note = try NoteDocument(text: "base")
        let records = [SyncRecord(catalog: catalog.snapshot()),
                       SyncRecord(snapshot: note.snapshot(), notebookID: catalog.notebookID)]
        let checkpoints = Dictionary(uniqueKeysWithValues:
            records.map { ($0.documentKey, $0.snapshot.heads) })
        for _ in 0..<3 {
            let contains = try await checker.containsHistory(
                checkpoints, records: records, deleted: []
            )
            XCTAssertTrue(contains)
        }
        let initialCount = await checker.decodedSnapshotCount
        XCTAssertEqual(initialCount, 2)

        try note.replaceAll(with: "later")
        let changed = [records[0], SyncRecord(snapshot: note.snapshot(),
                                             notebookID: catalog.notebookID)]
        let contains = try await checker.containsHistory(
            checkpoints, records: changed, deleted: []
        )
        XCTAssertTrue(contains)
        let updatedCount = await checker.decodedSnapshotCount
        XCTAssertEqual(updatedCount, 3)
    }

    func testCachedHistoryCannotHideMissingFileOrRollback() async throws {
        let checker = NotebookHistoryChecker()
        let note = try NoteDocument(text: "base")
        let original = SyncRecord(snapshot: note.snapshot())
        try note.replaceAll(with: "new revision")
        let latest = SyncRecord(snapshot: note.snapshot())
        let checkpoints = [latest.documentKey: latest.snapshot.heads]
        let warm = try await checker.containsHistory(
            checkpoints, records: [latest], deleted: []
        )
        XCTAssertTrue(warm)
        let missing = try await checker.containsHistory(checkpoints, records: [], deleted: [])
        XCTAssertFalse(missing)
        let rolledBack = try await checker.containsHistory(
            checkpoints, records: [original], deleted: []
        )
        XCTAssertFalse(rolledBack)
        let deleted = try await checker.containsHistory(
            checkpoints, records: [], deleted: [note.noteID]
        )
        XCTAssertTrue(deleted)
    }

    func testForgedHeadsAndCorruptBytesCannotReuseCachedValidation() async throws {
        let checker = NotebookHistoryChecker()
        let snapshot = try NoteDocument(text: "base").snapshot()
        let record = SyncRecord(snapshot: snapshot)
        let checkpoints = [record.documentKey: snapshot.heads]
        _ = try await checker.containsHistory(checkpoints, records: [record], deleted: [])
        let forged = [
            NoteSnapshot(data: snapshot.data, heads: ["forged"], noteID: snapshot.noteID),
            NoteSnapshot(data: Data("broken".utf8), heads: snapshot.heads,
                         noteID: snapshot.noteID),
        ]
        for invalid in forged {
            do {
                _ = try await checker.containsHistory(
                    checkpoints, records: [SyncRecord(snapshot: invalid)], deleted: []
                )
                XCTFail("A cached revision must not bypass snapshot validation")
            } catch { }
        }
        let restored = try await checker.containsHistory(
            checkpoints, records: [record], deleted: []
        )
        XCTAssertTrue(restored)
    }

    func testChangedCatalogEnvelopeIsValidatedAgain() async throws {
        let checker = NotebookHistoryChecker()
        let catalog = try NotebookCatalogDocument()
        let record = SyncRecord(catalog: catalog.snapshot())
        let checkpoints = [record.documentKey: record.snapshot.heads]
        _ = try await checker.containsHistory(checkpoints, records: [record], deleted: [])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(record)
        ) as? [String: Any])
        json["notebookID"] = UUID().uuidString
        let invalid = try JSONDecoder().decode(SyncRecord.self, from:
            JSONSerialization.data(withJSONObject: json))
        do {
            _ = try await checker.containsHistory(checkpoints, records: [invalid], deleted: [])
            XCTFail("A changed notebook identity must not reuse cached history")
        } catch { }
    }

    func testEvictionAndOversizedRecordsStillCheckCorrectly() async throws {
        let first = SyncRecord(snapshot: try NoteDocument(text: "first").snapshot())
        let second = SyncRecord(snapshot: try NoteDocument(text: "second").snapshot())
        let checker = NotebookHistoryChecker(maximumEntries: 1)
        for record in [first, second, first] {
            let result = try await checker.containsHistory(
                [record.documentKey: record.snapshot.heads], records: [record], deleted: []
            )
            XCTAssertTrue(result)
        }
        let decodes = await checker.decodedSnapshotCount
        XCTAssertEqual(decodes, 3)
        let tiny = NotebookHistoryChecker(maximumBytes: 1)
        for _ in 0..<2 {
            let result = try await tiny.containsHistory(
                [first.documentKey: first.snapshot.heads], records: [first], deleted: []
            )
            XCTAssertTrue(result)
        }
        let oversizedDecodes = await tiny.decodedSnapshotCount
        XCTAssertEqual(oversizedDecodes, 2)
    }

    func testCancellationDoesNotReturnCachedSuccess() async throws {
        let checker = NotebookHistoryChecker()
        let record = SyncRecord(snapshot: try NoteDocument(text: "base").snapshot())
        let task = Task { @MainActor in
            try await checker.containsHistory(
                [record.documentKey: record.snapshot.heads], records: [record], deleted: []
            )
        }
        // This main-actor test cancels before the task can begin.
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled checkpoint work must not acknowledge progress")
        } catch is CancellationError { }
    }
}
