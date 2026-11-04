import Foundation
import XCTest

@testable import NativeEditor

@MainActor
final class MarkdownBlockSyntaxTests: XCTestCase {
    func testUnderlineHeadingsStyleTheirParagraph() {
        let text = "Packing list\n============\n\nBefore we\nleave\n---\nBody"
        let result = MarkdownSyntax.parse(text)
        XCTAssertEqual(roles(in: text, result), [
            "heading(level: 1)=Packing list", "rule=============",
            "heading(level: 2)=Before we\nleave", "rule=---",
        ])
        XCTAssertEqual(result.paragraphRuns.map(\.kind), [
            .heading(level: 1), .heading(level: 2), .heading(level: 2),
        ])
        XCTAssertEqual(result.fontRuns.map(\.headingLevel), [1, 2])
        // Hashes that start an underline heading's text stay visible.
        let tag = "#hashtag\n---\nActive"
        XCTAssertEqual(hidden(in: tag, selection: (tag as NSString).range(of: "Active")), [])
    }

    func testRulesAndFrontmatter() {
        let text = "---\ntitle: Trip\ntags: [a]\n---\nIntro\n\n---\n\n* * *\n- item\n___\n```\n---\n```"
        XCTAssertEqual(roles(in: text, MarkdownSyntax.parse(text)), [
            "rule=---", "rule=* * *", "listMarker=-", "rule=___", "code=```\n---\n```",
        ])
        // Without its closing line, the opening `---` is an ordinary rule.
        XCTAssertEqual(roles(in: "---\ntitle", MarkdownSyntax.parse("---\ntitle")), ["rule=---"])
    }

    func testTimeCalculatorKeepsEqualsLinesAsText() {
        // Calculator notes have no underline headings; `---` stays a rule.
        let text = "Travel\n1h\n=\nNotes\n---\nDay\n==="
        XCTAssertEqual(roles(in: text, MarkdownSyntax.parse(text, timeSums: true)), ["rule=---"])
        let timesheet = "Mon 8h\nTue 7h\n---\n="
        XCTAssertEqual(MarkdownTimeCalculator.sums(
            in: timesheet, result: MarkdownSyntax.parse(timesheet, timeSums: true)
        ).map(\.seconds), [54_000])
        let sums = MarkdownTimeCalculator.sums(
            in: "1h\n30m\n=", result: MarkdownSyntax.parse("1h\n30m\n=", timeSums: true)
        )
        XCTAssertEqual(sums.map(\.seconds), [5_400])
        // Without underline headings, edits above a sum stay incremental.
        let block = "1h\n" + String(repeating: "30m\n", count: 2_000) + "="
        let edited = "2" + block.dropFirst()
        XCTAssertNotNil(MarkdownSyntax.incrementallyParse(
            edited, previousText: block, previousResult: MarkdownSyntax.parse(block, timeSums: true),
            editedRange: NSRange(location: 0, length: 1), changeInLength: 0, timeSums: true
        ))
    }

    func testLivePreviewHidesRules() {
        let text = "Title\n---\n\n***\n\nEnd"
        let source = text as NSString
        func transparent(at location: Int) -> [String] {
            MarkdownLivePreview.transparentRanges(
                in: text, result: MarkdownSyntax.parse(text),
                snapshot: MarkdownLivePreviewSnapshot(
                    mode: .livePreview, selection: NSRange(location: location, length: 0)
                )
            ).map(source.substring(with:))
        }
        XCTAssertEqual(transparent(at: source.length), ["---", "***"])
        // The caret's line shows its source.
        XCTAssertEqual(transparent(at: 7), ["***"])
        XCTAssertEqual(hidden(in: text, selection: NSRange(location: source.length, length: 0)), [])
    }

    func testLivePreviewHidesAutolinkBrackets() {
        let text = "x\nSee <https://example.com> or https://apple.com"
        let result = MarkdownSyntax.parse(text)
        XCTAssertEqual(
            result.spans.filter { $0.role == .link }.map { (text as NSString).substring(with: $0.range) },
            ["<https://example.com>", "https://apple.com"]
        )
        XCTAssertEqual(hidden(in: text, selection: NSRange(location: 1, length: 0)), ["<", ">"])
    }

    func testIncrementalEditsMatchFullParse() {
        let edits: [(String, String, String)] = [
            ("Intro\n\nTitle\nTail", "Tail", "==="),
            ("Intro\n\nTitle\n===\nTail", "===", "x"),
            ("Intro\n\nTitle\n===\nTail", "Title", ""),
            ("Intro\n\nTitle\nmore\n===\n\nTail", "Title", "- Title"),
            ("Intro\n\n\nTitle\n===\n\nTail", "\n\n\nTitle", "\n\nAbove\nTitle"),
            ("- item\n\nTitle\n---\nTail", "\n\nTitle", "\nTitle"),
            ("- item\nTitle\n---\nTail", "- item", "item"),
            ("Para\n\n---\nTail", "\n\n---", "\n---"),
            ("Para\n\nnext\n---\nTail", "Para\n\n", "Para\n"),
            ("Para\nnext\n\n---\nTail", "next\n\n", "next\n"),
            ("Intro\n\n- a\n- b\n---\n\nTail", "- b", "- bb"),
            ("---\ntitle: x\n--\nBody\n---\n", "--\nBody", "---\nBody"),
            ("Text\n\\* one\nTail", "\\* one", "\\* two \\_"),
        ]
        for (previous, target, replacement) in edits {
            let edit = (previous as NSString).range(of: target)
            XCTAssertNotEqual(edit.location, NSNotFound, target)
            let text = (previous as NSString).replacingCharacters(in: edit, with: replacement)
            guard let update = MarkdownSyntax.incrementallyParse(
                text, previousText: previous, previousResult: MarkdownSyntax.parse(previous),
                editedRange: NSRange(location: edit.location, length: replacement.utf16.count),
                changeInLength: replacement.utf16.count - edit.length
            ) else { continue }
            XCTAssertEqual(update.result, MarkdownSyntax.parse(text), "\(previous) → \(text)")
        }
    }

    func testEveryEditNearUnderlinesMatchesFullParse() {
        var incremental = 0
        for base in [
            "Intro *a\n\nTitle\nmore\n===\n- item\nlazy\n---\n\nPara\n\n***\n> q\n--\nEnd",
            "---\ntitle: x\n---\nOne\n--\n```\nTwo\n---\n```\nThree\n    four\n==\n",
            "# Head\nBody\n---\n1) a\n2) b\n\nx\\*y\n___\n| a |\n| - |\nz\n---",
        ] {
        let source = base as NSString
        for location in 0...source.length {
            for (deleted, inserted) in [(0, "="), (0, "-"), (0, "\n"), (0, "x"), (0, "- "),
                                        (1, ""), (1, "\n"), (2, "")]
            where location + deleted <= source.length {
                let edit = NSRange(location: location, length: deleted)
                let text = source.replacingCharacters(in: edit, with: inserted)
                guard let update = MarkdownSyntax.incrementallyParse(
                    text, previousText: base, previousResult: MarkdownSyntax.parse(base),
                    editedRange: NSRange(location: location, length: inserted.utf16.count),
                    changeInLength: inserted.utf16.count - deleted
                ) else { continue }
                incremental += 1
                XCTAssertEqual(update.result, MarkdownSyntax.parse(text),
                               "\(base.debugDescription) → \(text.debugDescription)")
            }
        }
        }
        XCTAssertGreaterThan(incremental, 300)
    }

    func testTypingFarFromHeadingsStaysIncremental() throws {
        let previous = "Title\n===\n\n" + String(repeating: "Ordinary paragraph.\n\n", count: 5_000)
            + "Last paragraph."
        let target = (previous as NSString).range(of: "Last paragraph")
        let text = (previous as NSString).replacingCharacters(in: target, with: "Last bright paragraph")
        let update = try XCTUnwrap(MarkdownSyntax.incrementallyParse(
            text, previousText: previous, previousResult: MarkdownSyntax.parse(previous),
            editedRange: NSRange(location: target.location, length: 21), changeInLength: 7
        ))
        XCTAssertLessThan(update.invalidatedRange.length, 256)
        XCTAssertEqual(update.result, MarkdownSyntax.parse(text))
    }

    private func roles(in text: String, _ result: MarkdownSyntaxResult) -> [String] {
        result.spans.map { "\($0.role)=\((text as NSString).substring(with: $0.range))" }
    }

    private func hidden(in text: String, selection: NSRange) -> [String] {
        MarkdownLivePreview.hiddenRanges(
            in: text, result: MarkdownSyntax.parse(text),
            snapshot: MarkdownLivePreviewSnapshot(mode: .livePreview, selection: selection)
        ).map { (text as NSString).substring(with: $0) }
    }
}
