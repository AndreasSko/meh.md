import Foundation
import XCTest

@testable import NativeEditor

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class MarkdownTableScrollingTests: XCTestCase {
    private let table = "| One | Two | Three | Four |\n"
        + "| --- | --- | --- | --- |\n"
        + "| Alpha | Beta | Gamma | Delta |\n"

    func testOffsetClampsAndDoesNotChangeLayoutGeometry() throws {
        let source = table + "\nOutside"
        let cache = MarkdownSyntaxCache()
        let range = try prepare(cache, source: source, width: 120)[0]
        let layout = try XCTUnwrap(cache.tableLayout)
        let contentWidth = try XCTUnwrap(layout.contentWidth(for: range))
        let maximum = contentWidth - layout.width
        XCTAssertGreaterThan(maximum, 0)

        XCTAssertFalse(cache.setTableHorizontalOffset(0, for: range))
        XCTAssertTrue(cache.setTableHorizontalOffset(maximum + 1_000, for: range))
        XCTAssertEqual(cache.tableHorizontalOffsets[range, default: 0], maximum,
                       accuracy: 0.01)
        XCTAssertFalse(cache.setTableHorizontalOffset(maximum + 1, for: range))
        XCTAssertTrue(cache.setTableHorizontalOffset(-100, for: range))
        XCTAssertEqual(cache.tableHorizontalOffsets[range], 0)
        XCTAssertFalse(cache.setTableHorizontalOffset(.infinity, for: range))
        XCTAssertFalse(cache.setTableHorizontalOffset(25, for: NSRange(
            location: range.location + 1, length: range.length
        )))
        XCTAssertEqual(cache.tableLayout?.width, layout.width)
        XCTAssertEqual(cache.tableLayout?.rows.map(\.height), layout.rows.map(\.height))
    }

    func testUnrelatedSourceShiftRetainsOffsetAndTableEditResetsIt() throws {
        let source = table + "\nOutside"
        let cache = MarkdownSyntaxCache()
        let original = try prepare(cache, source: source, width: 120)[0]
        XCTAssertTrue(cache.setTableHorizontalOffset(43, for: original))

        let shifted = "Intro\n\n" + source
        let moved = try prepare(cache, source: shifted, width: 120)[0]
        XCTAssertNotEqual(moved, original)
        XCTAssertNil(cache.tableHorizontalOffsets[original])
        XCTAssertEqual(cache.tableHorizontalOffsets[moved], 43)

        let edited = shifted.replacingOccurrences(of: "Alpha", with: "Alpine")
        let changed = try prepare(cache, source: edited, width: 120)[0]
        XCTAssertEqual(cache.tableHorizontalOffsets[changed, default: 0], 0)
    }

    func testResizeClampsOffsetAndIndependentTablesKeepTheirPositions() throws {
        let source = table + "\nMiddle\n\n" + table + "\nOutside"
        let cache = MarkdownSyntaxCache()
        let ranges = try prepare(cache, source: source, width: 120)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertTrue(cache.setTableHorizontalOffset(80, for: ranges[0]))
        XCTAssertTrue(cache.setTableHorizontalOffset(35, for: ranges[1]))

        let wider = try prepare(cache, source: source, width: 185)
        let layout = try XCTUnwrap(cache.tableLayout)
        let limit = try XCTUnwrap(layout.contentWidth(for: wider[0])) - layout.width
        XCTAssertEqual(cache.tableHorizontalOffsets[wider[0], default: 0],
                       min(80, limit),
                       accuracy: 0.01)
        XCTAssertEqual(cache.tableHorizontalOffsets[wider[1], default: 0],
                       min(35, limit),
                       accuracy: 0.01)

        let changed = source.replacingOccurrences(of: "Alpha", with: "Alpine",
            range: source.range(of: "Alpha"))
        let afterEdit = try prepare(cache, source: changed, width: 120)
        XCTAssertEqual(cache.tableHorizontalOffsets[afterEdit[0], default: 0], 0)
        XCTAssertEqual(cache.tableHorizontalOffsets[afterEdit[1], default: 0],
                       min(35, limit), accuracy: 0.01)
    }

    func testActiveSourceTableHasNoRenderedRowsOrScrollOffset() throws {
        let source = table + "\nOutside"
        let cache = MarkdownSyntaxCache()
        let range = try prepare(cache, source: source, width: 120)[0]
        XCTAssertTrue(cache.setTableHorizontalOffset(30, for: range))

        let active = cache.presentation(for: source, snapshot: snapshot(
            source: source, width: 120, selection: "Alpha"
        ))
        XCTAssertNotNil(cache.prepareTables(
            text: source, presentation: active,
            bodyFont: MarkdownPresentation.editorBodyFont, width: 120
        ))
        XCTAssertTrue(cache.tableLayout?.rows.isEmpty == true)
        XCTAssertFalse(cache.setTableHorizontalOffset(40, for: range))
    }

#if os(macOS)
    func testNativeOffsetPreservesSourceSelectionUndoAndViewportWidth() throws {
        let source = table + "\nOutside"
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 150, height: 400))
        view.textContainer?.containerSize = NSSize(width: 150, height: 400)
        view.allowsUndo = true
        view.string = source
        let selection = (source as NSString).range(of: "Outside")
        view.setSelectedRange(selection)
        MarkdownPresentation.configure(view, mode: .livePreview)
        view.undoManager?.removeAllActions()

        let range = try XCTUnwrap(view.markdownSyntaxCache.tableLayout?.rows.first?.tableRange)
        let containerWidth = try XCTUnwrap(view.textContainer?.containerSize.width)
        let frameWidth = view.frame.width
        XCTAssertTrue(view.setMarkdownTableHorizontalOffset(25, for: range))
        XCTAssertEqual(view.markdownSyntaxCache.tableHorizontalOffsets[range], 25)
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertFalse(view.undoManager?.canUndo == true)
        XCTAssertEqual(view.textContainer?.containerSize.width, containerWidth)
        XCTAssertEqual(view.frame.width, frameWidth)
    }

    func testNativeHitTestingRejectsOutsideAndSourceMode() throws {
        let source = table + "\nOutside"
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 150, height: 400))
        view.textContainer?.containerSize = NSSize(width: 150, height: 400)
        view.string = source
        view.setSelectedRange((source as NSString).range(of: "Outside"))
        MarkdownPresentation.configure(view, mode: .livePreview)
        view.updateMarkdownTableScrollOverlays()
        XCTAssertNil(view.scrollableMarkdownTable(at: CGPoint(x: -10, y: 50)))
        XCTAssertNil(view.scrollableMarkdownTable(at: CGPoint(x: 500, y: 50)))

        MarkdownPresentation.refresh(view, mode: .source)
        view.updateMarkdownTableScrollOverlays()
        XCTAssertNil(view.scrollableMarkdownTable(at: CGPoint(x: 50, y: 50)))
        XCTAssertTrue(view.markdownTableScrollOverlays.isEmpty)
    }

    func testNativeHitTestingFindsOverflowRowButNotOrdinaryProse() throws {
        let source = table + "\nOutside"
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 150, height: 400))
        view.textContainer?.containerSize = NSSize(width: 150, height: 400)
        view.string = source
        view.setSelectedRange((source as NSString).range(of: "Outside"))
        MarkdownPresentation.configure(view, mode: .livePreview)
        view.updateMarkdownTableScrollOverlays()
        let layout = try XCTUnwrap(view.markdownSyntaxCache.tableLayout)
        let firstRow = try XCTUnwrap(layout.rows.first)
        XCTAssertGreaterThan(firstRow.contentWidth, layout.width)
        let manager = try XCTUnwrap(view.textLayoutManager)
        let content = try XCTUnwrap(manager.textContentManager)
        manager.textViewportLayoutController.layoutViewport()
        var rowY: CGFloat?
        var proseY: CGFloat?
        manager.enumerateTextLayoutFragments(
            from: content.documentRange.location, options: [.ensuresLayout]
        ) { fragment in
            let location = content.offset(
                from: content.documentRange.location,
                to: fragment.rangeInElement.location
            )
            if location == firstRow.range.location {
                rowY = fragment.layoutFragmentFrame.minY
                    + min(firstRow.height / 2, 10)
            }
            if location == (source as NSString).range(of: "Outside").location {
                proseY = fragment.layoutFragmentFrame.midY
            }
            return proseY == nil
        }
        let x = view.textContainerOrigin.x
            + (view.textContainer?.lineFragmentPadding ?? 0) + 20
        let hit = CGPoint(x: x, y: view.textContainerOrigin.y
            + (try XCTUnwrap(rowY)))
        XCTAssertEqual(view.scrollableMarkdownTable(at: hit), firstRow.tableRange)
        XCTAssertNil(view.scrollableMarkdownTable(at: CGPoint(
            x: x, y: view.textContainerOrigin.y + (try XCTUnwrap(proseY))
        )))

        view.textContainer?.containerSize = NSSize(width: 500, height: 400)
        MarkdownPresentation.refresh(view, mode: .livePreview)
        view.updateMarkdownTableScrollOverlays()
        let wideLayout = try XCTUnwrap(view.markdownSyntaxCache.tableLayout)
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(wideLayout.contentWidth(for: firstRow.tableRange)),
            wideLayout.width
        )
        XCTAssertNil(view.scrollableMarkdownTable(at: hit))
        XCTAssertFalse(try XCTUnwrap(view.markdownTableScrollOverlays.first).hasHorizontalScroller)
        XCTAssertEqual(view.markdownTableScrollOverlays.count, 1,
                       "Nonoverflow tables still expose native table geometry")
    }

    func testNativeOverlayScrollsWithoutChangingSourceOrUndo() throws {
        let source = table + "\nOutside"
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 150, height: 400))
        view.textContainer?.containerSize = NSSize(width: 150, height: 400)
        view.string = source
        view.setSelectedRange((source as NSString).range(of: "Outside"))
        let window = NSWindow(
            contentRect: view.frame, styleMask: .borderless,
            backing: .buffered, defer: false
        )
        window.contentView = view
        MarkdownPresentation.configure(view, mode: .livePreview)
        view.updateMarkdownTableScrollOverlays()
        view.undoManager?.removeAllActions()
        let overlay = try XCTUnwrap(view.markdownTableScrollOverlays.first)
        XCTAssertTrue(overlay.hasHorizontalScroller)
        XCTAssertFalse(overlay.hasVerticalScroller)
        XCTAssertGreaterThan(try XCTUnwrap(overlay.documentView).frame.width,
                             overlay.bounds.width)
        XCTAssertTrue(overlay.scrollMarkdownTablePage(forward: true))
        XCTAssertGreaterThan(
            view.markdownSyntaxCache.tableHorizontalOffsets[
                overlay.tableRange, default: 0
            ],
            0
        )
        XCTAssertEqual(view.markdownTableDrawingOffsets[overlay.tableRange],
                       overlay.elasticHorizontalOffset)
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(),
                       (source as NSString).range(of: "Outside"))
        XCTAssertFalse(view.undoManager?.canUndo == true)

        overlay.revealMarkdownTableCell(row: 1, column: 2)
        XCTAssertEqual(view.selectedRange().location,
                       (source as NSString).range(of: "Gamma").location)
        XCTAssertEqual(view.string, source)
        XCTAssertFalse(view.undoManager?.canUndo == true)
        MarkdownPresentation.refresh(view, mode: .livePreview)
        view.updateMarkdownTableScrollOverlays()
        XCTAssertTrue(view.markdownTableScrollOverlays.isEmpty,
                      "Selecting a cell reveals the editable Markdown table")
    }

    func testVerticalWheelOverTableRoutesToNoteScrollView() throws {
        let source = table + "\nOutside\n" + String(repeating: "More\n", count: 40)
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 150, height: 600))
        view.textContainer?.containerSize = NSSize(width: 150, height: 600)
        view.string = source
        view.setSelectedRange((source as NSString).range(of: "Outside"))
        let noteScroller = WheelRoutingSpy(frame: NSRect(
            x: 0, y: 0, width: 150, height: 120
        ))
        noteScroller.documentView = view
        MarkdownPresentation.configure(view, mode: .livePreview)
        view.updateMarkdownTableScrollOverlays()
        let overlay = try XCTUnwrap(view.markdownTableScrollOverlays.first)
        let event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
            wheel1: -35, wheel2: 0, wheel3: 0
        ))
        let wheel = try XCTUnwrap(NSEvent(cgEvent: event))
        overlay.scrollWheel(with: wheel)
        XCTAssertEqual(noteScroller.wheelEvents, 1)
        XCTAssertEqual(view.markdownSyntaxCache.tableHorizontalOffsets[
            overlay.tableRange, default: 0
        ], 0)
        XCTAssertEqual(view.string, source)
    }

    func testTapOnPaddedBlankCellRevealsSourceRow() throws {
        let source = "| One | Two | Three | Four |\n"
            + "| --- | --- | --- | --- |\n"
            + "| Alpha | Beta |\n\nOutside"
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 150, height: 400))
        view.textContainer?.containerSize = NSSize(width: 150, height: 400)
        view.string = source
        view.setSelectedRange((source as NSString).range(of: "Outside"))
        MarkdownPresentation.configure(view, mode: .livePreview)
        view.updateMarkdownTableScrollOverlays()
        let overlay = try XCTUnwrap(view.markdownTableScrollOverlays.first)
        let rowStart = (source as NSString).range(of: "| Alpha").location
        XCTAssertTrue(overlay.revealMarkdownTableCell(row: 1, column: 3))
        XCTAssertEqual(view.selectedRange().location, rowStart)
        XCTAssertEqual(view.string, source)
    }

    func testAccessibilityCellRevealScrollsNoteWithoutEditing() throws {
        let source = String(repeating: "Intro\n", count: 30)
            + "\n" + table + "\nOutside"
        let view = MarkdownTextView(frame: NSRect(
            x: 0, y: 0, width: 150, height: 1_200
        ))
        view.textContainer?.containerSize = NSSize(width: 150, height: 1_200)
        view.string = source
        let selection = (source as NSString).range(of: "Outside")
        view.setSelectedRange(selection)
        let noteScroller = NSScrollView(frame: NSRect(
            x: 0, y: 0, width: 150, height: 110
        ))
        noteScroller.documentView = view
        let window = NSWindow(contentRect: noteScroller.frame,
                              styleMask: .borderless, backing: .buffered,
                              defer: false)
        window.contentView = noteScroller
        MarkdownPresentation.configure(view, mode: .livePreview)
        view.updateMarkdownTableScrollOverlays()
        view.undoManager?.removeAllActions()
        let overlay = try XCTUnwrap(view.markdownTableScrollOverlays.first)
        let lastRow = try XCTUnwrap(overlay.rowFrames.last)
        let cell = CGRect(x: 0, y: lastRow.minY,
                          width: 20, height: lastRow.height)
        let noteCellFrame = CGRect(
            x: overlay.frame.minX, y: overlay.frame.minY + cell.minY,
            width: overlay.bounds.width, height: cell.height
        )
        noteScroller.contentView.scroll(to: .zero)
        noteScroller.reflectScrolledClipView(noteScroller.contentView)
        XCTAssertFalse(noteScroller.contentView.bounds.intersects(noteCellFrame))
        overlay.revealMarkdownTableCellFrame(cell)
        XCTAssertTrue(noteScroller.contentView.bounds.intersects(noteCellFrame))
        XCTAssertEqual(overlay.elasticHorizontalOffset, 0)
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertEqual(view.string, source)
        XCTAssertFalse(view.undoManager?.canUndo == true)

        let matches = (view.accessibilityChildren() ?? []).filter {
            ($0 as AnyObject) === overlay
        }
        XCTAssertEqual(matches.count, 1)
    }
#endif

    @discardableResult
    private func prepare(
        _ cache: MarkdownSyntaxCache, source: String, width: CGFloat
    ) throws -> [NSRange] {
        let presentation = cache.presentation(for: source, snapshot: snapshot(
            source: source, width: width, selection: "Outside"
        ))
        _ = cache.prepareTables(
            text: source, presentation: presentation,
            bodyFont: MarkdownPresentation.editorBodyFont, width: width
        )
        let ranges = presentation.result.tables.map(\.range)
        XCTAssertFalse(ranges.isEmpty)
        return ranges
    }

    private func snapshot(
        source: String, width: CGFloat, selection: String
    ) -> MarkdownLivePreviewSnapshot {
        MarkdownLivePreviewSnapshot(
            mode: .livePreview,
            selection: (source as NSString).range(of: selection),
            tableWidth: width
        )
    }
}

#if os(macOS)
private final class WheelRoutingSpy: NSScrollView {
    var wheelEvents = 0
    override func scrollWheel(with event: NSEvent) { wheelEvents += 1 }
}
#endif
