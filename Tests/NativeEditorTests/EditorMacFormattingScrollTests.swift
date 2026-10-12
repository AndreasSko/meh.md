import XCTest

@testable import NativeEditor

#if os(macOS)
import AppKit

@MainActor
final class EditorMacFormattingScrollTests: XCTestCase {
    func testInitialViewportStartsAtBeginningAndLaterLayoutKeepsWheelPosition() throws {
        _ = NSApplication.shared
        let scroll = EditorMacFormattingScrollView(frame: .zero)
        scroll.documentView = NSView(frame: NSRect(
            x: 0, y: 0, width: 700, height: 36
        ))
        scroll.layout()
        scroll.setFrameSize(NSSize(width: 368, height: 36))
        scroll.tile()
        // Model AppKit retaining the trailing content during bridge mounting.
        scroll.contentView.scroll(to: NSPoint(x: 150, y: 0))
        scroll.layout()
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.5)

        try sendWheel(to: scroll, units: .line, vertical: -2)
        let position = scroll.contentView.bounds.minX
        XCTAssertGreaterThan(position, 0)
        scroll.layout()
        XCTAssertEqual(scroll.contentView.bounds.minX, position, accuracy: 0.5)
        scroll.setFrameSize(NSSize(width: 320, height: 36))
        scroll.tile()
        scroll.layout()
        XCTAssertEqual(scroll.contentView.bounds.minX, position, accuracy: 0.5)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0)
    }

    func testOrdinaryWheelMovesAcrossCommandsAndBack() throws {
        let scroll = makeScrollView()
        try sendWheel(to: scroll, units: .line, vertical: -1)
        let forward = scroll.contentView.bounds.minX
        XCTAssertGreaterThan(forward, 0)
        XCTAssertLessThan(forward, scroll.documentView!.frame.width)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0)

        try sendWheel(to: scroll, units: .line, vertical: 1)
        XCTAssertLessThan(scroll.contentView.bounds.minX, forward)
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.5)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0)
    }

    func testOrdinaryWheelStopsAtBothContentEdges() throws {
        let scroll = makeScrollView()
        try sendWheel(to: scroll, units: .line, vertical: -1000)
        XCTAssertEqual(scroll.contentView.documentVisibleRect.maxX,
                       scroll.documentView!.frame.maxX, accuracy: 0.5)
        let end = scroll.contentView.bounds.minX
        try sendWheel(to: scroll, units: .line, vertical: -1000)
        XCTAssertEqual(scroll.contentView.bounds.minX, end, accuracy: 0.5)

        try sendWheel(to: scroll, units: .line, vertical: 1000)
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.5)
        try sendWheel(to: scroll, units: .line, vertical: 1000)
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.5)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0)
    }

    func testPreciseVerticalWheelMovesByPixelsWithoutVerticalDrift() throws {
        let scroll = makeScrollView()
        try sendWheel(to: scroll, units: .pixel, vertical: -12)
        let forward = scroll.contentView.bounds.minX
        XCTAssertGreaterThan(forward, 0)
        XCTAssertLessThan(forward, 36,
                          "Precise input must not be amplified to whole cells")
        XCTAssertEqual(scroll.contentView.bounds.minY, 0)
        try sendWheel(to: scroll, units: .pixel, vertical: 12)
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.5)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0)
    }

    func testPreciseHorizontalAndDiagonalInputUsesHorizontalDelta() throws {
        let horizontal = makeScrollView()
        try sendWheel(to: horizontal, units: .pixel,
                      vertical: 0, horizontal: -20)
        let position = horizontal.contentView.bounds.minX
        XCTAssertEqual(position, 20, accuracy: 0.5)

        let diagonal = makeScrollView()
        try sendWheel(to: diagonal, units: .pixel,
                      vertical: -100, horizontal: -20)
        XCTAssertEqual(diagonal.contentView.bounds.minX, position, accuracy: 0.5,
                       "Vertical motion must not amplify a horizontal gesture")
        XCTAssertEqual(diagonal.contentView.bounds.minY, 0)
        try sendWheel(to: diagonal, units: .pixel,
                      vertical: -100, horizontal: 20)
        XCTAssertEqual(diagonal.contentView.bounds.minX, 0, accuracy: 0.5)
        XCTAssertEqual(diagonal.contentView.bounds.minY, 0)
    }

    func testCoarseHorizontalWheelMovesAcrossCellsAndBack() throws {
        let scroll = makeScrollView()
        try sendWheel(to: scroll, units: .line,
                      vertical: 0, horizontal: -1)
        let position = scroll.contentView.bounds.minX
        XCTAssertGreaterThan(position, 1,
                             "Ordinary wheel lines must move farther than a pixel")
        XCTAssertLessThan(position, 64)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0)
        try sendWheel(to: scroll, units: .line,
                      vertical: 0, horizontal: 1)
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.5)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0)
    }

    private func makeScrollView() -> EditorMacFormattingScrollView {
        _ = NSApplication.shared
        let scroll = EditorMacFormattingScrollView(frame: NSRect(
            x: 0, y: 0, width: 368, height: 36
        ))
        scroll.documentView = NSView(frame: NSRect(
            x: 0, y: 0, width: 700, height: 36
        ))
        scroll.tile()
        scroll.layout()
        return scroll
    }

    private func sendWheel(
        to scroll: EditorMacFormattingScrollView,
        units: CGScrollEventUnit, vertical: Int32, horizontal: Int32 = 0
    ) throws {
        let event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil, units: units, wheelCount: 2,
            wheel1: vertical, wheel2: horizontal, wheel3: 0
        ))
        let wheel = try XCTUnwrap(NSEvent(cgEvent: event))
        XCTAssertEqual(wheel.hasPreciseScrollingDeltas, units == .pixel)
        scroll.scrollWheel(with: wheel)
    }
}
#endif
