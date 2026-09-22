import Foundation
import XCTest

@testable import NativeEditor

@MainActor
final class MarkdownSyntaxIncrementalTests: XCTestCase {
    func testEmphasisSpansSoftBreaksButNotSeparateBlocks() {
        for marker in ["**", "__", "*", "_"] {
            for newline in ["\n", "\r\n"] {
                let text = "\(marker)first\(newline)second\(marker)"
                let emphasis = MarkdownSyntax.parse(text).spans.filter {
                    $0.role == .strong || $0.role == .emphasis
                }
                XCTAssertEqual(emphasis.map(\.range),
                               [NSRange(location: 0, length: text.utf16.count)])
            }
            for boundary in ["\n\n", "\n \t\n", "\r\n\r\n",
                             "\n# Heading\n", "\n```\ncode\n```\n", "\n- "] {
                let text = "\(marker)first\(boundary)second\(marker)"
                XCTAssertFalse(MarkdownSyntax.parse(text).spans.contains {
                    $0.role == .strong || $0.role == .emphasis
                }, text)
            }
        }
    }

    func testUnclosedBoldInLargeNoteStopsAtParagraphBoundary() throws {
        let previous = "Intro\n\nfirst\nsecond\n\n"
            + String(repeating: "Unrelated paragraph.\n\n", count: 24_000)
        let update = try check(previous: previous, target: "first",
                               replacement: "**first")
        XCTAssertLessThan(update.invalidatedRange.length, 256)
        XCTAssertFalse(update.result.spans.contains { $0.role == .strong })
    }

    func testParagraphBoundaryEditsUpdateMultilineBold() throws {
        for (previous, target, replacement) in [
            ("**first\n\nsecond**\n\nTail", "\n\n", "\n"),
            ("**first\nsecond**\n\nTail", "\n", "\n\n"),
            ("**first\n \t\nsecond**\n\nTail", " \t", "middle"),
            ("**first\n# Heading\nsecond**\n\nTail", "# ", ""),
        ] {
            _ = try check(previous: previous, target: target, replacement: replacement)
        }
    }

    func testOrdinaryUnicodeEditMatchesFullParseAndShiftsLaterSyntax() throws {
        let previous = "# Before\n\nA café paragraph.\n\n[After](url)\n"
        let edit = (previous as NSString).range(of: "café")
        let replacement = "bright 🪐"
        let text = (previous as NSString).replacingCharacters(
            in: edit,
            with: replacement
        )
        let editedRange = NSRange(
            location: edit.location,
            length: (replacement as NSString).length
        )

        let update = try XCTUnwrap(MarkdownSyntax.incrementallyParse(
            text,
            previousText: previous,
            previousResult: MarkdownSyntax.parse(previous),
            editedRange: editedRange,
            changeInLength: editedRange.length - edit.length
        ))

        XCTAssertEqual(update.result, MarkdownSyntax.parse(text))
        XCTAssertEqual(
            update.invalidatedRange,
            (text as NSString).lineRange(for: editedRange)
        )
        XCTAssertLessThan(update.invalidatedRange.length, (text as NSString).length)
    }

    func testDeletionMatchesFullParseWithParagraphMetadataOnBothSides() throws {
        let previous = "# Heading\n  Indented ordinary words\n> Quote\n"
        let edit = (previous as NSString).range(of: " ordinary")
        let text = (previous as NSString).replacingCharacters(
            in: edit,
            with: ""
        )
        let editedRange = NSRange(location: edit.location, length: 0)

        let update = try XCTUnwrap(MarkdownSyntax.incrementallyParse(
            text,
            previousText: previous,
            previousResult: MarkdownSyntax.parse(previous),
            editedRange: editedRange,
            changeInLength: -edit.length
        ))

        XCTAssertEqual(update.result, MarkdownSyntax.parse(text))
    }

    func testLineLocalHeadingAndLinkEditMatchesFullParse() throws {
        let previous = "Intro\n[old](url)\nTail"
        let edit = (previous as NSString).range(of: "[old](url)")
        let replacement = "## [new](other)"
        let text = (previous as NSString).replacingCharacters(
            in: edit,
            with: replacement
        )
        let editedRange = NSRange(
            location: edit.location,
            length: (replacement as NSString).length
        )

        let update = try XCTUnwrap(MarkdownSyntax.incrementallyParse(
            text,
            previousText: previous,
            previousResult: MarkdownSyntax.parse(previous),
            editedRange: editedRange,
            changeInLength: editedRange.length - edit.length
        ))

        XCTAssertEqual(update.result, MarkdownSyntax.parse(text))
    }

    func testUnicodeSeparatorUsesTheFullParserLineBoundary() throws {
        let previous = "first\u{2028}ordinary text\n# After"
        let edit = (previous as NSString).range(of: "ordinary")
        let replacement = "changed"
        let text = (previous as NSString).replacingCharacters(
            in: edit,
            with: replacement
        )
        let editedRange = NSRange(
            location: edit.location,
            length: (replacement as NSString).length
        )

        let update = try XCTUnwrap(MarkdownSyntax.incrementallyParse(
            text,
            previousText: previous,
            previousResult: MarkdownSyntax.parse(previous),
            editedRange: editedRange,
            changeInLength: editedRange.length - edit.length
        ))

        XCTAssertEqual(update.invalidatedRange.location, 0)
        XCTAssertEqual(update.result, MarkdownSyntax.parse(text))
    }

    func testFormattingAndNewlinesReuseUnaffectedSuffix() throws {
        for (previous, target, replacement) in [
            ("Intro\nordinary words\nTail", " ", "\n"),
            ("Intro\n**bold words**\nTail", "words", "bright 🪐 words"),
            ("Intro\n`code` and ~~old~~\nTail", "old", "new"),
            ("Intro\nplain words\nTail", "words", "**words**"),
            ("Intro\nfirst\nsecond\nTail", "first\nsecond", "joined"),
            ("Intro\n*opening\nmiddle words\nclosing*\nTail", "words", "paragraph"),
            ("Intro\n```\ncode\n```\nTail", "code", "other code"),
        ] {
            let update = try check(previous: previous, target: target,
                                   replacement: replacement)
            XCTAssertLessThan(NSMaxRange(update.invalidatedRange),
                              (previous as NSString).length
                                + (replacement as NSString).length
                                - (target as NSString).length)
        }
    }

    func testChangedContextExtendsPastTheEditedLine() throws {
        let update = try check(
            previous: "Intro\n**opening**\nmiddle\nclosing**\nTail",
            target: "**opening**", replacement: "**opening"
        )
        XCTAssertGreaterThan(update.invalidatedRange.length, "**opening\n".utf16.count)
        // A blank line terminates unmatched inline context.
        _ = try check(previous: "*open\n\nplain\nTail", target: "plain",
                      replacement: "plain*")
        _ = try check(previous: "Intro\n```\ncode\n```\nTail", target: "code\n```",
                      replacement: "code")
    }

    func testLongUnclosedContextKeepsFullParseFallback() {
        let previous = "Intro\nplain\n" + String(repeating: "ordinary line\n", count: 6000)
        let edit = (previous as NSString).range(of: "plain")
        let replacement = "```\nplain"
        let text = (previous as NSString).replacingCharacters(in: edit, with: replacement)
        XCTAssertNil(MarkdownSyntax.incrementallyParse(
            text, previousText: previous, previousResult: MarkdownSyntax.parse(previous),
            editedRange: NSRange(location: edit.location, length: replacement.utf16.count),
            changeInLength: replacement.utf16.count - edit.length
        ))
    }

    func testBoundaryEditsMatchFullParserIncludingCachedContext() throws {
        let samples = [
            "# Head\n**bold** and _word_\nTail\n",
            "*open\n\nmiddle\nclose*\nTail",
            "```\ncode\n```\n`inline`\nTail",
            "~~~\ncode\n~~~\n~~strike~~\nTail",
            "\\*literal* e\u{0301} 🪐\n==mark==\nTail",
            "unmatched *opener\ntext\n",
            "**first\n \t\nsecond**\n\nTail",
            "**first\n# Heading\nsecond**\n\nTail",
            "**first\n- second**\n\nTail",
            "`a`\n```\nb\n```\n`c`",
        ]
        for previous in samples {
            let previousResult = MarkdownSyntax.parse(previous)
            var offsets = [0]
            for scalar in previous.unicodeScalars {
                offsets.append(offsets.last! + scalar.utf16.count)
            }
            for index in offsets.indices {
                for replacement in ["x", " ", "\n", "**", "`", "", "\n~~~\n"] {
                    let end = offsets[min(index + 1, offsets.count - 1)]
                    let edit = NSRange(location: offsets[index], length: end - offsets[index])
                    let text = (previous as NSString).replacingCharacters(in: edit, with: replacement)
                    let update = try XCTUnwrap(MarkdownSyntax.incrementallyParse(
                        text, previousText: previous, previousResult: previousResult,
                        editedRange: NSRange(location: edit.location, length: replacement.utf16.count),
                        changeInLength: replacement.utf16.count - edit.length
                    ))
                    XCTAssertEqual(update.result, MarkdownSyntax.parse(text),
                                   "source=\(previous.debugDescription), edit=\(edit), replacement=\(replacement.debugDescription)")
                }
            }
        }
    }

    @discardableResult
    private func check(
        previous: String, target: String, replacement: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> MarkdownSyntaxIncrementalResult {
        let edit = (previous as NSString).range(of: target)
        let text = (previous as NSString).replacingCharacters(in: edit, with: replacement)
        let update = try XCTUnwrap(MarkdownSyntax.incrementallyParse(
            text, previousText: previous, previousResult: MarkdownSyntax.parse(previous),
            editedRange: NSRange(location: edit.location, length: replacement.utf16.count),
            changeInLength: replacement.utf16.count - edit.length
        ), file: file, line: line)
        XCTAssertEqual(update.result, MarkdownSyntax.parse(text), file: file, line: line)
        return update
    }
}
