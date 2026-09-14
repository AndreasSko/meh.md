import Foundation
import XCTest

@testable import NotebookAppModel

final class NotebookBrowserSelectionTests: XCTestCase {
    private let first = UUID(
        uuidString: "00000000-0000-0000-0000-000000000001"
    )!
    private let second = UUID(
        uuidString: "00000000-0000-0000-0000-000000000002"
    )!
    private let third = UUID(
        uuidString: "00000000-0000-0000-0000-000000000003"
    )!

    func testSelectOnlyReplacesTheExactBrowserSelection() {
        var selection = NotebookBrowserSelection()
        selection.toggle(first)
        selection.toggle(second)

        selection.selectOnly(third)

        XCTAssertEqual(selection.selectedIDs, [third])
        XCTAssertEqual(selection.count, 1)
        XCTAssertTrue(selection.contains(third))
        XCTAssertFalse(selection.contains(first))
    }

    func testToggleSelectAllAndClear() {
        var selection = NotebookBrowserSelection()
        selection.toggle(first)
        selection.toggle(second)
        selection.toggle(first)
        XCTAssertEqual(selection.selectedIDs, [second])

        selection.selectAll([third, first, third])
        XCTAssertEqual(selection.selectedIDs, [first, third])

        selection.clear()
        XCTAssertTrue(selection.isEmpty)
        XCTAssertEqual(selection.count, 0)
    }

    func testPruneRemovesInactiveIDsAndKeepsActiveSelection() {
        var selection = NotebookBrowserSelection()
        selection.selectAll([first, second, third])

        selection.prune(to: [third, first])

        XCTAssertEqual(selection.selectedIDs, [first, third])
    }

    func testOrderedIDsFollowCurrentSuppliedDisplayOrder() {
        var selection = NotebookBrowserSelection()
        selection.toggle(third)
        selection.toggle(first)

        XCTAssertEqual(
            selection.orderedIDs(in: [second, first, third]),
            [first, third]
        )
        XCTAssertEqual(
            selection.orderedIDs(in: [third, second, first]),
            [third, first]
        )
    }
}
