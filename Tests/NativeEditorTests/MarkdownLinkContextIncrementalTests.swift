import Foundation
import XCTest

@testable import NativeEditor

@MainActor
final class MarkdownLinkContextIncrementalTests: XCTestCase {
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
