import Foundation
import XCTest

@testable import NoteCore

final class NoteDocumentTests: XCTestCase {
    private let noteID = UUID(
        uuidString: "9C86E52A-7037-4107-B7AA-148E3308A52D"
    )!

    func testSerializationPreservesHistoryIdentityAndUnicode() throws {
        let original = "# Café\n\ne\u{301} 👋🏽 👨‍👩‍👧‍👦\n"
        let note = try NoteDocument(noteID: noteID, text: original)
        let firstHeads = note.heads
        try note.replaceAll(with: original + "saved\n")

        let reloaded = try NoteDocument(snapshot: note.snapshot())

        XCTAssertEqual(reloaded.noteID, noteID)
        XCTAssertEqual(try reloaded.text, original + "saved\n")
        XCTAssertEqual(reloaded.heads, note.heads)
        XCTAssertTrue(firstHeads.isSubset(of: reloaded.historyHeads))
        XCTAssertGreaterThan(reloaded.historyCount, 1)
    }

    func testReloadedOfflineForkStillMerges() throws {
        let base = try NoteDocument(noteID: noteID, text: "one two")
        let left = try base.fork()
        let right = try base.fork()
        try left.replaceUTF16(
            range: NSRange(location: 0, length: 3),
            with: "ONE"
        )
        try right.replaceUTF16(
            range: NSRange(location: 4, length: 3),
            with: "TWO"
        )

        let savedLeft = try NoteDocument(snapshot: left.snapshot())
        try savedLeft.merge(right)

        XCTAssertEqual(try savedLeft.text, "ONE TWO")
        XCTAssertEqual(savedLeft.noteID, noteID)
    }
}
