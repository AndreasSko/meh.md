import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class NotebookHistoryWorkingSetTests: XCTestCase {
    func testDefaultCacheRetainsAThousandNoteSweep() async throws {
        let checker = NotebookHistoryChecker()
        let catalog = try NotebookCatalogDocument(notebookID: notebookID)
        let records = try makeRecords(count: 1_000)
            + [SyncRecord(catalog: catalog.snapshot())]
        let checkpoints = heads(for: records)

        try await assertContains(checker,
            checkpoints, records: records, deleted: []
        )
        await assertDecodeCount(checker, 1_001)
        try await assertContains(checker,
            checkpoints, records: records, deleted: []
        )
        await assertDecodeCount(checker, 1_001)
    }

    func testOverCapacitySweepKeepsStableResidents() async throws {
        let checker = NotebookHistoryChecker(maximumEntries: 3)
        let records = try makeRecords(count: 7)
        let checkpoints = heads(for: records)

        for _ in 0..<3 {
            try await assertContains(checker,
                checkpoints, records: records, deleted: []
            )
        }
        // Seven decodes to warm, then four misses per pass. A cycling LRU
        // would decode all seven records on every repeated full sweep.
        await assertDecodeCount(checker, 15)
    }

    func testBytePressureRetainsAStableSubset() async throws {
        let records = try makeRecords(count: 3).sorted {
            $0.documentKey < $1.documentKey
        }
        let costs = try records.map { record in
            record.snapshot.data.count
                + (try NoteDocument(snapshot: record.snapshot)).historyHeads.count * 128
        }
        let budget = try XCTUnwrap(costs.max())
        XCTAssertGreaterThan(2 * costs.min()!, budget)
        let checker = NotebookHistoryChecker(
            maximumEntries: 3, maximumBytes: budget
        )
        let checkpoints = heads(for: records)

        for _ in 0..<3 {
            try await assertContains(checker,
                checkpoints, records: records, deleted: []
            )
        }
        await assertDecodeCount(checker, 7)
    }

    func testChangeRollbackAndRemovalUnderEntryPressure() async throws {
        let checker = NotebookHistoryChecker(maximumEntries: 2)
        let original = try makeRecords(count: 3).sorted {
            $0.documentKey < $1.documentKey
        }
        let checkpoints = heads(for: original)
        try await assertContains(checker,
            checkpoints, records: original, deleted: []
        )
        await assertDecodeCount(checker, 3)

        let document = try NoteDocument(snapshot: original[0].snapshot)
        try document.replaceAll(with: "changed")
        let changed = SyncRecord(snapshot: document.snapshot(),
                                 notebookID: try XCTUnwrap(original[0].notebookID))
        var updated = original
        updated[0] = changed
        try await assertContains(checker,
            checkpoints, records: updated, deleted: []
        )
        await assertDecodeCount(checker, 5)

        // A rollback to the original bytes must be decoded again; it must
        // never borrow the newer cached history.
        try await assertContains(checker,
            checkpoints, records: original, deleted: []
        )
        await assertDecodeCount(checker, 7)

        let remaining = Array(original.dropFirst())
        try await assertContains(checker,
            checkpoints, records: remaining, deleted: [], expected: false
        )
        try await assertContains(checker,
            checkpoints, records: remaining,
            deleted: [original[0].snapshot.noteID]
        )
        await assertDecodeCount(checker, 8)
        try await assertContains(checker,
            checkpoints, records: original, deleted: []
        )
        await assertDecodeCount(checker, 9)
    }

    func testForgedResidentAndDisabledCache() async throws {
        let records = try makeRecords(count: 2).sorted {
            $0.documentKey < $1.documentKey
        }
        let record = records[0]
        let checkpoints = heads(for: records)
        let checker = NotebookHistoryChecker(maximumEntries: 1)
        try await assertContains(checker,
            checkpoints, records: records, deleted: []
        )
        let forgeries = [
            NoteSnapshot(
                data: record.snapshot.data,
                heads: ["forged"],
                noteID: record.snapshot.noteID
            ),
            NoteSnapshot(
                data: Data("broken".utf8),
                heads: record.snapshot.heads,
                noteID: record.snapshot.noteID
            ),
        ]
        for forged in forgeries {
            var changed = records
            changed[0] = SyncRecord(
                snapshot: forged,
                notebookID: try XCTUnwrap(record.notebookID)
            )
            do {
                _ = try await checker.containsHistory(
                    checkpoints, records: changed, deleted: []
                )
                XCTFail("Forged record must not reuse a resident history")
            } catch { }
            try await assertContains(checker,
                checkpoints, records: records, deleted: []
            )
        }
        await assertDecodeCount(checker, 6)

        let disabled = NotebookHistoryChecker(maximumEntries: 0)
        for _ in 0..<2 {
            try await assertContains(disabled,
                checkpoints, records: records, deleted: []
            )
        }
        await assertDecodeCount(disabled, 4)
    }

    func testCancelledFullSweepCannotReturnCachedSuccess() async throws {
        let checker = NotebookHistoryChecker(maximumEntries: 1)
        let records = try makeRecords(count: 2)
        let checkpoints = heads(for: records)
        try await assertContains(checker,
            checkpoints, records: records, deleted: []
        )
        let task = Task { @MainActor in
            try await checker.containsHistory(
                checkpoints, records: records, deleted: []
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must prevent an unchanged cached success")
        } catch is CancellationError { }
        await assertDecodeCount(checker, 2)
    }

    private var notebookID: UUID {
        UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    }

    private func assertContains(
        _ checker: NotebookHistoryChecker,
        _ checkpoints: [String: Set<String>],
        records: [SyncRecord],
        deleted: Set<UUID>,
        expected: Bool = true
    ) async throws {
        let result = try await checker.containsHistory(
            checkpoints, records: records, deleted: deleted
        )
        XCTAssertEqual(result, expected)
    }

    private func assertDecodeCount(
        _ checker: NotebookHistoryChecker,
        _ expected: Int
    ) async {
        let actual = await checker.decodedSnapshotCount
        XCTAssertEqual(actual, expected)
    }

    private func makeRecords(count: Int) throws -> [SyncRecord] {
        return try (0..<count).map { index in
            let document = try NoteDocument(text: "Fictional \(index)")
            return SyncRecord(snapshot: document.snapshot(), notebookID: notebookID)
        }
    }

    private func heads(for records: [SyncRecord]) -> [String: Set<String>] {
        Dictionary(uniqueKeysWithValues: records.map {
            ($0.documentKey, $0.snapshot.heads)
        })
    }
}
