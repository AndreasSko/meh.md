import XCTest

@testable import NativeEditor

#if os(macOS)
import AppKit
#endif

@MainActor
final class MarkdownEditorScrollPaddingTests: XCTestCase {
    func testShortViewportUsesHalfHeightPadding() {
        XCTAssertEqual(
            MarkdownEditorScrollPadding.bottom(for: 80),
            40
        )
    }

    func testTallViewportLeavesFiniteSpaceBelowText() {
        XCTAssertEqual(
            MarkdownEditorScrollPadding.bottom(for: 600),
            300
        )
    }

    func testPaddingTracksViewportResize() {
        let compact = MarkdownEditorScrollPadding.bottom(for: 300)
        let expanded = MarkdownEditorScrollPadding.bottom(for: 700)

        XCTAssertEqual(expanded - compact, 200)
    }

#if os(macOS)
    func testMountedEditorScrollsLastLineNearMiddleWithFiniteExtent() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let scrollView = MarkdownEditorScrollView(frame: window.contentView!.bounds)
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.width, .height]
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        textView.string = (1...80).map { "Line \($0)" }.joined(separator: "\n")
        textView.font = .systemFont(ofSize: 17)
        textView.textContainerInset = NSSize(width: 22, height: 20)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        window.contentView?.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        try ensureTextKit2Layout(in: textView)

        XCTAssertEqual(textView.textContainerOrigin.y, 20)
        let firstHeight = textView.frame.height
        XCTAssertGreaterThan(firstHeight, scrollView.contentView.bounds.height)
        try assertLastLinePosition(in: scrollView, textView: textView)

        textView.insertText("\nAnother line", replacementRange: NSRange(
            location: (textView.string as NSString).length,
            length: 0
        ))
        try ensureTextKit2Layout(in: textView)
        scrollView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(textView.frame.height, firstHeight)
        try assertLastLinePosition(in: scrollView, textView: textView)

        window.setContentSize(NSSize(width: 320, height: 600))
        window.contentView?.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        try ensureTextKit2Layout(in: textView)

        XCTAssertEqual(textView.textContainerOrigin.y, 20)
        XCTAssertGreaterThan(textView.frame.height, firstHeight)
        try assertLastLinePosition(in: scrollView, textView: textView)
    }

    private func assertLastLinePosition(
        in scrollView: NSScrollView,
        textView: NSTextView
    ) throws {
        let maximumY = max(
            0,
            textView.frame.height - scrollView.contentView.bounds.height
        )
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: maximumY))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        let layoutManager = try XCTUnwrap(textView.textLayoutManager)
        let contentManager = try XCTUnwrap(layoutManager.textContentManager)
        var finalFragment: NSTextLayoutFragment?
        layoutManager.enumerateTextLayoutFragments(
            from: contentManager.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            finalFragment = fragment
            return true
        }
        let finalLineY = try XCTUnwrap(finalFragment).layoutFragmentFrame.minY
            + textView.textContainerOrigin.y
        let lineYInViewport = finalLineY
            - scrollView.contentView.bounds.minY

        XCTAssertEqual(
            lineYInViewport,
            scrollView.contentView.bounds.height / 2,
            accuracy: 40
        )
        XCTAssertLessThanOrEqual(
            scrollView.contentView.bounds.maxY,
            textView.frame.maxY + 0.5
        )
    }

    private func ensureTextKit2Layout(in textView: NSTextView) throws {
        let layoutManager = try XCTUnwrap(textView.textLayoutManager)
        layoutManager.ensureLayout(
            for: try XCTUnwrap(layoutManager.textContentManager).documentRange
        )
    }
#endif
}
