import Foundation
import XCTest

@testable import NativeEditor

@MainActor
final class MarkdownTableCellEditingTests: XCTestCase {
    private let text = "Before 🪐\r\n\r\n| Name | Detail | Third |\r\n"
        + "| --- | --- | --- |\r\n|  café  | a\\|b |   |\r\n"
        + "| short |\r\n\r\nAfter"

    func testSourceSelectionKeepsUTF16AndLiteralInlineMarkdown() throws {
        let target = try cell(text, row: 1, column: 0)
        XCTAssertEqual(MarkdownTableCellEditing.text(in: text, target: target),
                       "café")
        let local = NSRange(location: 1, length: 2)
        let source = MarkdownTableCellEditing.sourceSelection(local, in: target)
        XCTAssertEqual(MarkdownTableCellEditing.localSelection(source, in: target),
                       local)
        XCTAssertEqual((text as NSString).substring(with: source), "af")
        let pipe = try cell(text, row: 1, column: 1)
        XCTAssertEqual(MarkdownTableCellEditing.text(in: text, target: pipe),
                       "a\\|b")
        let end = NSRange(location: NSMaxRange(pipe.contentRange), length: 0)
        XCTAssertEqual(MarkdownTableCellEditing.target(text: text, selection: end),
                       pipe)
    }

    func testCellReplacementPreservesPaddingCRLFAndUntouchedBytes() throws {
        let target = try cell(text, row: 1, column: 0)
        let replacement = "**moon 🪐**"
        let change = try XCTUnwrap(MarkdownTableCellEditing.change(
            text: text, target: target, replacement: replacement,
            selection: NSRange(location: replacement.utf16.count, length: 0)
        ))
        let updated = applying(change, to: text)
        XCTAssertEqual(updated, text.replacingOccurrences(of: "café",
                                                         with: replacement))
        XCTAssertEqual(change.selection.location,
                       target.contentRange.location + replacement.utf16.count)
        XCTAssertEqual(MarkdownSyntax.parse(updated).tables.count, 1)
    }

    func testEmptyCellInsertsWithoutRemovingWhitespace() throws {
        let target = try cell(text, row: 1, column: 2)
        XCTAssertEqual(target.contentRange.length, 0)
        XCTAssertEqual(MarkdownTableCellEditing.target(
            text: text, selection: target.contentRange
        ), target)
        let change = try XCTUnwrap(MarkdownTableCellEditing.change(
            text: text, target: target, replacement: "value",
            selection: NSRange(location: 5, length: 0)
        ))
        XCTAssertEqual(applying(change, to: text),
                       text.replacingOccurrences(of: "|   |", with: "|   value|"))
    }

    func testRaggedCellMaterializesOnlyMissingSeparators() throws {
        let target = try cell(text, row: 2, column: 2)
        let change = try XCTUnwrap(MarkdownTableCellEditing.change(
            text: text, target: target, replacement: "last",
            selection: NSRange(location: 4, length: 0)
        ))
        let updated = applying(change, to: text)
        XCTAssertEqual(updated,
                       text.replacingOccurrences(of: "| short |",
                                                 with: "| short  | | last |"))
        let next = try cell(updated, row: 2, column: 2)
        XCTAssertEqual(MarkdownTableCellEditing.text(in: updated, target: next),
                       "last")
        XCTAssertEqual(change.selection.location, NSMaxRange(next.contentRange))
    }

    func testVisibleCellEditsPreserveExcessCellsAndRejectOverflowTargets() throws {
        for tail in ["|  ||  |  |", "| right | extra 🪐 | a\\|b |"] {
            let source = "Before\r\n\r\n| A | B |\r\n| --- | --- |\r\n"
                + "|  sample " + tail + "\r\n\r\nAfter"
            let target = try cell(source, row: 1, column: 0)
            let change = try XCTUnwrap(MarkdownTableCellEditing.change(
                text: source, target: target, replacement: "updated",
                selection: NSRange(location: 7, length: 0)
            ))
            XCTAssertEqual(applying(change, to: source),
                           source.replacingOccurrences(of: "sample", with: "updated"))
            let second = try cell(source, row: 1, column: 1)
            XCTAssertNotNil(MarkdownTableCellEditing.target(
                text: source, selection: second.contentRange
            ))
            let table = try XCTUnwrap(MarkdownSyntax.parse(source).tables.first)
            XCTAssertNil(MarkdownTableCellEditing.target(
                text: source, table: table, row: 1, column: 2
            ))
            XCTAssertNil(MarkdownTableCellEditing.target(
                text: source, selection: table.rows[0].cells[2]
            ))
        }
    }

    func testPasteEscapesBarePipesAndFlattensEachLineBreak() throws {
        let target = try cell(text, row: 1, column: 0)
        let value = "🪐|a\\|b\\\\|c\r\nd\ne\rf"
        let change = try XCTUnwrap(MarkdownTableCellEditing.change(
            text: text, target: target, replacement: value,
            selection: NSRange(location: value.utf16.count, length: 0)
        ))
        XCTAssertEqual(change.replacement, "🪐\\|a\\|b\\\\\\|c d e f")
        XCTAssertEqual(change.selection.location,
                       target.contentRange.location + change.replacement.utf16.count)
        let updated = applying(change, to: text)
        XCTAssertEqual(MarkdownSyntax.parse(updated).tables[0].rows[0].cells.count,
                       3)
        XCTAssertEqual(MarkdownSyntax.parse(updated).tables[0].rows.count, 2)
    }

    func testSelectionMapsThroughEscapingAndCRLFNormalization() throws {
        let target = try cell(text, row: 1, column: 0)
        let value = "a|b\r\n🪐"
        let selectedEmoji = (value as NSString).range(of: "🪐")
        let change = try XCTUnwrap(MarkdownTableCellEditing.change(
            text: text, target: target, replacement: value,
            selection: selectedEmoji
        ))
        XCTAssertEqual((applying(change, to: text) as NSString)
            .substring(with: change.selection), "🪐")
        XCTAssertEqual(change.selection.length, 2)
    }

    func testRebaseFollowsExternalPrefixAndSameCellEdit() throws {
        let target = try cell(text, row: 1, column: 0)
        let prefixed = "New 🪐\r\n" + text
        let moved = try XCTUnwrap(MarkdownTableCellEditing.rebased(
            target, from: text, to: prefixed
        ))
        XCTAssertEqual(moved.contentRange.location,
                       target.contentRange.location + "New 🪐\r\n".utf16.count)
        let updated = text.replacingOccurrences(of: "café", with: "moon 🪐")
        let changed = try XCTUnwrap(MarkdownTableCellEditing.rebased(
            target, from: text, to: updated
        ))
        XCTAssertEqual(MarkdownTableCellEditing.text(in: updated, target: changed),
                       "moon 🪐")
    }

    func testRebaseClosesOnDeletedRowOrNewCellSeparator() throws {
        let target = try cell(text, row: 1, column: 0)
        let deleted = (text as NSString).replacingCharacters(in: target.rowRange,
                                                           with: "")
        XCTAssertNil(MarkdownTableCellEditing.rebased(target, from: text,
                                                     to: deleted))
        let split = text.replacingOccurrences(of: "café", with: "ca|fé")
        XCTAssertNil(MarkdownTableCellEditing.rebased(target, from: text,
                                                     to: split))
    }

    func testCrossCellSelectionAndStaleTargetsAreRejected() throws {
        let target = try cell(text, row: 1, column: 0)
        let second = try cell(text, row: 1, column: 1)
        XCTAssertNil(MarkdownTableCellEditing.target(
            text: text, selection: NSRange(location: target.contentRange.location,
                length: NSMaxRange(second.contentRange) - target.contentRange.location)
        ))
        XCTAssertNil(MarkdownTableCellEditing.change(
            text: "prefix" + text, target: target, replacement: "value",
            selection: NSRange(location: 0, length: 0)
        ))
        XCTAssertNil(MarkdownTableCellEditing.target(
            text: text, selection: NSRange(location: NSNotFound, length: 0)
        ))
    }

    func testTrailingBackslashCannotConsumeAdjacentSeparator() throws {
        let compact = "a|b\n---|---\nx|y"
        let target = try cell(compact, row: 1, column: 0)
        let change = try XCTUnwrap(MarkdownTableCellEditing.change(
            text: compact, target: target, replacement: "end\\",
            selection: NSRange(location: 4, length: 0)
        ))
        let updated = applying(change, to: compact)
        XCTAssertEqual(updated, "a|b\n---|---\nend\\ |y")
        XCTAssertEqual(MarkdownSyntax.parse(updated).tables[0].rows[0].cells.count,
                       2)
        XCTAssertEqual(change.selection.location,
                       target.contentRange.location + 4)
    }

    func testMissingCellWithoutOuterPipesPreservesLineEnding() throws {
        let ragged = "a|b|c\r\n---|---|---\r\nx\r\n"
        let target = try cell(ragged, row: 1, column: 1)
        let change = try XCTUnwrap(MarkdownTableCellEditing.change(
            text: ragged, target: target, replacement: "new",
            selection: NSRange(location: 3, length: 0)
        ))
        XCTAssertEqual(applying(change, to: ragged),
                       "a|b|c\r\n---|---|---\r\nx | new \r\n")
    }

    func testTypingContinuesAfterTrailingAndLeadingWhitespace() throws {
        var source = text
        var target = try cell(source, row: 1, column: 0)
        for buffer in ["hello ", "hello world", "  hello world "] {
            let change = try XCTUnwrap(MarkdownTableCellEditing.change(
                text: source, target: target, replacement: buffer,
                selection: NSRange(location: buffer.utf16.count, length: 0)
            ))
            source = applying(change, to: source)
            target = try XCTUnwrap(MarkdownTableCellEditing.targetAfter(
                change: change, priorTarget: target, source: source
            ))
            XCTAssertEqual(MarkdownTableCellEditing.text(in: source,
                                                        target: target), buffer)
            XCTAssertEqual(change.selection.location,
                           NSMaxRange(target.contentRange))
        }
        XCTAssertEqual(source, text.replacingOccurrences(of: "café",
                                                        with: "  hello world "))
    }

    func testRetainedRangeCannotIncludeStructuralPipeOrNeighbor() throws {
        let target = try cell(text, row: 1, column: 0)
        XCTAssertNil(MarkdownTableCellEditing.retainingContentRange(
            NSRange(location: target.contentRange.location,
                    length: target.contentRange.length + 4),
            in: target, text: text
        ))
    }

    func testTargetAfterRaggedInsertionRetainsBufferWhitespace() throws {
        let target = try cell(text, row: 2, column: 2)
        let buffer = "  last "
        let change = try XCTUnwrap(MarkdownTableCellEditing.change(
            text: text, target: target, replacement: buffer,
            selection: NSRange(location: buffer.utf16.count, length: 0)
        ))
        let source = applying(change, to: text)
        let next = try XCTUnwrap(MarkdownTableCellEditing.targetAfter(
            change: change, priorTarget: target, source: source
        ))
        XCTAssertEqual(MarkdownTableCellEditing.text(in: source, target: next),
                       buffer)
    }

    func testTargetAfterCompactLastCellRetainsTrailingWhitespace() throws {
        let source = "a|b\n---|---\nx|y"
        let target = try cell(source, row: 1, column: 1)
        let change = try XCTUnwrap(MarkdownTableCellEditing.change(
            text: source, target: target, replacement: "hello ",
            selection: NSRange(location: 6, length: 0)
        ))
        let updated = applying(change, to: source)
        let next = try XCTUnwrap(MarkdownTableCellEditing.targetAfter(
            change: change, priorTarget: target, source: updated
        ))
        XCTAssertEqual(MarkdownTableCellEditing.text(in: updated, target: next),
                       "hello ")
    }

    func testWhitespaceOnlyBufferAndUndoKeepActiveSourceRange() throws {
        var source = text
        var target = try cell(source, row: 1, column: 0)
        for buffer in [" ", "", "  hello "] {
            let change = try XCTUnwrap(MarkdownTableCellEditing.change(
                text: source, target: target, replacement: buffer,
                selection: NSRange(location: buffer.utf16.count, length: 0)
            ))
            source = applying(change, to: source)
            target = try XCTUnwrap(MarkdownTableCellEditing.targetAfter(
                change: change, priorTarget: target, source: source
            ))
            XCTAssertEqual(MarkdownTableCellEditing.text(in: source,
                                                        target: target), buffer)
        }
        let moved = try XCTUnwrap(MarkdownTableCellEditing.rebased(
            target, from: source, to: "prefix\n" + source
        ))
        XCTAssertEqual(MarkdownTableCellEditing.text(in: "prefix\n" + source,
                                                    target: moved), "  hello ")
        let undone = try XCTUnwrap(MarkdownTableCellEditing.rebased(
            target, from: source, to: text
        ))
        XCTAssertEqual(MarkdownTableCellEditing.text(in: text, target: undone),
                       "café")
    }

    func testRebaseRetainsActiveCellWhenOtherCellInSameRowChanges() throws {
        let target = try cell(text, row: 1, column: 1)
        let earlier = text.replacingOccurrences(of: "café", with: "long 🪐 name")
        let moved = try XCTUnwrap(MarkdownTableCellEditing.rebased(
            target, from: text, to: earlier
        ))
        XCTAssertEqual(MarkdownTableCellEditing.text(in: earlier, target: moved),
                       "a\\|b")
        let later = text.replacingOccurrences(of: "|   |", with: "| moon |")
        let stable = try XCTUnwrap(MarkdownTableCellEditing.rebased(
            target, from: text, to: later
        ))
        XCTAssertEqual(stable.contentRange, target.contentRange)
        XCTAssertEqual(MarkdownTableCellEditing.text(in: later, target: stable),
                       "a\\|b")
    }

    func testUndoRebaseSurvivesDiffAbsorbingUnchangedCellPadding() throws {
        let original = "Intro\n\n| Name | Place |\n| --- | --- |\n"
            + "| Moon | Harbor |\n| Star | Meadow |\n\nClosing"
        for buffer in ["Moon 🪐", "  Moon 🪐", "Moon 🪐 ", "Moon\\|🪐",
                       "Moon 🪐 |"] {
            let prior = try cell(original, row: 1, column: 0)
            let change = try XCTUnwrap(MarkdownTableCellEditing.change(
                text: original, target: prior, replacement: buffer,
                selection: NSRange(location: buffer.utf16.count, length: 0)
            ))
            let updated = applying(change, to: original)
            let active = try XCTUnwrap(MarkdownTableCellEditing.targetAfter(
                change: change, priorTarget: prior, source: updated
            ))
            let undone = try XCTUnwrap(MarkdownTableCellEditing.rebased(
                active, from: updated, to: original
            ), "buffer=\(buffer.debugDescription)")
            XCTAssertEqual(MarkdownTableCellEditing.text(in: original,
                                                        target: undone), "Moon")
            XCTAssertEqual(undone.row, prior.row)
            XCTAssertEqual(undone.column, prior.column)
            let redone = try XCTUnwrap(MarkdownTableCellEditing.rebased(
                undone, from: original, to: updated
            ), "redo buffer=\(buffer.debugDescription)")
            XCTAssertEqual(redone.row, prior.row)
            XCTAssertEqual(redone.column, prior.column)
        }
    }

    func testRebaseRefreshesCanonicallyEquivalentLiteralUnicode() throws {
        let composed = "| Name | Place |\n| --- | --- |\n| Café | Harbor |"
        let decomposed = composed.replacingOccurrences(of: "Café",
                                                       with: "Cafe\u{0301}")
        let prior = try cell(composed, row: 1, column: 0)
        XCTAssertEqual(prior.contentRange.length, 4)
        let target = try XCTUnwrap(MarkdownTableCellEditing.rebased(
            prior, from: composed, to: decomposed
        ))
        XCTAssertEqual(target.contentRange.length, 5)
        XCTAssertTrue(MarkdownTableCellEditing.text(in: decomposed,
            target: target).utf8.elementsEqual("Cafe\u{0301}".utf8))
        XCTAssertEqual(target.tableRange.length, prior.tableRange.length + 1)
    }

    private func cell(_ text: String, row: Int, column: Int) throws
        -> MarkdownTableCellEditing.Target {
        let table = try XCTUnwrap(MarkdownSyntax.parse(text).tables.first)
        return try XCTUnwrap(MarkdownTableCellEditing.target(
            text: text, table: table, row: row, column: column
        ))
    }

    private func applying(_ change: MarkdownEditingChange, to text: String)
        -> String {
        (text as NSString).replacingCharacters(in: change.range,
                                              with: change.replacement)
    }
}
