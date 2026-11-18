import Foundation
import XCTest

@testable import NativeEditor

@MainActor
final class MarkdownLinkContextIncrementalTests: XCTestCase {
    func testIndentedLinksFollowBlockContextWhenEditing() {
        for (previous, target, replacement) in [
            ("Heading\n    [Read](Map.md)\n", "Heading", "# Heading"),
            ("# Heading\n    [Read](Map.md)\n", "# Heading", "Heading"),
            ("- Root\n  - Section\n    - [Read](Map.md)\n", "Read", "Open"),
            ("- Root\n  - Section\n    - [Read](Map.md)\n", "- Root\n  - Section", "# Heading"),
            ("- Root\n  ```\n  [[Literal]]\nOutside [[Map]]\n", "  ```", "  Example"),
            ("- Root\n  Example\n  [[Literal]]\nOutside [[Map]]\n", "  Example", "  ```"),
        ] {
            check(previous, replacing: target, with: replacement)
        }
    }

    func testNestedLinksAndCodeHaveMatchingEditorStyles() {
        let text = "- Root\n  - Section\n    - [Read](Map.md)\n"
            + "      ```\n      [[Literal]]\n      ```\n"
            + "      [Next](Next.md)\n"
        let syntax = MarkdownSyntax.parse(text)
        let links = syntax.spans.filter { $0.role == .link }
        XCTAssertEqual(links.map { (text as NSString).substring(with: $0.range) },
                       ["[Read](Map.md)", "[Next](Next.md)"])
        XCTAssertEqual(syntax.paragraphRuns.filter { $0.kind == .codeBlock }.count, 3)
    }

    func testCachedCodeRangesShiftWithProseEdits() throws {
        let previous = "    [[Before]]\n\nThe trail stays bright.\n\n"
            + "```\n[[After]]\n```\n"
        let parsed = MarkdownSyntax.parseWithCodeBlocks(previous)
        let edit = (previous as NSString).range(of: "stays")
        let replacement = "stays very"
        let text = (previous as NSString).replacingCharacters(in: edit, with: replacement)
        let update = try XCTUnwrap(MarkdownSyntax.incrementallyParse(
            text, previousText: previous, previousResult: parsed.result,
            editedRange: NSRange(location: edit.location, length: replacement.utf16.count),
            changeInLength: replacement.utf16.count - edit.length,
            previousLinkCodeBlocks: parsed.linkCodeBlocks
        ))
        let full = MarkdownSyntax.parseWithCodeBlocks(text)
        XCTAssertEqual(update.result, full.result)
        XCTAssertEqual(update.linkCodeBlocks, full.linkCodeBlocks)
        XCTAssertLessThan(update.invalidatedRange.length, text.utf16.count)
    }

    func testAppendingTextAtTheEndOfCodeExpandsTheCachedRange() throws {
        for previous in ["```\nhello", "    hello"] {
            let parsed = MarkdownSyntax.parseWithCodeBlocks(previous)
            let text = previous + "1á"
            let update = try XCTUnwrap(MarkdownSyntax.incrementallyParse(
                text, previousText: previous, previousResult: parsed.result,
                editedRange: NSRange(location: previous.utf16.count, length: 2),
                changeInLength: 2, previousLinkCodeBlocks: parsed.linkCodeBlocks
            ))
            let full = MarkdownSyntax.parseWithCodeBlocks(text)
            XCTAssertEqual(update.result, full.result)
            XCTAssertEqual(update.linkCodeBlocks, full.linkCodeBlocks)
        }
    }

    func testFenceLikeInlineDelimiterEditReparsesAcrossHTMLLines() throws {
        let previous = "<div>\n```\n[x](a.md)\n```\n</div>\n"
        let edit = NSRange(location: "<div>\n".utf16.count, length: 1)
        let text = (previous as NSString).replacingCharacters(
            in: NSRange(location: edit.location, length: 0), with: "`"
        )
        let update = try XCTUnwrap(MarkdownSyntax.incrementallyParse(
            text, previousText: previous, previousResult: MarkdownSyntax.parse(previous),
            editedRange: edit, changeInLength: 1
        ))
        XCTAssertEqual(update.result, MarkdownSyntax.parse(text))
        XCTAssertEqual(update.invalidatedRange, NSRange(location: 0, length: text.utf16.count))
        check(previous, replacing: "a.md", with: "longer.md")
    }

    func testLateFrontmatterClosersMatchFullParse() {
        for separator in ["\n", "\r\n", "\u{2028}"] {
            for closer in ["---", "..."] {
                let previous = "---\(separator)[[Sky]]\(separator)words\(separator)Tail"
                check(previous, replacing: "words", with: closer)
            }
        }
        check("---\n[[Sky]]\nTail", replacing: "Tail", with: "---\nTail")
        check("---\n[[Sky]]\n---\n[[Moon]]\n...\nTail",
              replacing: "---\n[[Moon]]", with: "words\n[[Moon]]")
    }

    func testAppendingInsideOpenCommentMatchesFullParse() {
        for previous in ["Start\n<!-- hidden\n", "<!-- hidden\r\n",
                         "Start\n<!-- 🪐 hidden\n", "Start\n<!-- hidden"] {
            for replacement in ["[[Moon]]", "--> [[Moon]]", "\n[[Moon]]"] {
                check(previous, edit: NSRange(location: previous.utf16.count, length: 0),
                      replacement: replacement)
            }
        }
    }

    func testCommentDelimitersAndCodeExclusionsMatchFullParse() {
        for (previous, target, replacement) in [
            ("Start\n<!-- hidden\n[[Sky]]\n-->\n[[Moon]]\nTail", "<!--", "words"),
            ("Start\n<!-- hidden\n[[Sky]]\n-->\n[[Moon]]\nTail", "-->", "words"),
            ("Start\n<!-- hidden\n[[Sky]]\n-->\n[[Moon]]\nTail", "hidden", "-->"),
            ("Start\n<!-- hidden -->\n[[Moon]]\nTail", "<!--", "\\<!--"),
            ("Start\n\\<!-- example\n[[Sky]]\nTail", "\\<!--", "<!--"),
            ("Start\n`<!-- example`\n[[Sky]]\nTail", "example", "changed"),
            ("Start\n`<!-- example`\n[[Sky]]\nTail", "`<!--", "<!--"),
            ("```\n<!-- example\n```\n[[Sky]]\nTail", "example", "changed"),
            ("```\n<!-- example\n```\n[[Sky]]\nTail", "<!--", "-->"),
            ("    <!-- example\n[[Sky]]\nTail", "example", "changed"),
        ] {
            check(previous, replacing: target, with: replacement)
        }
    }

    func testAppendingAfterClosedContextStaysIncremental() throws {
        for prefix in ["<!-- hidden\n[[Sky]] -->\n\n",
                       "---\naliases: [Sky]\n---\n\n",
                       "Heading\n---\n\n", "Before\n\n---\n\n"] {
            let previous = prefix + String(repeating: "Ordinary paragraph.\n\n", count: 100)
                + "Last paragraph."
            let update = try XCTUnwrap(check(
                previous, edit: NSRange(location: previous.utf16.count, length: 0),
                replacement: " bright"
            ))
            XCTAssertLessThan(update.invalidatedRange.length, 256)
        }
    }

    func testUnicodeSafeBoundaryMatrixMatchesFullParse() {
        let samples = [
            "Start\n<!-- 🪐 hidden\n[[Sky]]\n-->\n[[Moon]]\nTail\n",
            "Start\n<!-- hidden\n[[Sky]]\n",
            "---\n[[Sky]]\nwords\nTail\n",
            "---\r\naliases: [Sky]\r\n---\r\n[[Moon]]\r\nTail",
            "---\u{2028}[[Sky]]\u{2028}words\u{2028}Tail\n",
            "Before\n\n---\n[[Sky]]\n---\nTail\n",
        ]
        for previous in samples {
            let previousResult = MarkdownSyntax.parse(previous)
            var offsets = [0]
            for scalar in previous.unicodeScalars {
                offsets.append(offsets.last! + scalar.utf16.count)
            }
            for index in offsets.indices {
                for length in [0, offsets[min(index + 1, offsets.count - 1)] - offsets[index]] {
                    for replacement in ["x", "\n", "<!--", "-->", "---", "...", ""] {
                        check(previous,
                              edit: NSRange(location: offsets[index], length: length),
                              replacement: replacement, previousResult: previousResult)
                    }
                }
            }
        }
    }

    @discardableResult
    private func check(
        _ previous: String, replacing target: String, with replacement: String,
        file: StaticString = #filePath, line: UInt = #line
    ) -> MarkdownSyntaxIncrementalResult? {
        let edit = (previous as NSString).range(of: target)
        XCTAssertNotEqual(edit.location, NSNotFound, file: file, line: line)
        guard edit.location != NSNotFound else { return nil }
        return check(previous, edit: edit, replacement: replacement, file: file, line: line)
    }

    @discardableResult
    private func check(
        _ previous: String, edit: NSRange, replacement: String,
        previousResult: MarkdownSyntaxResult? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) -> MarkdownSyntaxIncrementalResult? {
        let text = (previous as NSString).replacingCharacters(in: edit, with: replacement)
        let update = MarkdownSyntax.incrementallyParse(
            text, previousText: previous,
            previousResult: previousResult ?? MarkdownSyntax.parse(previous),
            editedRange: NSRange(location: edit.location, length: replacement.utf16.count),
            changeInLength: replacement.utf16.count - edit.length
        )
        if let update {
            XCTAssertEqual(update.result, MarkdownSyntax.parse(text),
                           "source=\(previous.debugDescription), edit=\(edit), "
                               + "replacement=\(replacement.debugDescription)",
                           file: file, line: line)
        }
        return update
    }
}
