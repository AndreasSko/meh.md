import XCTest

@testable import NativeEditor

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
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

#if os(iOS)
    func testKeyboardResizeKeepsPaddingOutOfCaretViewport() {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        textView.font = .systemFont(ofSize: 17)
        textView.text = (1...200).map { "Line \($0) of the note" }
            .joined(separator: "\n")
        let selection = NSRange(location: 900, length: 0)
        textView.selectedRange = selection

        // Model keyboard appearance and dismissal without depending on
        // the simulator's hardware-keyboard setting.
        for height: CGFloat in [706, 343, 706] {
            textView.frame = CGRect(x: 0, y: 0, width: 390, height: height)
            textView.setNeedsLayout()
            textView.layoutIfNeeded()
            textView.scrollRangeToVisible(selection)

            // UIKit treats scroll insets as obscured space when revealing
            // the caret. Document whitespace must not consume that space.
            XCTAssertEqual(textView.contentInset.bottom, 0)
            XCTAssertEqual(textView.adjustedContentInset.bottom, 0)
            XCTAssertEqual(textView.selectedRange, selection)
            let caret = textView.caretRect(for: textView.selectedTextRange!.start)
            XCTAssertGreaterThanOrEqual(caret.minY, textView.bounds.minY - 1)
            XCTAssertLessThanOrEqual(caret.maxY, textView.bounds.maxY + 1)
        }
    }

    func testScrollPastEndSurvivesKeyboardResize() {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        textView.font = .systemFont(ofSize: 17)
        textView.text = (1...200).map { "Line \($0) of the note" }
            .joined(separator: "\n")

        for height: CGFloat in [706, 343, 706] {
            textView.frame = CGRect(x: 0, y: 0, width: 390, height: height)
            textView.setNeedsLayout()
            textView.layoutIfNeeded()
            if let manager = textView.textLayoutManager,
               let content = manager.textContentManager {
                manager.ensureLayout(for: content.documentRange)
            }
            textView.scrollRangeToVisible(
                NSRange(location: textView.text.utf16.count, length: 0)
            )
            textView.setContentOffset(
                CGPoint(x: 0, y: textView.contentSize.height - height),
                animated: false
            )
            let caret = textView.caretRect(for: textView.endOfDocument)
            let spaceBelowText = textView.bounds.maxY - caret.maxY
            XCTAssertGreaterThanOrEqual(spaceBelowText, height / 2)
            XCTAssertLessThan(spaceBelowText, height)
        }
    }

    func testRotatingLongEditorKeepsLastLineReachable() throws {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        host.view.addSubview(textView)
        textView.frame = host.view.bounds
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textView.font = .systemFont(ofSize: 17)
        textView.text = (1...600).map {
            "Line \($0) has enough text to wrap differently after rotation."
        }.joined(separator: "\n")
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        host.view.layoutIfNeeded()
        let end = NSRange(location: textView.text.utf16.count, length: 0)
        textView.scrollRangeToVisible(end)

        window.frame.size = CGSize(width: 844, height: 390)
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        window.frame.size = CGSize(width: 390, height: 844)
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()

        let insets = textView.adjustedContentInset
        let maximumY = textView.contentSize.height - textView.bounds.height
            + insets.bottom
        textView.setContentOffset(
            CGPoint(x: 0, y: max(-insets.top, maximumY)),
            animated: false
        )
        let caret = textView.caretRect(for: textView.endOfDocument)

        XCTAssertLessThanOrEqual(caret.maxY, textView.bounds.maxY + 1)
        XCTAssertGreaterThanOrEqual(caret.minY, textView.bounds.minY - 1)
        XCTAssertEqual(
            textView.textContainerInset.bottom,
            18 + MarkdownEditorScrollPadding.bottom(for: textView.bounds.height)
        )
    }
#endif
}
