import Foundation
import XCTest

@testable import NoteCore

final class NoteHistoryChangesTests: XCTestCase {
    func testIdenticalTextHasNoChanges() {
        XCTAssertEqual(NoteHistoryChanges(from: "A\nB", to: "A\nB"), .none)
    }

    func testEditedLineIsOneChangeWithoutRemoval() {
        let changes = NoteHistoryChanges(
            from: "Title\nOld line\nEnd", to: "Title\nNew line\nEnd"
        )
        XCTAssertEqual(changes.changed, [NSRange(location: 6, length: 8)])
        XCTAssertEqual(changes.removed, [])
    }

    func testAdjacentAddedLinesMergeIntoOneRange() {
        let changes = NoteHistoryChanges(from: "A\nD", to: "A\nB\nC\nD")
        XCTAssertEqual(changes.changed, [NSRange(location: 2, length: 3)])
    }

    func testRemovedLinesPointAtTheLineThatFollows() {
        let changes = NoteHistoryChanges(
            from: "A\n- [ ] Rent a car\n- [ ] Pack\nB", to: "A\nB"
        )
        XCTAssertEqual(changes.changed, [])
        XCTAssertEqual(changes.removed, [.init(
            location: 2, text: "- [ ] Rent a car\n- [ ] Pack"
        )])
    }

    func testRemovalAtTheEndPointsAtTheEndOfTheText() {
        let changes = NoteHistoryChanges(from: "A\nB\nC", to: "A\nB")
        XCTAssertEqual(changes.removed, [.init(location: 3, text: "C")])
    }

    func testAddedBlankLineHasAnEmptyRange() {
        let changes = NoteHistoryChanges(from: "A\nB", to: "A\n\nB")
        XCTAssertEqual(changes.changed, [NSRange(location: 2, length: 0)])
    }

    func testRangesCountUTF16LikeTheEditor() {
        let changes = NoteHistoryChanges(
            from: "Café 👋🏽\nold", to: "Café 👋🏽\nnew"
        )
        let start = ("Café 👋🏽\n" as NSString).length
        XCTAssertEqual(changes.changed, [NSRange(location: start, length: 3)])
    }

    func testEmptyBaseMarksTheWholeText() {
        let changes = NoteHistoryChanges(from: "", to: "A\nB")
        XCTAssertEqual(changes.changed, [NSRange(location: 0, length: 3)])
    }

    func testSeparateChangesStaySeparate() {
        let changes = NoteHistoryChanges(
            from: "1\n2\n3\n4\n5", to: "1\nX\n3\n5"
        )
        XCTAssertEqual(changes.changed, [NSRange(location: 2, length: 1)])
        XCTAssertEqual(changes.removed, [.init(location: 6, text: "4")])
    }

    func testFewerLinesInPlaceOfOldOnesKeepTheOldText() {
        let changes = NoteHistoryChanges(from: "A\nB\nC\nD", to: "A\nX\nD")
        XCTAssertEqual(changes.changed, [NSRange(location: 2, length: 1)])
        XCTAssertEqual(changes.removed, [.init(location: 4, text: "B\nC")])
    }

    func testCRLFLinesCompareOneByOne() {
        let changes = NoteHistoryChanges(
            from: "Title\r\nOld\r\nEnd\r\n", to: "Title\r\nNew line\r\nEnd\r\n"
        )
        XCTAssertEqual(changes.changed, [NSRange(location: 7, length: 9)])
        XCTAssertEqual(changes.removed, [])
    }

    func testOversizedRewriteMarksTheMiddleWithoutDiffing() {
        let count = 2_001
        XCTAssertGreaterThan(count * count, NoteHistoryChanges.diffComparisonLimit)
        let old = (0 ..< count).map { "old \($0)" }.joined(separator: "\n")
        let new = (0 ..< count).map { "new \($0)" }.joined(separator: "\n")
        let changes = NoteHistoryChanges(from: "Head\n" + old, to: "Head\n" + new)
        XCTAssertEqual(changes.changed, [NSRange(
            location: 5, length: (new as NSString).length
        )])
        XCTAssertEqual(changes.removed, [])
    }

    func testReaderComparesVersionsAndReusesTheResult() async throws {
        let start = Date(timeIntervalSince1970: 100)
        let note = try NoteDocument(
            text: "A\nB",
            metadata: NoteMetadata(createdAt: start, modifiedAt: start)
        )
        try note.replaceAll(with: "A\nB\nC", at: start.addingTimeInterval(100))
        try note.replaceAll(with: "A\nC", at: start.addingTimeInterval(200))
        let reader = NoteHistoryReader(snapshot: note.snapshot())
        var versions: [NoteHistoryVersion] = []
        for try await update in await reader.updates() {
            versions = update.versions
        }
        XCTAssertEqual(versions.count, 2)
        let changes = try await reader.changes(for: versions[1], since: versions[0])
        XCTAssertEqual(changes, NoteHistoryChanges(from: "A\nB", to: "A\nB\nC"))
        let reads = await reader.previewReadCount
        let again = try await reader.changes(for: versions[1], since: versions[0])
        XCTAssertEqual(again, changes)
        let readsAfterRepeat = await reader.previewReadCount
        XCTAssertEqual(readsAfterRepeat, reads)
        let first = try await reader.changes(for: versions[0], since: nil)
        XCTAssertEqual(first.changed, [NSRange(location: 0, length: 3)])
    }
}
