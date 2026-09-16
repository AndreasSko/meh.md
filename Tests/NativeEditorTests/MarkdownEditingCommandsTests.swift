import Foundation
import XCTest

@testable import NativeEditor

@MainActor
final class MarkdownEditingCommandsTests: XCTestCase {
    func testCommandCasesAreStable() {
        XCTAssertEqual(
            MarkdownEditingCommand.allCases,
            [
                .continueLine, .indent, .outdent, .bold, .italic,
                .strikethrough, .highlight, .heading, .link,
                .inlineCode, .codeBlock,
            ]
        )
    }

    func testReturnContinuesIndentBulletsQuotesAndOrderedNumbers() throws {
        try assertChange(
            .continueLine,
            text: "  + Europa",
            selection: caret(atEndOf: "  + Europa"),
            equals: "  + Europa\n  + ",
            selected: NSRange(location: 15, length: 0)
        )
        try assertChange(
            .continueLine,
            text: "  * > > Europa",
            selection: caret(atEndOf: "  * > > Europa"),
            equals: "  * > > Europa\n  * > > ",
            selected: NSRange(location: 23, length: 0)
        )
        let huge = "999999999999999999999999999999999999. Europa"
        try assertChange(
            .continueLine,
            text: huge,
            selection: caret(atEndOf: huge),
            equals: huge + "\n1000000000000000000000000000000000000. ",
            selected: NSRange(location: 84, length: 0)
        )
    }

    func testReturnExitsOnlyTheInnermostEmptyContainer() throws {
        try assertChange(
            .continueLine,
            text: "* Moon\n* ",
            selection: caret(atEndOf: "* Moon\n* "),
            equals: "* Moon\n",
            selected: NSRange(location: 7, length: 0)
        )
        try assertChange(
            .continueLine,
            text: "> > ",
            selection: caret(atEndOf: "> > "),
            equals: "> ",
            selected: NSRange(location: 2, length: 0)
        )
        try assertChange(
            .continueLine,
            text: "* > ",
            selection: caret(atEndOf: "* > "),
            equals: "* ",
            selected: NSRange(location: 2, length: 0)
        )
        try assertChange(
            .continueLine,
            text: "  - ",
            selection: caret(atEndOf: "  - "),
            equals: "- ",
            selected: NSRange(location: 2, length: 0)
        )
    }

    func testRepeatedReturnOutdentsThenExitsNestedLists() throws {
        try assertChange(
            .continueLine,
            text: "    * ",
            selection: caret(atEndOf: "    * "),
            equals: "  * ",
            selected: NSRange(location: 4, length: 0)
        )
        try assertChange(
            .continueLine,
            text: "  4. ",
            selection: caret(atEndOf: "  4. "),
            equals: "4. ",
            selected: NSRange(location: 3, length: 0)
        )
        try assertChange(
            .continueLine,
            text: "\t\t* ",
            selection: caret(atEndOf: "\t\t* "),
            equals: "\t* ",
            selected: NSRange(location: 3, length: 0)
        )
        try assertChange(
            .continueLine,
            text: "      - ",
            selection: caret(atEndOf: "      - "),
            equals: "    - ",
            selected: NSRange(location: 6, length: 0)
        )
        try assertChange(
            .continueLine,
            text: "* ",
            selection: caret(atEndOf: "* "),
            equals: "",
            selected: NSRange(location: 0, length: 0)
        )
    }

    func testIndentingEmptyQuotedListContinuationRemovesQuote() throws {
        try assertChange(
            .indent,
            text: "* > ",
            selection: caret(atEndOf: "* > "),
            equals: "  * ",
            selected: NSRange(location: 4, length: 0)
        )
        try assertChange(
            .indent,
            text: "  2. > > ",
            selection: caret(atEndOf: "  2. > > "),
            equals: "    2. ",
            selected: NSRange(location: 7, length: 0)
        )
        try assertChange(
            .indent,
            text: "\t3. > ",
            selection: caret(atEndOf: "\t3. > "),
            equals: "  \t3. ",
            selected: NSRange(location: 6, length: 0)
        )
        try assertChange(
            .indent,
            text: "* > quoted",
            selection: caret(atEndOf: "* > quoted"),
            equals: "  * > quoted",
            selected: NSRange(location: 12, length: 0)
        )
    }

    func testReturnDoesNotInterpretMarkersInCode() throws {
        let fenced = "```\n* literal"
        try assertChange(
            .continueLine,
            text: fenced,
            selection: caret(atEndOf: fenced),
            equals: fenced + "\n",
            selected: NSRange(location: 14, length: 0)
        )
        let inline = "`* literal`"
        try assertChange(
            .continueLine,
            text: inline,
            selection: NSRange(location: 5, length: 0),
            equals: "`* li\nteral`",
            selected: NSRange(location: 6, length: 0)
        )
        let closed = "* `literal`"
        try assertChange(
            .continueLine,
            text: closed,
            selection: caret(atEndOf: closed),
            equals: closed + "\n* ",
            selected: NSRange(location: 14, length: 0)
        )
        XCTAssertNil(
            MarkdownEditingRules.change(
                for: .bold,
                text: "`unfinished",
                selection: caret(atEndOf: "`unfinished")
            )
        )
        let closedFence = "```\nliteral\n```"
        XCTAssertNotNil(
            MarkdownEditingRules.change(
                for: .bold,
                text: closedFence,
                selection: caret(atEndOf: closedFence)
            )
        )
        XCTAssertNil(
            MarkdownEditingRules.change(
                for: .bold,
                text: "```\nliteral",
                selection: caret(atEndOf: "```\nliteral")
            )
        )
    }

    func testReturnInsideContainerPrefixDoesNotDuplicateItsRemainder() throws {
        try assertChange(
            .continueLine,
            text: "* > Europa",
            selection: NSRange(location: 1, length: 0),
            equals: "*\n > Europa",
            selected: NSRange(location: 2, length: 0)
        )
    }

    func testIndentUsesWholeLinesAndExcludesTerminalBoundary() throws {
        try assertChange(
            .indent,
            text: "*\nnext",
            selection: NSRange(location: 0, length: 2),
            equals: "  *\nnext",
            selected: NSRange(location: 2, length: 2)
        )
        try assertChange(
            .indent,
            text: "one\ntwo\nthree",
            selection: NSRange(location: 1, length: 6),
            equals: "  one\n  two\nthree",
            selected: NSRange(location: 3, length: 8)
        )
    }

    func testOutdentRemovesAtMostOneTwoSpaceOrTabLevel() throws {
        try assertChange(
            .outdent,
            text: "    one\n\ttwo\n three",
            selection: NSRange(location: 0, length: 19),
            equals: "  one\ntwo\nthree",
            selected: NSRange(location: 0, length: 15)
        )
    }

    func testIndentAndOutdentDoNotInterpretCodeLines() {
        let text = "```\n* literal\n```"
        let literal = (text as NSString).range(of: "* literal")
        XCTAssertNil(
            MarkdownEditingRules.change(
                for: .indent,
                text: text,
                selection: literal
            )
        )
        XCTAssertNil(
            MarkdownEditingRules.change(
                for: .outdent,
                text: text,
                selection: literal
            )
        )
    }

    func testInlineCommandsWrapAndUnwrapSelectedUnicode() throws {
        let text = "Orbit 👩🏽‍💻 map"
        let source = text as NSString
        let emoji = source.range(of: "👩🏽‍💻")
        let wrapped = try XCTUnwrap(
            MarkdownEditingRules.change(
                for: .bold,
                text: text,
                selection: emoji
            )
        )
        let result = applying(wrapped, to: text)
        XCTAssertEqual(result, "Orbit **👩🏽‍💻** map")
        XCTAssertEqual(
            (result as NSString).substring(with: wrapped.selection),
            "👩🏽‍💻"
        )

        try assertChange(
            .bold,
            text: result,
            selection: wrapped.selection,
            equals: text,
            selected: emoji
        )
        try assertChange(
            .italic,
            text: "Moon",
            selection: NSRange(location: 2, length: 0),
            equals: "Mo**on",
            selected: NSRange(location: 3, length: 0)
        )
    }

    func testMultilineInlineCommandsTransformEachNonemptyLine() throws {
        let text = "one\n\n二"
        try assertChange(
            .highlight,
            text: text,
            selection: NSRange(location: 0, length: text.utf16.count),
            equals: "==one==\n\n==二==",
            selected: NSRange(location: 0, length: 14)
        )
        let mixed = "~~done~~\nnext"
        try assertChange(
            .strikethrough,
            text: mixed,
            selection: NSRange(location: 0, length: mixed.utf16.count),
            equals: "done\n~~next~~",
            selected: NSRange(location: 0, length: 13)
        )
    }

    func testInlineFormattingIsUnavailableInsideCodeButCodeCanToggle() throws {
        let text = "`literal`"
        let literal = (text as NSString).range(of: "literal")
        XCTAssertNil(
            MarkdownEditingRules.change(
                for: .bold,
                text: text,
                selection: literal
            )
        )
        try assertChange(
            .inlineCode,
            text: text,
            selection: literal,
            equals: "literal",
            selected: NSRange(location: 0, length: 7)
        )

        let fenced = "```\n**literal**\n```"
        XCTAssertNil(
            MarkdownEditingRules.change(
                for: .bold,
                text: fenced,
                selection: (fenced as NSString).range(of: "literal")
            )
        )
        let closed = "`literal`"
        let after = caret(atEndOf: closed)
        XCTAssertNotNil(
            MarkdownEditingRules.change(
                for: .bold,
                text: closed,
                selection: after
            )
        )
    }

    func testCombinedEmphasisTogglesOnlyTheRequestedStyle() throws {
        let combined = "***orbit***"
        let orbit = (combined as NSString).range(of: "orbit")
        try assertChange(
            .bold,
            text: combined,
            selection: orbit,
            equals: "*orbit*",
            selected: NSRange(location: 1, length: 5)
        )
        try assertChange(
            .italic,
            text: combined,
            selection: orbit,
            equals: "**orbit**",
            selected: NSRange(location: 2, length: 5)
        )
        try assertChange(
            .bold,
            text: "*orbit*",
            selection: NSRange(location: 1, length: 5),
            equals: combined,
            selected: orbit
        )
        try assertChange(
            .italic,
            text: "**orbit**",
            selection: NSRange(location: 2, length: 5),
            equals: combined,
            selected: orbit
        )
    }

    func testInlineCodeChoosesSafeDelimiterAndCommonMarkPadding() throws {
        let withBacktick = "a`b"
        try assertChange(
            .inlineCode,
            text: withBacktick,
            selection: NSRange(location: 0, length: withBacktick.utf16.count),
            equals: "``a`b``",
            selected: NSRange(location: 2, length: 3)
        )

        let edged = "`edge"
        let wrapped = try XCTUnwrap(
            MarkdownEditingRules.change(
                for: .inlineCode,
                text: edged,
                selection: NSRange(location: 0, length: edged.utf16.count)
            )
        )
        let wrappedText = applying(wrapped, to: edged)
        XCTAssertEqual(wrappedText, "`` `edge ``")
        XCTAssertEqual(
            (wrappedText as NSString).substring(with: wrapped.selection),
            edged
        )

        try assertChange(
            .inlineCode,
            text: wrappedText,
            selection: wrapped.selection,
            equals: edged,
            selected: NSRange(location: 0, length: edged.utf16.count)
        )

        let spaced = " code "
        try assertChange(
            .inlineCode,
            text: spaced,
            selection: NSRange(location: 0, length: spaced.utf16.count),
            equals: "`  code  `",
            selected: NSRange(location: 2, length: 6)
        )
    }

    func testHeadingTogglesH2AndNormalizesOtherATXLevels() throws {
        let text = "one\n# two\n\n* > three"
        let change = try XCTUnwrap(
            MarkdownEditingRules.change(
                for: .heading,
                text: text,
                selection: NSRange(location: 0, length: text.utf16.count)
            )
        )
        let result = applying(change, to: text)
        XCTAssertEqual(result, "## one\n## two\n\n* > ## three")

        try assertChange(
            .heading,
            text: result,
            selection: NSRange(location: 0, length: result.utf16.count),
            equals: text.replacingOccurrences(of: "# two", with: "two"),
            selected: NSRange(location: 0, length: 18)
        )
        try assertChange(
            .heading,
            text: "",
            selection: NSRange(location: 0, length: 0),
            equals: "## ",
            selected: NSRange(location: 3, length: 0)
        )
    }

    func testLinkCreatesDestinationSelectionAndRevealsExistingURL() throws {
        try assertChange(
            .link,
            text: "Moon map",
            selection: NSRange(location: 0, length: 4),
            equals: "[Moon](https://) map",
            selected: NSRange(location: 7, length: 8)
        )

        let existing = "See [Moon](https://example.test/orbit) soon"
        let label = (existing as NSString).range(of: "Moon")
        let change = try XCTUnwrap(
            MarkdownEditingRules.change(
                for: .link,
                text: existing,
                selection: label
            )
        )
        XCTAssertEqual(applying(change, to: existing), existing)
        XCTAssertEqual(
            (existing as NSString).substring(with: change.selection),
            "https://example.test/orbit"
        )

        let unsafeLabel = "a]b\\c"
        let escaped = try XCTUnwrap(
            MarkdownEditingRules.change(
                for: .link,
                text: unsafeLabel,
                selection: NSRange(location: 0, length: unsafeLabel.utf16.count)
            )
        )
        let escapedText = applying(escaped, to: unsafeLabel)
        XCTAssertEqual(escapedText, "[a\\]b\\\\c](https://)")
        XCTAssertEqual(
            (escapedText as NSString).substring(with: escaped.selection),
            "https://"
        )

        let nested = "[outer [inner]](https://example.test/nested)"
        let nestedChange = try XCTUnwrap(
            MarkdownEditingRules.change(
                for: .link,
                text: nested,
                selection: (nested as NSString).range(of: "inner")
            )
        )
        XCTAssertEqual(
            (nested as NSString).substring(with: nestedChange.selection),
            "https://example.test/nested"
        )

        let linkOnly = "[Moon](https://example.test/orbit)"
        let afterLink = caret(atEndOf: linkOnly)
        let afterChange = try XCTUnwrap(
            MarkdownEditingRules.change(
                for: .link,
                text: linkOnly,
                selection: afterLink
            )
        )
        XCTAssertEqual(applying(afterChange, to: linkOnly), linkOnly + "[](https://)")
    }

    func testCodeBlockWrapsAndUnwrapsWithoutTouchingOutsideText() throws {
        let text = "before\nalpha\nbeta\nafter"
        let selected = (text as NSString).range(of: "alpha\nbeta")
        let change = try XCTUnwrap(
            MarkdownEditingRules.change(
                for: .codeBlock,
                text: text,
                selection: selected
            )
        )
        let wrapped = applying(change, to: text)
        XCTAssertEqual(wrapped, "before\n```\nalpha\nbeta\n```\nafter")
        XCTAssertEqual(
            (wrapped as NSString).substring(with: change.selection),
            "alpha\nbeta"
        )

        try assertChange(
            .codeBlock,
            text: wrapped,
            selection: change.selection,
            equals: text,
            selected: selected
        )

        let nestedFence = "alpha\n```\nomega"
        let longer = try XCTUnwrap(
            MarkdownEditingRules.change(
                for: .codeBlock,
                text: nestedFence,
                selection: NSRange(
                    location: 0,
                    length: nestedFence.utf16.count
                )
            )
        )
        XCTAssertEqual(
            applying(longer, to: nestedFence),
            "````\nalpha\n```\nomega\n````"
        )

        let informed = "```swift\nlet orbit = 1\n```\nafter"
        let infoChange = try XCTUnwrap(
            MarkdownEditingRules.change(
                for: .codeBlock,
                text: informed,
                selection: (informed as NSString).range(of: "let orbit = 1")
            )
        )
        XCTAssertEqual(applying(infoChange, to: informed), "let orbit = 1\nafter")
    }

    func testInvalidUTF16SelectionExpandsToComposedCharacterBoundaries() throws {
        let text = "A👩🏽‍💻B"
        let emoji = (text as NSString).range(of: "👩🏽‍💻")
        let invalid = NSRange(location: emoji.location + 1, length: 1)
        let change = try XCTUnwrap(
            MarkdownEditingRules.change(
                for: .bold,
                text: text,
                selection: invalid
            )
        )
        let result = applying(change, to: text)
        XCTAssertEqual(result, "A**👩🏽‍💻**B")
        XCTAssertEqual(
            (result as NSString).substring(with: change.selection),
            "👩🏽‍💻"
        )

        try assertChange(
            .italic,
            text: text,
            selection: NSRange(location: NSNotFound, length: 20),
            equals: text + "**",
            selected: NSRange(location: text.utf16.count + 1, length: 0)
        )
    }

    private func assertChange(
        _ command: MarkdownEditingCommand,
        text: String,
        selection: NSRange,
        equals expectedText: String,
        selected expectedSelection: NSRange,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let change = try XCTUnwrap(
            MarkdownEditingRules.change(
                for: command,
                text: text,
                selection: selection
            ),
            file: file,
            line: line
        )
        XCTAssertEqual(
            applying(change, to: text),
            expectedText,
            file: file,
            line: line
        )
        XCTAssertEqual(change.selection, expectedSelection, file: file, line: line)
    }

    private func applying(_ change: MarkdownEditingChange, to text: String) -> String {
        (text as NSString).replacingCharacters(
            in: change.range,
            with: change.replacement
        )
    }

    private func caret(atEndOf text: String) -> NSRange {
        NSRange(location: text.utf16.count, length: 0)
    }
}
