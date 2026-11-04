import Foundation
import XCTest
@testable import NoteCore

final class MarkdownSetextHeadingsTests: XCTestCase {
    func testUnderlinesFollowCommonMarkParagraphs() {
        XCTAssertEqual(headings("Packing list\n============"), ["1:Packing list"])
        XCTAssertEqual(headings("Before we leave\n---"), ["2:Before we leave"])
        XCTAssertEqual(headings("First line\nsecond line\n  ==="), ["1:First line second line"])
        XCTAssertEqual(headings("Title\n--"), ["2:Title"])
        // A single dash is an empty list item, not an underline.
        XCTAssertEqual(headings("Title\n-"), [])
        // Underlines need a paragraph directly above them.
        XCTAssertEqual(headings("Title\n\n---"), [])
        XCTAssertEqual(headings("# Title\n==="), [])
        XCTAssertEqual(headings("---\n==="), [])
        // Internal spaces make a rule, and four spaces an indented line.
        XCTAssertEqual(headings("Title\n- - -"), [])
        XCTAssertEqual(headings("Title\n    ---"), [])
        // Lines after a list item or quote continue that container.
        XCTAssertEqual(headings("- item\n---"), [])
        XCTAssertEqual(headings("- item\nlazy\n---"), [])
        XCTAssertEqual(headings("> quote\n==="), [])
        XCTAssertEqual(headings("1) item\n==="), [])
        XCTAssertEqual(headings("Title\n=", timeSums: true), [])
        XCTAssertEqual(headings("Title\n---", timeSums: true), [])
    }

    func testThematicBreaks() {
        for line in ["---", "***", "___", " - - -", "*  *  *", "-----   "] {
            XCTAssertTrue(isRule(line), line)
        }
        for line in ["--", "    ---", "-- -x", "==="] {
            XCTAssertFalse(isRule(line), line)
        }
    }

    func testParagraphReachesUnderline() {
        func reaches(_ text: String) -> Bool {
            MarkdownSetextHeadings.paragraphReachesUnderline(from: 0, in: text as NSString)
        }
        XCTAssertTrue(reaches("more\ntext\n---\n"))
        XCTAssertTrue(reaches("==="))
        XCTAssertTrue(reaches("`inline` code\n---"))
        XCTAssertFalse(reaches("more\n\n---"))
        XCTAssertFalse(reaches("- item\n---"))
        XCTAssertFalse(reaches("```\n---"))
        XCTAssertFalse(reaches("text\n* * *"))
    }

    func testHeadingLinksUseTheEditorRule() {
        let text = "---\ntitle: Trip\n---\nPacking list\n===\n\n- item\n---\n\nTwo\nlines\n---"
        XCTAssertEqual(NotebookLinkParser.headings(in: text), ["Packing list", "Two lines", "Packing list#Two lines"])
        let target = NotebookLinkParser.targetRange(for: "Two lines", in: text)
        XCTAssertEqual(target.map { (text as NSString).substring(with: $0) }, "Two\nlines")
    }

    private func headings(_ text: String, timeSums: Bool = false) -> [String] {
        let source = text as NSString
        var lines: [NSRange] = []
        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length),
                                   options: .byLines) { _, range, _, _ in lines.append(range) }
        return MarkdownSetextHeadings.find(
            in: source, lines: lines, timeSums: timeSums, isExcluded: { _ in false }
        ).map { heading in
            let title = lines[heading.paragraph].map {
                source.substring(with: $0).trimmingCharacters(in: .whitespaces)
            }.joined(separator: " ")
            return "\(heading.level):\(title)"
        }
    }

    private func isRule(_ line: String) -> Bool {
        MarkdownSetextHeadings.isThematicBreak(
            NSRange(location: 0, length: line.utf16.count), in: line as NSString
        )
    }
}
