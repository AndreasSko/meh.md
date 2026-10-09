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

    #if os(macOS)
    func testFreshRestorePreservesNativeInsetAtTopMiddleAndBottom()
        async throws {
        let source = (0..<120).map { "Fictional observation \($0)." }
            .joined(separator: "\n")
        for requestedOffset: CGFloat in [-52, 200, 100_000] {
            try await assertFreshInsetRestore(
                source: source, requestedOffset: requestedOffset,
                expectedOffset: requestedOffset < 1_000
                    ? requestedOffset : nil
            )
        }
    }

    func testFreshShortNoteRestoreKeepsNativeTitleSpace() async throws {
        let source = "# Fictional voyage\n\nSample checklist.\n"
        try await assertFreshInsetRestore(
            source: source, requestedOffset: -52, expectedOffset: -52
        )
    }

    private func assertFreshInsetRestore(
        source: String, requestedOffset: CGFloat, expectedOffset: CGFloat?
    ) async throws {
        let selection = NSRange(location: 7, length: 3)
        let captureNavigation = MarkdownEditorNavigation()
        // These regressions use a real native editor in an unordered
        // window. They do not take focus or control the desktop pointer.
        let original = mount(
            text: source, navigation: captureNavigation, showWindow: false
        )
        defer { original.tearDown() }
        let originalView = try XCTUnwrap(original.textView)
        let originalScroll = try XCTUnwrap(originalView.enclosingScrollView)
        originalScroll.automaticallyAdjustsContentInsets = false
        originalScroll.contentInsets = NSEdgeInsets(
            top: 52, left: 0, bottom: 0, right: 0
        )
        try await settleInsetEditor(original)
        setSelection(selection, in: originalView)
        var proposedBounds = originalScroll.contentView.bounds
        proposedBounds.origin.y = requestedOffset
        let originalOffset = originalScroll.contentView
            .constrainBoundsRect(proposedBounds).minY
        setVerticalScrollOffset(originalOffset, in: originalView)
        try await settleInsetEditor(original)
        if let expectedOffset {
            XCTAssertEqual(originalOffset, expectedOffset, accuracy: 1)
        } else {
            XCTAssertGreaterThan(originalOffset, 200)
        }
        XCTAssertEqual(
            verticalScrollOffset(in: originalView), originalOffset, accuracy: 1
        )
        let position = try XCTUnwrap(captureNavigation.capturePosition?())
        original.tearDown()

        let restoreNavigation = MarkdownEditorNavigation()
        let incoming = mount(
            text: source, navigation: restoreNavigation, showWindow: false
        )
        defer { incoming.tearDown() }
        let incomingView = try XCTUnwrap(incoming.textView)
        let incomingScroll = try XCTUnwrap(incomingView.enclosingScrollView)
        incomingScroll.automaticallyAdjustsContentInsets = false
        incomingScroll.contentInsets = NSEdgeInsets(
            top: 52, left: 0, bottom: 0, right: 0
        )
        try await settleInsetEditor(incoming)
        setSelection(NSRange(location: 0, length: 0), in: incomingView)
        restoreNavigation.restorePosition?(position)
        // Restoration defers its bounded retries until TextKit has laid out
        // the requested anchor in the newly mounted editor.
        for _ in 0..<4 {
            await flushMainQueue()
            layout(incoming)
        }

        XCTAssertEqual(
            verticalScrollOffset(in: incomingView), originalOffset, accuracy: 1,
            "Captured \(position); original visible \(originalView.visibleRect); "
                + "incoming visible \(incomingView.visibleRect)"
        )
        XCTAssertEqual(selectedRange(in: incomingView), selection)
        XCTAssertEqual(nativeText(in: incomingView), source)
        XCTAssertFalse(isFirstResponder(incomingView))
        let restored = try XCTUnwrap(restoreNavigation.capturePosition?())
        XCTAssertEqual(restored.scrollAnchor, position.scrollAnchor)
        XCTAssertEqual(
            restored.scrollAnchorOffset, position.scrollAnchorOffset, accuracy: 1
        )
    }

    private func settleInsetEditor(_ mounted: MountedEditor) async throws {
        let textView = try XCTUnwrap(mounted.textView)
        let layoutManager = try XCTUnwrap(textView.textLayoutManager)
        let contentManager = try XCTUnwrap(layoutManager.textContentManager)
        layoutManager.ensureLayout(for: contentManager.documentRange)
        for _ in 0..<2 {
            layout(mounted)
            await flushMainQueue()
        }
    }
    #endif

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

    #if os(iOS)
    func testDestinationRevealAcknowledgesCanceledRestorationOnce() async throws {
        let navigation = MarkdownEditorNavigation()
        let mounted = mount(text: "Fictional first line\nSecond line", navigation: navigation)
        defer { mounted.tearDown() }
        let position = try XCTUnwrap(navigation.capturePosition?())
        var completionCount = 0
        let restore = try XCTUnwrap(navigation.restorePositionAndNotify)
        restore(position) { completionCount += 1 }
        navigation.revealSearchMatch?(NSRange(location: 0, length: 0))
        XCTAssertEqual(completionCount, 1)
        await flushMainQueue()
        await flushMainQueue()
        XCTAssertEqual(completionCount, 1)
    }

    func testRestorationCompletionWaitsForFreshEditorViewport() async throws {
        let source = (0..<180).map {
            "Fictional observation \($0) with enough text to wrap."
        }.joined(separator: "\n")
        let originalNavigation = MarkdownEditorNavigation()
        let original = mount(text: source, navigation: originalNavigation)
        let originalView = try XCTUnwrap(original.textView)
        setSelection(NSRange(location: source.utf16.count, length: 0), in: originalView)
        scrollSelectionToVisible(in: originalView)
        layout(original)
        await flushMainQueue()
        setVerticalScrollOffset(1_600, in: originalView)
        layout(original)
        let position = try XCTUnwrap(originalNavigation.capturePosition?())
        original.tearDown()

        let navigation = MarkdownEditorNavigation()
        let incoming = mount(text: source, navigation: navigation)
        let incomingView = try XCTUnwrap(incoming.textView)
        defer { incoming.tearDown() }
        let restore = try XCTUnwrap(navigation.restorePositionAndNotify)
        let completed = expectation(description: "Restored viewport is ready for display")
        var completionCount = 0
        restore(position) {
            completionCount += 1
            let restored = navigation.capturePosition?()
            XCTAssertEqual(restored?.scrollAnchor, position.scrollAnchor)
            XCTAssertEqual(restored?.scrollAnchorOffset ?? .infinity,
                           position.scrollAnchorOffset, accuracy: 1)
            XCTAssertGreaterThan(incomingView.contentOffset.y, 0)
            XCTAssertFalse(incomingView.isFirstResponder)
            completed.fulfill()
        }
        XCTAssertEqual(completionCount, 0)
        await fulfillment(of: [completed], timeout: 3)
        await flushMainQueue()
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(incomingView.text, source)
    }
    #endif

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
        navigation: MarkdownEditorNavigation,
        showWindow: Bool = true
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
        if showWindow {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(host)
        }
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
        size: CGSize = CGSize(width: 390, height: 844),
        isReadOnly: Bool = false,
        initialPreviewPosition: MarkdownEditorPosition? = nil,
        initialPreviewInsets: UIEdgeInsets? = nil
    ) -> MountedEditor {
        let editor = MarkdownEditor(
            text: .constant(text),
            isReadOnly: isReadOnly, navigation: navigation,
            initialPreviewPosition: initialPreviewPosition,
            initialPreviewInsets: initialPreviewInsets
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
