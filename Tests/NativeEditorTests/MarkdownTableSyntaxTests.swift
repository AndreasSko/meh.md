import Foundation
import XCTest

@testable import NativeEditor

@MainActor
final class MarkdownTableSyntaxTests: XCTestCase {
    func testOuterPipesUnicodeAndCRLFRangesPreserveSource() throws {
        let text = "Before\r\n| Name | 🌙 |\r\n| :--- | ---: |\r\n"
            + "| café | 🪐 |\r\n\r\nAfter"
        let source = text as NSString
        let table = try XCTUnwrap(MarkdownSyntax.parse(text).tables.first)
        XCTAssertEqual(MarkdownSyntax.parse(text).tables.count, 1)
        XCTAssertEqual(source.substring(with: table.range),
                       "| Name | 🌙 |\r\n| :--- | ---: |\r\n| café | 🪐 |\r\n")
        XCTAssertEqual(source.substring(with: table.header.range),
                       "| Name | 🌙 |\r\n")
        XCTAssertEqual(source.substring(with: table.delimiterRange),
                       "| :--- | ---: |\r\n")
        XCTAssertEqual(table.header.cells.map(source.substring(with:)),
                       ["Name", "🌙"])
        XCTAssertEqual(table.rows[0].cells.map(source.substring(with:)),
                       ["café", "🪐"])
        XCTAssertEqual(table.alignments, [.left, .right])
    }

    func testOptionalOuterPipesEscapesAndRaggedRows() throws {
        let text = "a\\|b | c | d\n:--- | :---: | ---:\n"
            + "one | two\nonly one\n1 | 2 | 3 | 4\n"
        let source = text as NSString
        let table = try XCTUnwrap(MarkdownSyntax.parse(text).tables.first)
        XCTAssertEqual(table.header.cells.map(source.substring(with:)),
                       ["a\\|b", "c", "d"])
        XCTAssertEqual(table.alignments, [.left, .center, .right])
        XCTAssertEqual(table.rows.map { $0.cells.count }, [2, 1, 4])
        XCTAssertEqual(source.substring(with: table.rows[2].range),
                       "1 | 2 | 3 | 4\n")
    }

    func testSingleColumnDelimiterCanOmitOuterPipes() throws {
        for delimiter in ["---", "-", ":-", "-:", ":-:"] {
            let text = "| Name |\n" + delimiter + "\n| Value |\n"
            let table = try XCTUnwrap(MarkdownSyntax.parse(text).tables.first)
            XCTAssertEqual(table.header.cells.count, 1)
            XCTAssertEqual(table.rows.count, 1)
        }
        XCTAssertTrue(MarkdownSyntax.parse("Name\n---\n").tables.isEmpty)
        XCTAssertTrue(MarkdownSyntax.parse("| Name |\n    ---\n").tables.isEmpty)
    }

    func testNonTablesAndCodeAreExcluded() {
        let samples = [
            "a | b\n--- | no\n",
            "a | b\n---\n",
            "| a | b |\n| --- | --- | --- |\n",
            "    a | b\n    --- | ---\n",
            "\ta | b\n\t--- | ---\n",
            "  \ta | b\n  \t--- | ---\n",
            "> a | b\n> --- | ---\n",
            "- a | b\n  --- | ---\n",
            "- item\n  a | b\n  --- | ---\n",
            "# a | b\n--- | ---\n",
            "***\n| --- | --- |\n",
            "```\na | b\n--- | ---\n```\n",
            "~~~\na | b\n--- | ---\n~~~\n",
        ]
        for text in samples {
            XCTAssertTrue(MarkdownSyntax.parse(text).tables.isEmpty, text)
        }
    }

    func testInlineStylingDoesNotCrossCellsOrDelimiter() throws {
        let text = "| *open | close* | `code` | ~~open | close~~ |\n"
            + "| --- | --- | --- | --- | --- |\n"
            + "| **bold** | ==mark== | [link](url) | `a | b` |\n"
        let parsed = MarkdownSyntax.parse(text)
        let source = text as NSString
        let table = try XCTUnwrap(parsed.tables.first)
        XCTAssertFalse(parsed.spans.contains { $0.role == .emphasis })
        XCTAssertEqual(parsed.spans.filter { $0.role == .strong }
            .map { source.substring(with: $0.range) }, ["**bold**"])
        XCTAssertEqual(parsed.spans.filter { $0.role == .highlight }
            .map { source.substring(with: $0.range) }, ["==mark=="])
        XCTAssertEqual(parsed.spans.filter { $0.role == .code }
            .map { source.substring(with: $0.range) },
            ["`code`", "`a", "`"])
        XCTAssertEqual(parsed.spans.filter { $0.role == .link }
            .map { source.substring(with: $0.range) }, ["[link](url)"])
        XCTAssertFalse(parsed.spans.contains {
            $0.role == .strikethrough
        })
        let allCells = ([table.header] + table.rows).flatMap(\.cells)
        XCTAssertTrue(parsed.spans.allSatisfy { span in
            allCells.contains { cell in
                span.range.location >= cell.location
                    && NSMaxRange(span.range) <= NSMaxRange(cell)
            }
        })
        XCTAssertFalse(parsed.paragraphRuns.contains {
            $0.range.location >= table.range.location
                && $0.range.location < NSMaxRange(table.range)
        })
    }

    func testSingleDashDelimiterAndPipeFreeBodyRow() throws {
        let text = "| one | two |\n| :- | -: |\nplain body\n\nAfter"
        let source = text as NSString
        let table = try XCTUnwrap(MarkdownSyntax.parse(text).tables.first)
        XCTAssertEqual(table.alignments, [.left, .right])
        XCTAssertEqual(table.rows.count, 1)
        XCTAssertEqual(table.rows[0].cells.map(source.substring(with:)),
                       ["plain body"])
        XCTAssertEqual(source.substring(with: table.range),
                       "| one | two |\n| :- | -: |\nplain body\n")
    }

    func testBlockStartsTerminatePipeFreeBodyRows() throws {
        let endings = [
            "# Heading\n", "---\n", "* * *\n",
            "```\ncode\n```\n", "~~~\ncode\n~~~\n",
            "> quote\n", "- list item\n", "    indented code\n",
        ]
        for ending in endings {
            let text = "| a | b |\n| --- | --- |\nplain\n" + ending
            let table = try XCTUnwrap(
                MarkdownSyntax.parse(text).tables.first, ending
            )
            XCTAssertEqual((text as NSString).substring(with: table.range),
                           "| a | b |\n| --- | --- |\nplain\n", ending)
            XCTAssertEqual(table.rows.count, 1, ending)
        }
    }

    func testIncrementalCreationAndRemovalFallBackToFullParse() {
        let plain = "a | b\nordinary\nTail"
        let table = "a | b\n--- | ---\nTail"
        let old = (plain as NSString).range(of: "ordinary")
        let replacement = "--- | ---"
        let edited = NSRange(location: old.location,
                             length: replacement.utf16.count)
        XCTAssertNil(MarkdownSyntax.incrementallyParse(
            table, previousText: plain,
            previousResult: MarkdownSyntax.parse(plain),
            editedRange: edited,
            changeInLength: edited.length - old.length
        ))
        XCTAssertEqual(MarkdownSyntax.parse(table).tables.count, 1)

        let inverse = (table as NSString).range(of: replacement)
        XCTAssertNil(MarkdownSyntax.incrementallyParse(
            plain, previousText: table,
            previousResult: MarkdownSyntax.parse(table),
            editedRange: NSRange(location: inverse.location,
                                 length: old.length),
            changeInLength: old.length - inverse.length
        ))
        XCTAssertTrue(MarkdownSyntax.parse(plain).tables.isEmpty)
    }

    func testDistantOrdinaryPipeDoesNotForceFullParse() throws {
        let previous = "one | two\n\nordinary text\n\nTail"
        let edit = (previous as NSString).range(of: "ordinary")
        let replacement = "updated"
        let text = (previous as NSString).replacingCharacters(
            in: edit, with: replacement
        )
        let update = try XCTUnwrap(MarkdownSyntax.incrementallyParse(
            text, previousText: previous,
            previousResult: MarkdownSyntax.parse(previous),
            editedRange: NSRange(location: edit.location,
                                 length: replacement.utf16.count),
            changeInLength: replacement.utf16.count - edit.length
        ))
        XCTAssertEqual(update.result, MarkdownSyntax.parse(text))
    }

    func testIncrementalEditsReuseDistantTableBeforeAndAfter() throws {
        let previous = "Before ordinary text\n\n"
            + "| a | b |\n| --- | --- |\n| one | two |\n\n"
            + "After ordinary text\n"
        for target in ["Before", "After"] {
            let edit = (previous as NSString).range(of: target)
            let replacement = "Updated 🪐"
            let text = (previous as NSString).replacingCharacters(
                in: edit, with: replacement
            )
            let update = try XCTUnwrap(MarkdownSyntax.incrementallyParse(
                text, previousText: previous,
                previousResult: MarkdownSyntax.parse(previous),
                editedRange: NSRange(location: edit.location,
                                     length: replacement.utf16.count),
                changeInLength: replacement.utf16.count - edit.length
            ), target)
            XCTAssertEqual(update.result, MarkdownSyntax.parse(text), target)
            XCTAssertEqual(update.result.tables.count, 1, target)
        }
    }

    func testDeletingBlankAtPipeFreeTableEndFallsBack() throws {
        let previous = "| a | b |\n| --- | --- |\nplain\n\nTail"
        let table = try XCTUnwrap(MarkdownSyntax.parse(previous).tables.first)
        let edit = NSRange(location: NSMaxRange(table.range), length: 1)
        let text = (previous as NSString).replacingCharacters(
            in: edit, with: ""
        )
        XCTAssertEqual(MarkdownSyntax.parse(text).tables.first?.rows.count,
                       2)
        XCTAssertNil(MarkdownSyntax.incrementallyParse(
            text, previousText: previous,
            previousResult: MarkdownSyntax.parse(previous),
            editedRange: NSRange(location: edit.location, length: 0),
            changeInLength: -1
        ))
    }

    func testRemovingDistantFenceExposesTableAndFallsBack() {
        let previous = "```\nintro\n\n| a | b |\n| --- | --- |\n```\n"
        let edit = NSRange(location: 0, length: 3)
        let text = (previous as NSString).replacingCharacters(
            in: edit, with: ""
        )
        XCTAssertTrue(MarkdownSyntax.parse(previous).tables.isEmpty)
        XCTAssertEqual(MarkdownSyntax.parse(text).tables.count, 1)
        XCTAssertNil(MarkdownSyntax.incrementallyParse(
            text, previousText: previous,
            previousResult: MarkdownSyntax.parse(previous),
            editedRange: NSRange(location: 0, length: 0),
            changeInLength: -edit.length
        ))
    }
}
