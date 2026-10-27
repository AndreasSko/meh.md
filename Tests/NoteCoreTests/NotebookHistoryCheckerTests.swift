import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class NotebookHistoryCheckerTests: XCTestCase {
    func testProgressUsesCheckpointTotalAndReportsCompletedComparisons() async throws {
        let checker = NotebookHistoryChecker()
        let note = try NoteDocument(text: "fictional progress fixture")
        let record = SyncRecord(snapshot: note.snapshot())
        let deletedID = UUID()
        let checkpoints = [record.documentKey: record.snapshot.heads,
                           "note:\(deletedID.uuidString)": Set<String>()]
        var updates: [(Int, Int)] = []
        let contains = try await checker.containsHistory(
            checkpoints, records: [record], deleted: [deletedID],
            progress: { updates.append(($0, $1)) }
        )
        XCTAssertTrue(contains)
        XCTAssertEqual(updates.map { $0.0 }, [0, 1, 2])
        XCTAssertEqual(updates.map { $0.1 }, [2, 2, 2])
        let decoded = await checker.decodedSnapshotCount
        XCTAssertEqual(decoded, 1)
    }

    func testHexHeadsParseToTheSameChangeHashes() throws {
        let note = try NoteDocument(text: "fictional hash fixture")
        try note.replaceAll(with: "fictional hash fixture, edited")
        XCTAssertEqual(
            NotebookHistoryChecker.changeHashes(note.historyHeads),
            note.historyHashes
        )
        XCTAssertEqual(NotebookHistoryChecker.changeHashes([]), [])

        let head = try XCTUnwrap(note.historyHeads.first)
        for malformed in [head.uppercased(), String(head.dropLast()), head + "0",
                          String(head.dropLast()) + "g"] {
            XCTAssertNil(NotebookHistoryChecker.changeHashes([head, malformed]))
        }
    }

    func testMalformedCheckpointHeadIsReportedMissing() async throws {
        let checker = NotebookHistoryChecker()
        let note = try NoteDocument(text: "fictional malformed fixture")
        let record = SyncRecord(snapshot: note.snapshot())
        let uppercased = Set(record.snapshot.heads.map { $0.uppercased() })
        let contains = try await checker.containsHistory(
            [record.documentKey: uppercased], records: [record], deleted: []
        )
        XCTAssertFalse(contains)
    }

    func testProgressStopsAtFailedComparisonAndThrottlesLargePass() async throws {
        let checker = NotebookHistoryChecker()
        let missing = Dictionary(uniqueKeysWithValues: (0..<1_000).map {
            (String(format: "missing:%04d", $0), Set<String>())
        })
        var updates: [(Int, Int)] = []
        let contains = try await checker.containsHistory(
            missing, records: [], deleted: [],
            progress: { updates.append(($0, $1)) }
        )
        XCTAssertFalse(contains)
        XCTAssertEqual(updates.map { $0.0 }, [0, 1])
        XCTAssertEqual(updates.map { $0.1 }, [1_000, 1_000])

        let ids = (0..<1_000).map { _ in UUID() }
        let deleted = Dictionary(uniqueKeysWithValues: ids.map {
            ("note:\($0.uuidString)", Set<String>())
        })
        updates.removeAll()
        let skipped = try await checker.containsHistory(
            deleted, records: [], deleted: Set(ids),
            progress: { updates.append(($0, $1)) }
        )
        XCTAssertTrue(skipped)
        XCTAssertEqual(updates.first?.0, 0)
        XCTAssertEqual(updates.last?.0, 1_000)
        XCTAssertTrue(updates.allSatisfy { $0.1 == 1_000 })
        XCTAssertLessThanOrEqual(updates.count, 102)
        XCTAssertEqual(updates.map { $0.0 }, updates.map { $0.0 }.sorted())
    }

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
