import Foundation
import XCTest

@testable import NativeEditor

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class MarkdownWideTableLayoutTests: XCTestCase {
    private func layout(_ source: String, width: CGFloat,
                        font: PlatformFont = MarkdownPresentation.editorBodyFont
    ) throws -> MarkdownTableLayout {
        let parsed = MarkdownSyntax.parse(source)
        XCTAssertFalse(parsed.tables.isEmpty)
        return MarkdownTableLayout.make(
            text: source, result: parsed,
            hiddenRanges: parsed.tables.map(\.range),
            bodyFont: font, width: width
        )
    }

    func testCompactValuesUseLessWidthThanProseAndRowsAlign() throws {
        let source = "| ID | Description | Qty |\n"
            + "| --- | --- | ---: |\n"
            + "| 7 | A long description with several words that should wrap | 2 |\n"
            + "| 8 | More descriptive content | 12 |\n"
        let value = try layout(source, width: 430)
        XCTAssertEqual(value.rows.count, 3)
        let widths = try XCTUnwrap(value.rows.first?.columnWidths)
        XCTAssertEqual(widths.count, 3)
        XCTAssertGreaterThan(widths[1], widths[0])
        XCTAssertGreaterThan(widths[1], widths[2])
        XCTAssertTrue(value.rows.allSatisfy { $0.columnWidths == widths })
        XCTAssertLessThanOrEqual(try XCTUnwrap(value.contentWidth(
            for: value.rows[0].tableRange
        )), value.width)
    }

    func testSixColumnsOverflowWithoutDiscardingCells() throws {
        let source = "| A | B | C | D | E | F |\n"
            + "| --- | --- | --- | --- | --- | --- |\n"
            + "| one | two | three | four | five | six |\n"
        let value = try layout(source, width: 210)
        let header = try XCTUnwrap(value.rows.first)
        XCTAssertEqual(header.cells.map(\.string), ["A", "B", "C", "D", "E", "F"])
        XCTAssertEqual(value.rows[1].cells.map(\.string),
                       ["one", "two", "three", "four", "five", "six"])
        XCTAssertEqual(header.columnWidths.count, 6)
        XCTAssertTrue(header.columnWidths.allSatisfy { $0 >= 52 })
        XCTAssertGreaterThan(try XCTUnwrap(value.contentWidth(
            for: header.tableRange
        )), value.width)
        XCTAssertTrue(value.rows[1].isLast)
    }

    func testOverflowKeepsReadableColumnWidthsAndReservesIndicatorSpace() throws {
        let source = "| Item | Description |\n| --- | --- |\n"
            + "| x | A long description with many distinct words to wrap |\n"
        let wide = try layout(source, width: 700)
        let narrow = try layout(source, width: 110)
        XCTAssertEqual(narrow.rows[1].columnWidths, wide.rows[1].columnWidths)
        XCTAssertEqual(narrow.rows[1].height, wide.rows[1].height
                       + MarkdownTableLayout.scrollIndicatorHeight)
        XCTAssertGreaterThan(try XCTUnwrap(narrow.contentWidth(
            for: narrow.rows[0].tableRange
        )), narrow.width)
    }

    func testFontAndDegenerateViewportProduceFinitePositiveWidths() throws {
        let source = "| One | Two |\n| --- | --- |\n| value | value |\n"
        let standard = try layout(source, width: 300)
#if os(macOS)
        let largeFont = NSFont.systemFont(ofSize: 28)
#else
        let largeFont = UIFont.systemFont(ofSize: 28)
#endif
        let large = try layout(source, width: 300, font: largeFont)
        XCTAssertGreaterThan(large.rows[0].columnWidths[0],
                             standard.rows[0].columnWidths[0])
        for input in [CGFloat.zero, CGFloat.nan, CGFloat.infinity] {
            let value = try layout(source, width: input)
            XCTAssertTrue(value.width.isFinite)
            XCTAssertGreaterThan(value.width, 0)
            XCTAssertTrue(value.rows.flatMap(\.columnWidths).allSatisfy {
                $0.isFinite && $0 > 0
            })
        }
    }

    func testEachTableKeepsItsOwnContentWidth() throws {
        let source = "| A | B |\n| --- | --- |\n| 1 | 2 |\n\n"
            + "| One | Two | Three | Four |\n"
            + "| --- | --- | --- | --- |\n"
            + "| Alpha | Beta | Gamma | Delta |\n"
        let value = try layout(source, width: 250)
        XCTAssertEqual(value.rows.count, 4)
        let first = value.rows[0].tableRange
        let second = value.rows[2].tableRange
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(value.rows[1].tableRange, first)
        XCTAssertEqual(value.rows[3].tableRange, second)
        XCTAssertLessThan(try XCTUnwrap(value.contentWidth(for: first)),
                          try XCTUnwrap(value.contentWidth(for: second)))
        XCTAssertNil(value.contentWidth(for: NSRange(location: 999, length: 1)))
    }
}
