import CoreGraphics
import Foundation
import NoteCore
import XCTest

@testable import NativeEditor

@MainActor
final class MarkdownHistoryMarksTests: XCTestCase {
    private let line = CGRect(x: 0, y: 20, width: 300, height: 18)

    private func marks(
        _ changes: NoteHistoryChanges, _ location: Int, _ length: Int, textLength: Int
    ) -> MarkdownHistoryMarks.Marks {
        MarkdownHistoryMarks.marks(
            for: changes, fragmentRange: NSRange(location: location, length: length),
            lineBounds: line, textLength: textLength
        )
    }

    func testChangedLineGetsABarBesideItsLines() {
        let changes = NoteHistoryChanges(from: "A\nB\nC", to: "A\nX\nC")
        XCTAssertNil(marks(changes, 0, 2, textLength: 5).bar)
        let bar = marks(changes, 2, 2, textLength: 5).bar
        XCTAssertEqual(bar?.minY, line.minY)
        XCTAssertEqual(bar?.height, line.height)
        XCTAssertLessThan(bar?.maxX ?? 0, 0)
        XCTAssertNil(marks(changes, 4, 1, textLength: 5).bar)
    }

    func testAddedBlankLineMarksTheFragmentThatStartsThere() {
        let changes = NoteHistoryChanges(from: "A\nB", to: "A\n\nB")
        XCTAssertNil(marks(changes, 0, 2, textLength: 4).bar)
        XCTAssertNotNil(marks(changes, 2, 1, textLength: 4).bar)
        XCTAssertNil(marks(changes, 3, 1, textLength: 4).bar)
    }

    func testLineBreakAddedAtTheEndMarksTheLastLine() {
        let changes = NoteHistoryChanges(from: "A\nB", to: "A\nB\n")
        XCTAssertEqual(changes.changed, [NSRange(location: 4, length: 0)])
        XCTAssertNil(marks(changes, 0, 2, textLength: 4).bar)
        XCTAssertNotNil(marks(changes, 2, 2, textLength: 4).bar)
    }

    func testRemovalRingSitsAboveTheLineThatFollows() {
        let changes = NoteHistoryChanges(from: "A\nGone\nB", to: "A\nB")
        let rings = marks(changes, 2, 1, textLength: 3).rings
        XCTAssertEqual(rings.map(\.removal.text), ["Gone"])
        XCTAssertEqual(rings.first?.center.y, line.minY - 1)
        XCTAssertEqual(marks(changes, 0, 2, textLength: 3).rings, [])
    }

    func testRemovalAtTheEndSitsBelowTheLastLine() {
        let changes = NoteHistoryChanges(from: "A\nB\nGone", to: "A\nB")
        let rings = marks(changes, 2, 1, textLength: 3).rings
        XCTAssertEqual(rings.map(\.removal.text), ["Gone"])
        XCTAssertGreaterThan(rings.first?.center.y ?? 0, line.maxY)
        XCTAssertEqual(marks(changes, 0, 2, textLength: 3).rings, [])
    }

    func testNoChangesDrawNothing() {
        XCTAssertTrue(marks(.none, 0, 5, textLength: 5).isEmpty)
    }
}
