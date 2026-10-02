import Foundation
import XCTest

@testable import NativeEditor

@MainActor
final class MarkdownTableEditingTests: XCTestCase {
    private let source = "Before\n\n| Name | Planet |\n"
        + "| :--- | ---: |\n"
        + "| café | 🪐 |\n"
        + "| a\\|b | Earth |\n\nAfter"

    func testCurrentAlignmentFollowsSelectedTableCell() {
        let parsed = MarkdownSyntax.parse(source)
        let left = (source as NSString).range(of: "café")
        let right = (source as NSString).range(of: "🪐")
        XCTAssertEqual(MarkdownTableEditing.currentAlignment(
            text: source, selection: left, syntax: parsed
        ), .left)
        XCTAssertEqual(MarkdownTableEditing.currentAlignment(
            text: source, selection: right, syntax: parsed
        ), .right)
        XCTAssertNil(MarkdownTableEditing.currentAlignment(
            text: source,
            selection: (source as NSString).range(of: "After"),
            syntax: parsed
        ))
    }

    func testInsertTableKeepsSurroundingParagraphsAndSelectsHeader() throws {
        let text = "Before\nAfter"
        let change = try XCTUnwrap(MarkdownTableEditing.change(
            for: .insertTable, text: text,
            selection: NSRange(location: 2, length: 0)
        ))
        let result = apply(change, to: text)
        XCTAssertEqual(result, "Before\n\n| Column 1 | Column 2 |\n"
            + "| --- | --- |\n|  |  |\n\nAfter")
        XCTAssertEqual((result as NSString).substring(with: change.selection),
                       "Column 1")
        XCTAssertEqual(MarkdownSyntax.parse(result).tables.count, 1)
    }

    func testInsertTablePreservesCRLFAndRejectsFencedCode() throws {
        let text = "Before\r\nAfter"
        let change = try XCTUnwrap(MarkdownTableEditing.change(
            for: .insertTable, text: text,
            selection: NSRange(location: 2, length: 0)
        ))
        XCTAssertTrue(apply(change, to: text).contains("| --- | --- |\r\n"))
        let fenced = "```\ncontent\n```"
        let caret = (fenced as NSString).range(of: "content").location
        XCTAssertNil(MarkdownTableEditing.change(
            for: .insertTable, text: fenced,
            selection: NSRange(location: caret, length: 0)
        ))
    }

    func testRowsPreserveOtherSourceAndHeaderCannotBeDeleted() throws {
        let cell = (source as NSString).range(of: "café")
        let above = try XCTUnwrap(MarkdownTableEditing.change(
            for: .tableRowAbove, text: source, selection: cell
        ))
        XCTAssertEqual(apply(above, to: source),
                       source.replacingOccurrences(of: "| café | 🪐 |\n",
                           with: "|  |  |\n| café | 🪐 |\n"))
        let below = try XCTUnwrap(MarkdownTableEditing.change(
            for: .tableRowBelow, text: source, selection: cell
        ))
        XCTAssertEqual(MarkdownSyntax.parse(apply(below, to: source))
            .tables.first?.rows.count, 3)
        let insertedTable = try XCTUnwrap(
            MarkdownSyntax.parse(apply(below, to: source)).tables.first
        )
        XCTAssertEqual(below.selection.location,
                       insertedTable.rows[1].cells[0].location)
        let deleted = try XCTUnwrap(MarkdownTableEditing.change(
            for: .tableDeleteRow, text: source, selection: cell
        ))
        XCTAssertFalse(apply(deleted, to: source).contains("café"))
        XCTAssertTrue(apply(deleted, to: source).contains("a\\|b"))
        let header = (source as NSString).range(of: "Name")
        XCTAssertNil(MarkdownTableEditing.change(
            for: .tableDeleteRow, text: source, selection: header
        ))
        XCTAssertNil(MarkdownTableEditing.change(
            for: .tableRowAbove, text: source, selection: header
        ))
    }

    func testColumnsPreserveUnicodeEscapesAndAlignments() throws {
        let cell = (source as NSString).range(of: "🪐")
        let added = try XCTUnwrap(MarkdownTableEditing.change(
            for: .tableColumnBefore, text: source, selection: cell
        ))
        let inserted = apply(added, to: source)
        let table = try XCTUnwrap(MarkdownSyntax.parse(inserted).tables.first)
        XCTAssertEqual(table.header.cells.count, 3)
        XCTAssertEqual(table.alignments, [.left, .left, .right])
        XCTAssertTrue(inserted.contains("café"))
        XCTAssertTrue(inserted.contains("🪐"))
        XCTAssertTrue(inserted.contains("a\\|b"))
        XCTAssertTrue(inserted.hasPrefix("Before\n\n"))
        XCTAssertTrue(inserted.hasSuffix("\n\nAfter"))
        XCTAssertEqual(added.range, MarkdownSyntax.parse(source).tables[0].range)

        let removed = try XCTUnwrap(MarkdownTableEditing.change(
            for: .tableDeleteColumn, text: source, selection: cell
        ))
        let remaining = apply(removed, to: source)
        XCTAssertEqual(MarkdownSyntax.parse(remaining).tables[0].header.cells.count, 1)
        XCTAssertTrue(remaining.contains("café"))
        XCTAssertTrue(remaining.contains("a\\|b"))
        XCTAssertFalse(remaining.contains("🪐"))
    }

    func testOptionalPipesMissingCellsAndExtraCellsPreserved() throws {
        let text = "One | Two\n:--- | ---:\nonly one\n"
        let cell = (text as NSString).range(of: "only one")
        let change = try XCTUnwrap(MarkdownTableEditing.change(
            for: .tableColumnAfter, text: text, selection: cell
        ))
        let result = apply(change, to: text)
        let table = try XCTUnwrap(MarkdownSyntax.parse(result).tables.first)
        XCTAssertEqual(table.header.cells.count, 3)
        XCTAssertEqual(table.rows[0].cells.count, 3)
        XCTAssertTrue(result.contains("only one"))

        let extra = "| A | B |\n| --- | --- |\n| x | y | z |\n"
        let x = (extra as NSString).range(of: "x")
        let inserted = try XCTUnwrap(MarkdownTableEditing.change(
            for: .tableColumnAfter, text: extra, selection: x
        ))
        let expanded = apply(inserted, to: extra)
        let expandedTable = try XCTUnwrap(
            MarkdownSyntax.parse(expanded).tables.first
        )
        XCTAssertEqual(expandedTable.header.cells.count, 3)
        XCTAssertEqual(expandedTable.rows[0].cells.count, 4)
        XCTAssertTrue(expanded.contains("| x |  | y | z |\n"))
        XCTAssertTrue(MarkdownTableEditing.availableCommands(
            text: extra, selection: x
        ).contains(.tableColumnAfter))
    }

    func testOverflowColumnChangesPreserveEveryRemainingCellByte() throws {
        let prefix = "Before 🪐\r\n\r\n"
        let suffix = "\r\nAfter cafe\u{301}"
        let text = prefix + "| A | B |\r\n| :--- | ---: |\r\n"
            + "| café | visible | cafe\u{301} | a\\|b | 🪐 |\r\n"
            + "| short |\r\n" + suffix
        let visible = (text as NSString).range(of: "visible")
        let existing = ["café", "visible", "cafe\u{301}", "a\\|b", "🪐"]
        let cases: [(MarkdownEditingCommand, [String])] = [
            (.tableColumnBefore, [existing[0], ""] + Array(existing.dropFirst())),
            (.tableColumnAfter, Array(existing.prefix(2)) + [""]
                + Array(existing.dropFirst(2))),
            (.tableDeleteColumn, [existing[0]] + Array(existing.dropFirst(2))),
        ]
        for (command, expected) in cases {
            let change = try XCTUnwrap(MarkdownTableEditing.change(
                for: command, text: text, selection: visible
            ))
            let result = apply(change, to: text)
            let table = try XCTUnwrap(MarkdownSyntax.parse(result).tables.first)
            let actual = table.rows[0].cells.map {
                (result as NSString).substring(with: $0)
            }
            XCTAssertEqual(actual.map { Array($0.utf8) },
                           expected.map { Array($0.utf8) }, "\(command)")
            let columns = command == .tableDeleteColumn ? 1 : 3
            XCTAssertEqual(table.header.cells.count, columns)
            XCTAssertEqual(table.rows[1].cells.count, columns)
            let expectedAlignments: [MarkdownTableAlignment]
            switch command {
            case .tableDeleteColumn: expectedAlignments = [.left]
            case .tableColumnAfter: expectedAlignments = [.left, .right, .left]
            default: expectedAlignments = [.left, .left, .right]
            }
            XCTAssertEqual(table.alignments, expectedAlignments)
            XCTAssertTrue(result.hasPrefix(prefix))
            XCTAssertTrue(result.hasSuffix(suffix))
            XCTAssertFalse(result.replacingOccurrences(of: "\r\n", with: "")
                .contains("\n"))
        }
    }

    func testOverflowCellsRejectSelectionsAndCarets() throws {
        let text = "| A | B |\n| --- | --- |\n| x | y | extra |  |\n"
        let table = try XCTUnwrap(MarkdownSyntax.parse(text).tables.first)
        let overflow = table.rows[0].cells[2]
        let emptyOverflow = table.rows[0].cells[3]
        let selections = [
            overflow,
            NSRange(location: overflow.location, length: 0),
            NSRange(location: NSMaxRange(overflow), length: 0),
            NSRange(location: emptyOverflow.location, length: 0),
        ]
        for selection in selections {
            XCTAssertTrue(MarkdownTableEditing.availableCommands(
                text: text, selection: selection
            ).isEmpty)
            XCTAssertNil(MarkdownTableEditing.currentAlignment(
                text: text, selection: selection
            ))
            for command: MarkdownEditingCommand in [
                .tableColumnAfter, .tableDeleteColumn, .tableAlignRight,
                .tableNextCell, .tablePreviousCell, .tableRowBelow,
            ] {
                XCTAssertNil(MarkdownTableEditing.change(
                    for: command, text: text, selection: selection
                ))
            }
        }
    }

    func testVisibleOverflowRowSupportsNavigationAlignmentAndRowChanges() throws {
        let text = "| Column 1 | Column 2 |\n| --- | --- |\n"
            + "|  TEs T |  ||  |  |\n| later | row |\n"
        let table = try XCTUnwrap(MarkdownSyntax.parse(text).tables.first)
        let first = table.rows[0].cells[0]
        let second = table.rows[0].cells[1]
        let next = try XCTUnwrap(MarkdownTableEditing.change(
            for: .tableNextCell, text: text, selection: first
        ))
        XCTAssertEqual(next.selection, second)
        XCTAssertEqual(apply(next, to: text), text)
        let nextRow = try XCTUnwrap(MarkdownTableEditing.change(
            for: .tableNextCell, text: text, selection: second
        ))
        XCTAssertEqual(nextRow.selection, table.rows[1].cells[0])
        XCTAssertEqual(apply(nextRow, to: text), text)
        let previous = try XCTUnwrap(MarkdownTableEditing.change(
            for: .tablePreviousCell, text: text, selection: nextRow.selection
        ))
        XCTAssertEqual(previous.selection, second)

        let aligned = try XCTUnwrap(MarkdownTableEditing.change(
            for: .tableAlignCenter, text: text, selection: first
        ))
        let alignedText = apply(aligned, to: text)
        XCTAssertEqual(aligned.range, table.delimiterRange)
        XCTAssertTrue(alignedText.hasSuffix(
            "|  TEs T |  ||  |  |\n| later | row |\n"
        ))
        XCTAssertEqual(MarkdownTableEditing.currentAlignment(
            text: alignedText, selection: aligned.selection
        ), .center)

        let added = try XCTUnwrap(MarkdownTableEditing.change(
            for: .tableRowBelow, text: text, selection: first
        ))
        XCTAssertTrue(apply(added, to: text).contains(
            "|  TEs T |  ||  |  |\n|  |  |\n| later | row |\n"
        ))
        let deleted = try XCTUnwrap(MarkdownTableEditing.change(
            for: .tableDeleteRow, text: text,
            selection: table.rows[1].cells[0]
        ))
        XCTAssertEqual(apply(deleted, to: text),
                       (text as NSString).substring(to: table.rows[1].range.location))
    }

    func testColumnChangeKeepsCRLFAndEscapedCellText() throws {
        let text = "| A | B |\r\n| :--- | ---: |\r\n"
            + "| café\\|noir | 🪐 |\r\n"
        let cell = (text as NSString).range(of: "🪐")
        let changed = try XCTUnwrap(MarkdownTableEditing.change(
            for: .tableColumnAfter, text: text, selection: cell
        ))
        let result = apply(changed, to: text)
        XCTAssertTrue(result.contains("café\\|noir"))
        XCTAssertEqual(result.components(separatedBy: "\r\n").count, 4)
        XCTAssertEqual(MarkdownSyntax.parse(result).tables[0].header.cells.count,
                       3)
    }

    func testAlignmentOnlyChangesDelimiterAndKeepsBody() throws {
        let cell = (source as NSString).range(of: "café")
        let change = try XCTUnwrap(MarkdownTableEditing.change(
            for: .tableAlignCenter, text: source, selection: cell
        ))
        let result = apply(change, to: source)
        XCTAssertEqual(MarkdownSyntax.parse(result).tables[0].alignments,
                       [.center, .right])
        XCTAssertEqual(change.range,
                       MarkdownSyntax.parse(source).tables[0].delimiterRange)
        XCTAssertTrue(result.contains("| café | 🪐 |\n"))
        XCTAssertEqual(change.selection.location,
                       cell.location + change.replacement.utf16.count
                           - change.range.length)
        XCTAssertEqual(change.selection.length, cell.length)
    }

    func testNavigationSkipsDelimiterAndAddsRowAtEnd() throws {
        let header = (source as NSString).range(of: "Planet")
        let next = try XCTUnwrap(MarkdownTableEditing.change(
            for: .tableNextCell, text: source, selection: header
        ))
        XCTAssertEqual(next.replacement, "")
        XCTAssertEqual(next.selection.location,
                       (source as NSString).range(of: "café").location)
        XCTAssertEqual(next.selection.length, "café".utf16.count)
        let previous = try XCTUnwrap(MarkdownTableEditing.change(
            for: .tablePreviousCell, text: source, selection: next.selection
        ))
        XCTAssertEqual(previous.selection.location, header.location)
        XCTAssertEqual(previous.selection.length, "Planet".utf16.count)

        let last = (source as NSString).range(of: "Earth")
        let append = try XCTUnwrap(MarkdownTableEditing.change(
            for: .tableNextCell, text: source, selection: last
        ))
        let result = apply(append, to: source)
        XCTAssertEqual(MarkdownSyntax.parse(result).tables[0].rows.count, 3)
        XCTAssertTrue(result.contains("| a\\|b | Earth |\n|  |  |\n"))

        let first = (source as NSString).range(of: "Name")
        let exit = try XCTUnwrap(MarkdownTableEditing.change(
            for: .tablePreviousCell, text: source, selection: first
        ))
        XCTAssertEqual(exit.replacement, "")
        XCTAssertLessThan(exit.selection.location,
                          MarkdownSyntax.parse(source).tables[0].range.location)
        XCTAssertFalse(MarkdownTableEditing.availableCommands(
            text: source, selection: exit.selection
        ).contains(.tablePreviousCell))
    }

    func testSelectionsAcrossCellsOrOutsideTableAreRejected() {
        let first = (source as NSString).range(of: "café")
        let second = (source as NSString).range(of: "🪐")
        let across = NSRange(location: first.location,
                             length: NSMaxRange(second) - first.location)
        XCTAssertNil(MarkdownTableEditing.change(
            for: .tableDeleteColumn, text: source, selection: across
        ))
        XCTAssertTrue(MarkdownTableEditing.availableCommands(
            text: source, selection: across
        ).isEmpty)
        let prose = (source as NSString).range(of: "Before")
        XCTAssertNil(MarkdownTableEditing.change(
            for: .tableDeleteRow, text: source, selection: prose
        ))
    }

    func testSingleColumnCannotBeDeleted() {
        let text = "| Name |\n| --- |\n| Value |\n"
        let value = (text as NSString).range(of: "Value")
        XCTAssertNil(MarkdownTableEditing.change(
            for: .tableDeleteColumn, text: text, selection: value
        ))
        XCTAssertFalse(MarkdownTableEditing.availableCommands(
            text: text, selection: value
        ).contains(.tableDeleteColumn))
    }

    func testNavigationMaterializesMissingBodyCell() throws {
        let text = "| A | B |\n| --- | --- |\nshort\n| later | row |\n"
        let later = (text as NSString).range(of: "later")
        let previous = try XCTUnwrap(MarkdownTableEditing.change(
            for: .tablePreviousCell, text: text, selection: later
        ))
        let result = apply(previous, to: text)
        let table = try XCTUnwrap(MarkdownSyntax.parse(result).tables.first)
        XCTAssertEqual(table.rows[0].cells.count, 2)
        XCTAssertEqual(previous.selection.location,
                       table.rows[0].cells[1].location)
        let next = try XCTUnwrap(MarkdownTableEditing.change(
            for: .tableNextCell, text: result,
            selection: previous.selection
        ))
        XCTAssertEqual(next.selection.location,
                       (result as NSString).range(of: "later").location)
    }

    func testLastCellAtTableEOFWithoutNewlineIsEditable() throws {
        let text = "| A | B |\n| --- | --- |\n| one | two |"
        let caret = NSRange(location: (text as NSString).length, length: 0)
        let change = try XCTUnwrap(MarkdownTableEditing.change(
            for: .tableNextCell, text: text, selection: caret
        ))
        XCTAssertEqual(MarkdownSyntax.parse(apply(change, to: text))
            .tables.first?.rows.count, 2)
        XCTAssertTrue(MarkdownTableEditing.availableCommands(
            text: text, selection: caret
        ).contains(.tableNextCell))
    }

    func testPreviousCellUsesCRLFBoundary() throws {
        let text = "Before\r\n\r\n| A | B |\r\n| --- | --- |\r\n"
        let first = (text as NSString).range(of: "A")
        let previous = try XCTUnwrap(MarkdownTableEditing.change(
            for: .tablePreviousCell, text: text, selection: first
        ))
        let tableStart = MarkdownSyntax.parse(text).tables[0].range.location
        XCTAssertEqual(previous.selection.location, tableStart - 2)
        XCTAssertEqual((text as NSString).character(
            at: previous.selection.location), 13)
    }

    func testTabThroughMultipleMissingCells() throws {
        let text = "| A | B | C |\n| --- | --- | --- |\nshort\n"
        let first = (text as NSString).range(of: "short")
        let second = try XCTUnwrap(MarkdownTableEditing.change(
            for: .tableNextCell, text: text, selection: first
        ))
        let twoCells = apply(second, to: text)
        XCTAssertEqual(MarkdownSyntax.parse(twoCells).tables[0]
            .rows[0].cells.count, 2)
        let third = try XCTUnwrap(MarkdownTableEditing.change(
            for: .tableNextCell, text: twoCells,
            selection: second.selection
        ))
        let threeCells = apply(third, to: twoCells)
        XCTAssertEqual(MarkdownSyntax.parse(threeCells).tables[0]
            .rows[0].cells.count, 3)
        let append = try XCTUnwrap(MarkdownTableEditing.change(
            for: .tableNextCell, text: threeCells,
            selection: third.selection
        ))
        XCTAssertEqual(MarkdownSyntax.parse(apply(append, to: threeCells))
            .tables[0].rows.count, 2)
    }

    func testAlignmentPreservesTrailingOnlyPipeStyle() throws {
        let text = "A | B\n--- | --- |\none | two\n"
        let first = (text as NSString).range(of: "one")
        let change = try XCTUnwrap(MarkdownTableEditing.change(
            for: .tableAlignRight, text: text, selection: first
        ))
        let result = apply(change, to: text)
        XCTAssertTrue(result.contains("---: | --- |\n"))
        XCTAssertEqual(MarkdownSyntax.parse(result).tables[0].alignments,
                       [.right, .left])
    }

    func testInsertionRejectsSelectionCrossingIntoTable() {
        let start = (source as NSString).range(of: "Before").location
        let end = (source as NSString).range(of: "Name")
        let selection = NSRange(location: start,
                                length: NSMaxRange(end) - start)
        XCTAssertNil(MarkdownTableEditing.change(
            for: .insertTable, text: source, selection: selection
        ))
        XCTAssertFalse(MarkdownTableEditing.availableCommands(
            text: source, selection: selection
        ).contains(.insertTable))
    }

    private func apply(_ change: MarkdownEditingChange,
                       to text: String) -> String {
        (text as NSString).replacingCharacters(in: change.range,
                                               with: change.replacement)
    }
}
