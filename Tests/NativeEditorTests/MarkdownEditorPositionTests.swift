import SwiftUI
import XCTest

@testable import NativeEditor

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

@MainActor
final class MarkdownEditorPositionTests: XCTestCase {
    func testPositionIsCodable() throws {
        let position = MarkdownEditorPosition(
            selection: NSRange(location: 7, length: 3),
            scrollAnchor: 41,
            scrollAnchorOffset: 12.5
        )

        let data = try JSONEncoder().encode(position)

        XCTAssertEqual(
            try JSONDecoder().decode(MarkdownEditorPosition.self, from: data),
            position
        )
    }

    func testCaptureAndRestorePreserveSelectionViewportAndEditorState()
        async throws {
        let lines = (0..<120).map { "Line \($0) with enough text for layout." }
        let source = lines.joined(separator: "\n")
        let navigation = MarkdownEditorNavigation()
        let mounted = mount(text: source, navigation: navigation)
        let textView = try XCTUnwrap(mounted.textView)
        defer { mounted.tearDown() }
        let selected = (source as NSString).range(of: lines[82])
        setSelection(selected, in: textView)
        scrollSelectionToVisible(in: textView)
        layout(mounted)
        #if os(macOS)
        // AppKit can finish a programmatic TextKit 2 viewport layout on the
        // next main-queue turn. Capture the settled viewport a user sees.
        await flushMainQueue()
        layout(mounted)
        #endif
        let originalOffset = verticalScrollOffset(in: textView)
        XCTAssertGreaterThan(originalOffset, 0)
        let position = try XCTUnwrap(navigation.capturePosition?())
        let undoManager = try XCTUnwrap(textView.undoManager)
        undoManager.removeAllActions()
        undoManager.registerUndo(withTarget: textView) { _ in }
        XCTAssertTrue(undoManager.canUndo)

        setSelection(NSRange(location: 0, length: 0), in: textView)
        setVerticalScrollOffset(0, in: textView)
        navigation.restorePosition?(position)
        await flushMainQueue()
        layout(mounted)
        await flushMainQueue()

        XCTAssertEqual(selectedRange(in: textView), selected)
        let restored = try XCTUnwrap(navigation.capturePosition?())
        XCTAssertEqual(restored.scrollAnchor, position.scrollAnchor)
        XCTAssertEqual(
            restored.scrollAnchorOffset,
            position.scrollAnchorOffset,
            accuracy: 1
        )
        XCTAssertGreaterThan(verticalScrollOffset(in: textView), 0)
        XCTAssertEqual(nativeText(in: textView), source)
        XCTAssertTrue(undoManager.canUndo)
        XCTAssertFalse(isFirstResponder(textView))
    }

    func testRestoreIntoFreshEditorPreservesReadingViewport() async throws {
        // A short note is fully laid out before restoration and does not
        // exercise TextKit 2's provisional content extent on relaunch.
        let lines = (1...600).map {
            "Moon log \($0) records a long observation that wraps on phones."
        }
        let source = lines.joined(separator: "\n")
        let captureNavigation = MarkdownEditorNavigation()
        #if os(iOS)
        let capturedEditor = mount(
            text: source,
            navigation: captureNavigation,
            size: CGSize(width: 402, height: 639)
        )
        #else
        let capturedEditor = mount(text: source, navigation: captureNavigation)
        #endif
        let capturedTextView = try XCTUnwrap(capturedEditor.textView)
        setSelection(
            NSRange(location: source.utf16.count, length: 0),
            in: capturedTextView
        )
        scrollSelectionToVisible(in: capturedTextView)
        layout(capturedEditor)
        #if os(iOS)
        setVerticalScrollOffset(6_000, in: capturedTextView)
        #else
        setVerticalScrollOffset(200, in: capturedTextView)
        #endif
        layout(capturedEditor)
        let position = try XCTUnwrap(captureNavigation.capturePosition?())
        capturedEditor.tearDown()

        let restoreNavigation = MarkdownEditorNavigation()
        #if os(iOS)
        let restoredEditor = mount(
            text: source,
            navigation: restoreNavigation,
            size: CGSize(width: 402, height: 639)
        )
        #else
        let restoredEditor = mount(text: source, navigation: restoreNavigation)
        #endif
        let restoredTextView = try XCTUnwrap(restoredEditor.textView)
        defer { restoredEditor.tearDown() }
        restoreNavigation.restorePosition?(position)
        await flushMainQueue()
        layout(restoredEditor)
        await flushMainQueue()

        XCTAssertEqual(
            selectedRange(in: restoredTextView),
            NSRange(location: source.utf16.count, length: 0)
        )
        let restored = try XCTUnwrap(restoreNavigation.capturePosition?())
        XCTAssertEqual(restored.scrollAnchor, position.scrollAnchor)
        XCTAssertEqual(
            restored.scrollAnchorOffset,
            position.scrollAnchorOffset,
            accuracy: 1
        )
        XCTAssertEqual(nativeText(in: restoredTextView), source)
        XCTAssertFalse(isFirstResponder(restoredTextView))
    }

    func testRestoreClampsMalformedUTF16RangesAndScrollValues()
        async throws {
        let source = "A😀B\n" + String(repeating: "More text\n", count: 80)
        let navigation = MarkdownEditorNavigation()
        let mounted = mount(text: source, navigation: navigation)
        let textView = try XCTUnwrap(mounted.textView)
        defer { mounted.tearDown() }
        textView.undoManager?.removeAllActions()
        let invalid = MarkdownEditorPosition(
            selection: NSRange(location: 2, length: Int.max),
            scrollAnchor: Int.max,
            scrollAnchorOffset: .infinity
        )

        navigation.restorePosition?(invalid)
        await flushMainQueue()
        layout(mounted)
        await flushMainQueue()

        let expected = (source as NSString)
            .rangeOfComposedCharacterSequences(
                for: NSRange(location: 1, length: source.utf16.count - 1)
            )
        XCTAssertEqual(selectedRange(in: textView), expected)
        XCTAssertTrue(verticalScrollOffset(in: textView).isFinite)
        XCTAssertGreaterThanOrEqual(verticalScrollOffset(in: textView), 0)
        XCTAssertEqual(nativeText(in: textView), source)
        XCTAssertFalse(textView.undoManager?.canUndo == true)
        XCTAssertFalse(isFirstResponder(textView))
    }

    func testRestoreWaitsForMarkedText() async throws {
        let navigation = MarkdownEditorNavigation()
        let mounted = mount(text: "hello", navigation: navigation)
        let textView = try XCTUnwrap(mounted.textView)
        defer { mounted.tearDown() }
        setSelection(NSRange(location: 5, length: 0), in: textView)
        setMarkedText("世界", in: textView)
        XCTAssertTrue(hasMarkedText(in: textView))
        XCTAssertNil(navigation.capturePosition?())

        navigation.restorePosition?(MarkdownEditorPosition(
            selection: NSRange(location: 0, length: 0),
            scrollAnchor: 0,
            scrollAnchorOffset: 0
        ))
        await flushMainQueue()

        XCTAssertTrue(hasMarkedText(in: textView))
        XCTAssertNotEqual(
            selectedRange(in: textView),
            NSRange(location: 0, length: 0)
        )

        unmarkText(in: textView)
        await flushMainQueue()
        await flushMainQueue()

        XCTAssertFalse(hasMarkedText(in: textView))
        XCTAssertEqual(
            selectedRange(in: textView),
            NSRange(location: 0, length: 0)
        )
    }

    private func flushMainQueue() async {
        let flushed = expectation(description: "main queue flushed")
        DispatchQueue.main.async { flushed.fulfill() }
        await fulfillment(of: [flushed], timeout: 1)
    }
}

#if os(macOS)
@MainActor
private extension MarkdownEditorPositionTests {
    typealias NativeTextView = NSTextView

    struct MountedEditor {
        let window: NSWindow
        let host: NSHostingView<MarkdownEditor>
        let textView: NSTextView?

        @MainActor func tearDown() {
            window.orderOut(nil)
        }
    }

    func mount(
        text: String,
        navigation: MarkdownEditorNavigation
    ) -> MountedEditor {
        _ = NSApplication.shared
        let editor = MarkdownEditor(
            text: .constant(text),
            navigation: navigation
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 260),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let host = NSHostingView(rootView: editor)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(host)
        host.layoutSubtreeIfNeeded()
        return MountedEditor(
            window: window,
            host: host,
            textView: findTextView(in: host)
        )
    }

    func layout(_ mounted: MountedEditor) {
        mounted.host.layoutSubtreeIfNeeded()
        mounted.window.displayIfNeeded()
    }

    func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let textView = findTextView(in: subview) { return textView }
        }
        return nil
    }

    func setSelection(_ range: NSRange, in textView: NSTextView) {
        textView.setSelectedRange(range)
    }

    func selectedRange(in textView: NSTextView) -> NSRange {
        textView.selectedRange()
    }

    func scrollSelectionToVisible(in textView: NSTextView) {
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    func verticalScrollOffset(in textView: NSTextView) -> CGFloat {
        textView.enclosingScrollView?.contentView.bounds.minY ?? 0
    }

    func setVerticalScrollOffset(_ offset: CGFloat, in textView: NSTextView) {
        guard let scrollView = textView.enclosingScrollView else { return }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func nativeText(in textView: NSTextView) -> String {
        textView.string
    }

    func isFirstResponder(_ textView: NSTextView) -> Bool {
        textView.window?.firstResponder === textView
    }

    func setMarkedText(_ text: String, in textView: NSTextView) {
        textView.setMarkedText(
            text,
            selectedRange: NSRange(location: text.utf16.count, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    func hasMarkedText(in textView: NSTextView) -> Bool {
        textView.hasMarkedText()
    }

    func unmarkText(in textView: NSTextView) {
        textView.unmarkText()
    }
}
#elseif os(iOS)
@MainActor
private extension MarkdownEditorPositionTests {
    typealias NativeTextView = UITextView

    struct MountedEditor {
        let window: UIWindow
        let host: UIHostingController<MarkdownEditor>
        let textView: UITextView?

        @MainActor func tearDown() {
            window.isHidden = true
        }
    }

    func mount(
        text: String,
        navigation: MarkdownEditorNavigation,
        size: CGSize = CGSize(width: 390, height: 844)
    ) -> MountedEditor {
        let editor = MarkdownEditor(
            text: .constant(text),
            navigation: navigation
        )
        let host = UIHostingController(rootView: editor)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return MountedEditor(
            window: window,
            host: host,
            textView: findTextView(in: host.view)
        )
    }

    func layout(_ mounted: MountedEditor) {
        mounted.host.view.setNeedsLayout()
        mounted.host.view.layoutIfNeeded()
    }

    func findTextView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView { return textView }
        for subview in view.subviews {
            if let textView = findTextView(in: subview) { return textView }
        }
        return nil
    }

    func setSelection(_ range: NSRange, in textView: UITextView) {
        textView.selectedRange = range
    }

    func selectedRange(in textView: UITextView) -> NSRange {
        textView.selectedRange
    }

    func scrollSelectionToVisible(in textView: UITextView) {
        textView.scrollRangeToVisible(textView.selectedRange)
    }

    func verticalScrollOffset(in textView: UITextView) -> CGFloat {
        textView.contentOffset.y
    }

    func setVerticalScrollOffset(_ offset: CGFloat, in textView: UITextView) {
        textView.setContentOffset(
            CGPoint(x: textView.contentOffset.x, y: offset),
            animated: false
        )
    }

    func nativeText(in textView: UITextView) -> String {
        textView.text
    }

    func isFirstResponder(_ textView: UITextView) -> Bool {
        textView.isFirstResponder
    }

    func setMarkedText(_ text: String, in textView: UITextView) {
        textView.setMarkedText(
            text,
            selectedRange: NSRange(location: text.utf16.count, length: 0)
        )
    }

    func hasMarkedText(in textView: UITextView) -> Bool {
        textView.markedTextRange != nil
    }

    func unmarkText(in textView: UITextView) {
        textView.unmarkText()
    }
}
#endif
