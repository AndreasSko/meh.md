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
        XCTAssertNil(view.scrollableMarkdownTable(at: CGPoint(x: -10, y: 50)))
        XCTAssertNil(view.scrollableMarkdownTable(at: CGPoint(x: 500, y: 50)))

        MarkdownPresentation.refresh(view, mode: .source)
        XCTAssertNil(view.scrollableMarkdownTable(at: CGPoint(x: 50, y: 50)))
    }

    func testNativeHitTestingFindsOverflowRowButNotOrdinaryProse() throws {
        let source = table + "\nOutside"
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 150, height: 400))
        view.textContainer?.containerSize = NSSize(width: 150, height: 400)
        view.string = source
        view.setSelectedRange((source as NSString).range(of: "Outside"))
        MarkdownPresentation.configure(view, mode: .livePreview)
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
        let wideLayout = try XCTUnwrap(view.markdownSyntaxCache.tableLayout)
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(wideLayout.contentWidth(for: firstRow.tableRange)),
            wideLayout.width
        )
        XCTAssertNil(view.scrollableMarkdownTable(at: hit))
    }

    func testHorizontalWheelEventScrollsOnlyOverOverflowTable() throws {
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
        let row = try XCTUnwrap(view.markdownSyntaxCache.tableLayout?.rows.first)
        let manager = try XCTUnwrap(view.textLayoutManager)
        let content = try XCTUnwrap(manager.textContentManager)
        manager.textViewportLayoutController.layoutViewport()
        var rowY: CGFloat?
        manager.enumerateTextLayoutFragments(
            from: content.documentRange.location, options: [.ensuresLayout]
        ) { fragment in
            let location = content.offset(
                from: content.documentRange.location,
                to: fragment.rangeInElement.location
            )
            if location == row.range.location {
                rowY = fragment.layoutFragmentFrame.minY + min(row.height / 2, 10)
                return false
            }
            return true
        }
        let hit = CGPoint(
            x: view.textContainerOrigin.x
                + (view.textContainer?.lineFragmentPadding ?? 0) + 20,
            y: view.textContainerOrigin.y + (try XCTUnwrap(rowY))
        )
        XCTAssertEqual(view.scrollableMarkdownTable(at: hit), row.tableRange)

        func wheel(deltaX: Int32, deltaY: Int32) throws -> NSEvent {
            let event = try XCTUnwrap(CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                wheel1: deltaY, wheel2: deltaX, wheel3: 0
            ))
            event.location = view.convert(hit, to: nil)
            let probe = try XCTUnwrap(NSEvent(cgEvent: event))
            let desired = view.convert(hit, to: nil)
            // A synthetic CGEvent has no target window. Normalize the screen
            // coordinate so AppKit reports the desired window location.
            event.location.y -= desired.y - probe.locationInWindow.y
            return try XCTUnwrap(NSEvent(cgEvent: event))
        }
        let horizontal = try wheel(deltaX: -35, deltaY: 0)
        XCTAssertEqual(view.convert(horizontal.locationInWindow, from: nil).x,
                       hit.x, accuracy: 0.5)
        XCTAssertEqual(view.convert(horizontal.locationInWindow, from: nil).y,
                       hit.y, accuracy: 0.5)
        XCTAssertTrue(view.scrollMarkdownTable(with: horizontal))
        XCTAssertGreaterThan(
            view.markdownSyntaxCache.tableHorizontalOffsets[row.tableRange, default: 0],
            0
        )
        let offset = view.markdownSyntaxCache.tableHorizontalOffsets[row.tableRange]
        XCTAssertFalse(view.scrollMarkdownTable(with: try wheel(
            deltaX: 0, deltaY: -35
        )))
        XCTAssertEqual(view.markdownSyntaxCache.tableHorizontalOffsets[row.tableRange],
                       offset)
        XCTAssertEqual(view.string, source)
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
