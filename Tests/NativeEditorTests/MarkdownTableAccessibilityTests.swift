import Foundation
import XCTest

@testable import NativeEditor

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class MarkdownTableAccessibilityTests: XCTestCase {
    func testModelExposesRenderedTextHeadersAndCellGeometry() throws {
        let source = "| Name | Value |\n"
            + "| :--- | ---: |\n"
            + "| café | **bright** |\n"
            + "| a\\|b |  |\n"
        let parsed = MarkdownSyntax.parse(source)
        let table = try XCTUnwrap(parsed.tables.first)
        let layout = MarkdownTableLayout.make(
            text: source, result: parsed, hiddenRanges: [table.range],
            bodyFont: bodyFont, width: 150
        )
        let frames = layout.rows.enumerated().map { index, row in
            CGRect(x: 0, y: CGFloat(index) * 42, width: 150, height: row.height)
        }
        let cells = MarkdownAccessibleTableCell.make(
            rows: layout.rows, frames: frames
        )

        XCTAssertEqual(cells.count, 6)
        XCTAssertEqual(cells.map { ($0.row, $0.column) }.map { "\($0.0),\($0.1)" },
                       ["0,0", "0,1", "1,0", "1,1", "2,0", "2,1"])
        XCTAssertEqual(cells[0].label, "Name")
        XCTAssertEqual(cells[2].label, "Name: café")
        XCTAssertEqual(cells[3].label, "Value: bright")
        XCTAssertEqual(cells[4].label, "Name: a|b")
        XCTAssertEqual(cells[5].label,
                       "Value: \(String(localized: "Empty cell"))")
        XCTAssertEqual(cells[3].text, "bright")
        XCTAssertEqual(cells[3].frame.minX, layout.rows[1].columnWidths[0])
        XCTAssertEqual(cells[3].frame.minY, frames[1].minY)
    }

#if os(macOS)
    func testMacNativeTableTreeAndScrollPreserveEditorState() throws {
        let source = "| One | Two | Three | Four |\n"
            + "| --- | --- | --- | --- |\n"
            + "| Alpha | Beta | Gamma | Delta |\n\nOutside"
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 150, height: 400))
        view.textContainer?.containerSize = NSSize(width: 150, height: 400)
        view.string = source
        let selection = (source as NSString).range(of: "Outside")
        view.setSelectedRange(selection)
        let window = NSWindow(
            contentRect: view.frame, styleMask: .borderless,
            backing: .buffered, defer: false
        )
        window.contentView = view
        MarkdownPresentation.configure(view, mode: .livePreview)
        view.updateMarkdownTableScrollOverlays()
        view.undoManager?.removeAllActions()

        let overlay = try XCTUnwrap(view.markdownTableScrollOverlays.first)
        let document = try XCTUnwrap(overlay.documentView)
        let table = try XCTUnwrap(document.accessibilityChildren()?.first
            as? NSAccessibilityElement)
        XCTAssertEqual(table.accessibilityRole(), .table)
        XCTAssertEqual(table.accessibilityRows()?.count, 2)
        XCTAssertEqual(table.accessibilityColumns()?.count, 4)
        let firstRow = try XCTUnwrap(table.accessibilityRows()?.first
            as? NSAccessibilityElement)
        let firstCell = try XCTUnwrap(firstRow.accessibilityChildren()?.first
            as? NSAccessibilityElement)
        XCTAssertEqual(firstCell.accessibilityRole(), .cell)
        XCTAssertEqual(firstCell.accessibilityLabel(), "One")
        XCTAssertEqual(firstCell.accessibilityRowIndexRange(),
                       NSRange(location: 0, length: 1))
        XCTAssertEqual(firstCell.accessibilityColumnIndexRange(),
                       NSRange(location: 0, length: 1))

        let tableFrame = table.accessibilityFrame()
        let cellFrame = firstCell.accessibilityFrame()
        XCTAssertGreaterThan(firstRow.accessibilityFrame().height, 0)
        XCTAssertTrue(overlay.scrollMarkdownTablePage(forward: true))
        XCTAssertEqual(table.accessibilityFrame(), tableFrame)
        XCTAssertLessThan(firstCell.accessibilityFrame().minX, cellFrame.minX)
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertFalse(view.undoManager?.canUndo == true)

        XCTAssertTrue(firstCell.accessibilityPerformPress())
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange().location,
                       (source as NSString).range(of: "One").location)
        XCTAssertFalse(view.undoManager?.canUndo == true)
    }
#endif

    private var bodyFont: PlatformFont {
#if os(macOS)
        NSFont.systemFont(ofSize: 16)
#else
        UIFont.systemFont(ofSize: 16)
#endif
    }
}
