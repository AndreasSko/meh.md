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

    func testExtendAddsTheRangeFromTheAnchorInEitherDirection() {
        let fourth = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let order = [first, second, third, fourth]
        var selection = NotebookBrowserSelection()
        selection.toggle(fourth)
        selection.toggle(second)

        selection.extend(to: first, in: order)
        XCTAssertEqual(selection.selectedIDs, [first, second, fourth])

        selection.extend(to: third, in: order)
        XCTAssertEqual(selection.selectedIDs, [first, second, third, fourth])
        XCTAssertEqual(selection.anchorID, second)
    }

    func testExtendWithoutAVisibleAnchorSelectsOnlyTheClickedRow() {
        var selection = NotebookBrowserSelection()
        selection.extend(to: second, in: [first, second, third])
        XCTAssertEqual(selection.selectedIDs, [second])
        XCTAssertEqual(selection.anchorID, second)

        selection.toggle(first)
        selection.extend(to: third, in: [second, third])
        XCTAssertEqual(selection.selectedIDs, [third])
    }

    func testClicksFollowTheMacRulesWhateverTheListProposes() {
        let fourth = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let order = [first, second, third, fourth]
        var selection = NotebookBrowserSelection()

        // A plain click opens the row; the list reports no selection.
        selection.click(first, .plain, proposed: [], in: order)
        XCTAssertTrue(selection.isEmpty)
        selection.click(third, .shift, proposed: [third], in: order)
        XCTAssertEqual(selection.selectedIDs, [first, second, third])

        selection.click(fourth, .command, proposed: [fourth], in: order)
        XCTAssertEqual(selection.selectedIDs, [first, second, third, fourth])
        selection.click(second, .command, proposed: [second], in: order)
        XCTAssertEqual(selection.selectedIDs, [first, third, fourth])

        selection.click(fourth, .plain, proposed: [], in: order)
        XCTAssertTrue(selection.isEmpty)
        XCTAssertEqual(selection.anchorID, fourth)
    }

    func testClickIgnoresProposalsFromOtherInput() {
        let order = [first, second, third]
        var selection = NotebookBrowserSelection()
        selection.click(first, .command, proposed: [first], in: order)
        selection.click(second, .command, proposed: [second], in: order)

        // An arrow key moved to the third row after a click on the first
        // row's disclosure button selected nothing.
        XCTAssertFalse(selection.click(first, .command, proposed: [third], in: order))
        XCTAssertEqual(selection.selectedIDs, [first, second])

        // Command-clicking a selected row may report it alone or without it.
        XCTAssertTrue(selection.click(first, .command, proposed: [second], in: order))
        XCTAssertEqual(selection.selectedIDs, [second])
    }

    func testShiftClickAcceptsTheListsPartialRange() {
        let order = [first, second, third]
        var selection = NotebookBrowserSelection()
        selection.click(first, .command, proposed: [first], in: order)

        XCTAssertTrue(selection.click(third, .shift, proposed: [second], in: order))
        XCTAssertEqual(selection.selectedIDs, [first, second, third])

        selection.click(second, .plain, proposed: [], in: order)
        XCTAssertFalse(selection.click(first, .shift, proposed: [third], in: order))
        XCTAssertTrue(selection.isEmpty)
    }

    func testCommandAndShiftClicksStartFromTheOpenNote() {
        let fourth = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let order = [first, second, third, fourth]
        var selection = NotebookBrowserSelection()

        // The note was opened from Recents or with a plain click on iPad,
        // so nothing is selected yet.
        selection.click(first, .command, proposed: [first], in: order, openNoteID: third)
        XCTAssertEqual(selection.selectedIDs, [first, third])

        selection.clear()
        selection.click(first, .shift, proposed: [first], in: order, openNoteID: third)
        XCTAssertEqual(selection.selectedIDs, [first, second, third])
        XCTAssertEqual(selection.anchorID, third)

        // Command-clicking the open note itself leaves nothing selected.
        selection.clear()
        selection.click(third, .command, proposed: [third], in: order, openNoteID: third)
        XCTAssertTrue(selection.isEmpty)

        // An existing selection, or a plain click, doesn't add the note.
        selection.click(fourth, .command, proposed: [fourth], in: order)
        selection.click(first, .command, proposed: [first], in: order, openNoteID: third)
        XCTAssertEqual(selection.selectedIDs, [first, fourth])
        selection.clear()
        selection.click(first, .plain, proposed: [first], in: order, openNoteID: third)
        XCTAssertEqual(selection.selectedIDs, [first])
    }

    func testOpenNoteOutsideTheVisibleRowsIsNotAdded() {
        let order = [first, second]
        var selection = NotebookBrowserSelection()
        selection.click(first, .command, proposed: [first], in: order, openNoteID: third)
        XCTAssertEqual(selection.selectedIDs, [first])
    }

    func testRejectedClickLeavesTheSelectionAndAnchorAlone() {
        let order = [first, second, third]
        var selection = NotebookBrowserSelection()
        selection.activate(second)

        XCTAssertFalse(selection.click(first, .command, proposed: [second],
                                       in: order, openNoteID: third))
        XCTAssertTrue(selection.isEmpty)
        XCTAssertEqual(selection.anchorID, second)
    }

    func testPlainActivationLeavesABatchButKeepsASingleRow() {
        var selection = NotebookBrowserSelection()
        selection.selectAll([first, second])
        selection.activate(third)
        XCTAssertEqual(selection.selectedIDs, [third])
        XCTAssertEqual(selection.anchorID, third)

        selection.activate(first)
        XCTAssertEqual(selection.selectedIDs, [third])
        XCTAssertEqual(selection.anchorID, first)
    }

    func testOpeningANoteDropsOnlyAStaleSingleRow() {
        var selection = NotebookBrowserSelection()
        selection.selectOnly(first)
        selection.noteOpened(first)
        XCTAssertEqual(selection.selectedIDs, [first])
        selection.noteOpened(second)
        XCTAssertTrue(selection.isEmpty)

        selection.selectAll([first, second])
        selection.noteOpened(third)
        XCTAssertEqual(selection.selectedIDs, [first, second])
    }

    func testEmptySpaceClearsOtherRowsBeforeClosingTheNote() {
        var selection = NotebookBrowserSelection()
        selection.selectAll([first, second])
        XCTAssertFalse(selection.clickEmptySpace(openNoteID: first))
        XCTAssertTrue(selection.isEmpty)
        XCTAssertTrue(selection.clickEmptySpace(openNoteID: first))

        selection.selectOnly(first)
        XCTAssertTrue(selection.clickEmptySpace(openNoteID: first))
        XCTAssertTrue(selection.isEmpty)

        XCTAssertFalse(selection.clickEmptySpace(openNoteID: nil))
    }

    func testHighlightShowsTheOpenNoteUnlessItIsSelected() {
        var selection = NotebookBrowserSelection()
        XCTAssertEqual(selection.highlight(of: first, openNoteID: first), .open)
        XCTAssertEqual(selection.highlight(of: second, openNoteID: first), .none)

        selection.selectAll([first, second])
        XCTAssertEqual(selection.highlight(of: first, openNoteID: first), .selected)
        XCTAssertEqual(selection.highlight(of: second, openNoteID: first), .selected)
        XCTAssertEqual(selection.highlight(of: third, openNoteID: nil), .none)
    }

    func testAnchorClearsWithTheSelectionOrItsRow() {
        var selection = NotebookBrowserSelection()
        selection.toggle(first)
        selection.prune(to: [second])
        XCTAssertNil(selection.anchorID)

        selection.toggle(second)
        selection.selectAll([first, second])
        XCTAssertNil(selection.anchorID)

        selection.selectOnly(third)
        selection.clear()
        XCTAssertNil(selection.anchorID)
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
