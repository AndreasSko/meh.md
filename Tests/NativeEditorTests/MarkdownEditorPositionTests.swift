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
    #if os(iOS)
    func testSceneSuspensionCapturesResizeBeforeKeyboardNotifications()
        async throws {
        let source = (0..<300).map { "Fictional observation \($0)." }
            .joined(separator: "\n")
        let navigation = MarkdownEditorNavigation()
        let mounted = mount(text: source, navigation: navigation,
                            size: CGSize(width: 390, height: 400))
        defer { mounted.tearDown() }
        let textView = try XCTUnwrap(mounted.textView as? MarkdownTextView)
        let coordinator = try XCTUnwrap(
            textView.delegate as? MarkdownEditor.Coordinator
        )
        try prepareFocusedViewport(textView, source: source)
        let originalSize = textView.bounds.size
        let offset = textView.contentOffset
        let selection = textView.selectedRange
        let position = try XCTUnwrap(navigation.capturePosition?())

        textView.frame.size.height = 728
        textView.setNeedsLayout()
        textView.layoutIfNeeded()
        textView.setContentOffset(CGPoint(x: 0, y: 500), animated: false)
        NotificationCenter.default.post(
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil
        )
        NotificationCenter.default.post(
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil
        )
        NotificationCenter.default.post(
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil
        )
        NotificationCenter.default.post(
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil
        )
        XCTAssertNotEqual(navigation.capturePosition?(), position)
        coordinator.suspendSceneViewport(in: textView)

        XCTAssertEqual(navigation.capturePosition?(), position)
        textView.frame.size = originalSize
        textView.setNeedsLayout()
        textView.layoutIfNeeded()
        textView.setContentOffset(CGPoint(x: 0, y: 500), animated: false)
        coordinator.resumeSceneViewport(in: textView)
        for _ in 0..<4 { await flushMainQueue() }

        XCTAssertEqual(textView.contentOffset.y, offset.y, accuracy: 0.5)
        XCTAssertEqual(textView.selectedRange, selection)
        XCTAssertTrue(textView.isFirstResponder)
        XCTAssertEqual(textView.text, source)
    }

    func testSelectionChangeDiscardsEarlierResizeViewport() async throws {
        let source = (0..<300).map { "Fictional observation \($0)." }
            .joined(separator: "\n")
        let navigation = MarkdownEditorNavigation()
        let mounted = mount(text: source, navigation: navigation,
                            size: CGSize(width: 390, height: 400))
        defer { mounted.tearDown() }
        let textView = try XCTUnwrap(mounted.textView as? MarkdownTextView)
        let coordinator = try XCTUnwrap(
            textView.delegate as? MarkdownEditor.Coordinator
        )
        try prepareFocusedViewport(textView, source: source)
        let originalSize = textView.bounds.size
        textView.frame.size.height = 728
        textView.setNeedsLayout()
        textView.layoutIfNeeded()
        textView.frame.size = originalSize
        textView.setNeedsLayout()
        textView.layoutIfNeeded()
        textView.selectedRange = NSRange(location: 1_000, length: 0)
        coordinator.textViewDidChangeSelection(textView)
        for _ in 0..<4 { await flushMainQueue() }
        textView.setContentOffset(CGPoint(x: 0, y: 500), animated: false)
        let position = try XCTUnwrap(navigation.capturePosition?())
        let offset = textView.contentOffset.y
        coordinator.suspendSceneViewport(in: textView)
        XCTAssertEqual(navigation.capturePosition?(), position)
        textView.setContentOffset(CGPoint(x: 0, y: 900), animated: false)
        coordinator.resumeSceneViewport(in: textView)
        for _ in 0..<4 { await flushMainQueue() }
        XCTAssertEqual(textView.contentOffset.y, offset, accuracy: 0.5)
        XCTAssertEqual(textView.selectedRange, position.selection)
    }

    func testShrinkAndScrollDoNotRetainEarlierViewport() async throws {
        let source = (0..<300).map { "Fictional observation \($0)." }
            .joined(separator: "\n")
        let navigation = MarkdownEditorNavigation()
        let mounted = mount(text: source, navigation: navigation,
                            size: CGSize(width: 390, height: 400))
        defer { mounted.tearDown() }
        let textView = try XCTUnwrap(mounted.textView as? MarkdownTextView)
        let coordinator = try XCTUnwrap(
            textView.delegate as? MarkdownEditor.Coordinator
        )
        try prepareFocusedViewport(textView, source: source)
        let earlier = try XCTUnwrap(navigation.capturePosition?())
        textView.frame.size.height = 300
        textView.setNeedsLayout()
        textView.layoutIfNeeded()
        textView.bounds.origin.y = 500
        let current = try XCTUnwrap(navigation.capturePosition?())
        XCTAssertNotEqual(current, earlier)
        coordinator.suspendSceneViewport(in: textView)
        XCTAssertEqual(navigation.capturePosition?(), current)
        textView.bounds.origin.y = 900
        coordinator.resumeSceneViewport(in: textView)
        for _ in 0..<4 { await flushMainQueue() }
        XCTAssertEqual(textView.contentOffset.y, 500, accuracy: 0.5)
    }

    func testDismissAndReopenKeyboardDiscardsEarlierResizeViewport()
        async throws {
        let source = (0..<300).map { "Fictional observation \($0)." }
            .joined(separator: "\n")
        let navigation = MarkdownEditorNavigation()
        let mounted = mount(text: source, navigation: navigation,
                            size: CGSize(width: 390, height: 400))
        defer { mounted.tearDown() }
        let textView = try XCTUnwrap(mounted.textView as? MarkdownTextView)
        let coordinator = try XCTUnwrap(
            textView.delegate as? MarkdownEditor.Coordinator
        )
        try prepareFocusedViewport(textView, source: source)
        let earlier = try XCTUnwrap(navigation.capturePosition?())
        // Keyboard dismissal expands the editor and reopening shrinks it.
        // Both can occur while UITextView remains the first responder.
        for height: CGFloat in [728, 400] {
            textView.frame.size.height = height
            textView.setNeedsLayout()
            textView.layoutIfNeeded()
        }
        textView.setContentOffset(CGPoint(x: 0, y: 500), animated: false)
        let current = try XCTUnwrap(navigation.capturePosition?())
        XCTAssertNotEqual(current, earlier)
        coordinator.suspendSceneViewport(in: textView)
        XCTAssertEqual(navigation.capturePosition?(), current)
        textView.setContentOffset(CGPoint(x: 0, y: 900), animated: false)
        coordinator.resumeSceneViewport(in: textView)
        for _ in 0..<4 { await flushMainQueue() }
        XCTAssertEqual(textView.contentOffset.y, 500, accuracy: 0.5)
        XCTAssertTrue(textView.isFirstResponder)
    }

    func testSceneReturnRestoresFocusedViewportWithoutChangingEditorState()
        async throws {
        let source = (0..<300).map { "Fictional observation \($0)." }
            .joined(separator: "\n")
        let navigation = MarkdownEditorNavigation()
        let mounted = mount(text: source, navigation: navigation,
                            size: CGSize(width: 390, height: 400))
        defer { mounted.tearDown() }
        let textView = try XCTUnwrap(mounted.textView as? MarkdownTextView)
        let coordinator = try XCTUnwrap(
            textView.delegate as? MarkdownEditor.Coordinator
        )
        try prepareFocusedViewport(textView, source: source)
        let selection = textView.selectedRange
        let offset = textView.contentOffset
        let undoManager = try XCTUnwrap(textView.undoManager)
        undoManager.removeAllActions()
        undoManager.registerUndo(withTarget: textView) { _ in }
        let position = try XCTUnwrap(navigation.capturePosition?())

        coordinator.suspendSceneViewport(in: textView)
        textView.setContentOffset(CGPoint(x: 0, y: 500), animated: false)
        XCTAssertEqual(navigation.capturePosition?(), position)
        coordinator.resumeSceneViewport(in: textView)
        for _ in 0..<4 { await flushMainQueue() }

        XCTAssertEqual(textView.contentOffset.y, offset.y, accuracy: 0.5)
        XCTAssertEqual(textView.selectedRange, selection)
        XCTAssertTrue(textView.isFirstResponder)
        XCTAssertTrue(undoManager.canUndo)
        XCTAssertEqual(textView.text, source)
        // Once recovery finishes, durable capture follows the live viewport.
        try await Task.sleep(for: .milliseconds(150))
        for _ in 0..<4 { await flushMainQueue() }
        textView.setContentOffset(CGPoint(x: 0, y: 500), animated: false)
        let current = try XCTUnwrap(navigation.capturePosition?())
        XCTAssertNotEqual(current, position)
    }

    func testLateNativeScrollRecoversBeforeReleasingSceneSnapshot()
        async throws {
        let source = (0..<300).map { "Fictional observation \($0)." }
            .joined(separator: "\n")
        let navigation = MarkdownEditorNavigation()
        let mounted = mount(text: source, navigation: navigation,
                            size: CGSize(width: 390, height: 400))
        defer { mounted.tearDown() }
        let textView = try XCTUnwrap(mounted.textView as? MarkdownTextView)
        let coordinator = try XCTUnwrap(
            textView.delegate as? MarkdownEditor.Coordinator
        )
        try prepareFocusedViewport(textView, source: source)
        let offset = textView.contentOffset.y
        let position = try XCTUnwrap(navigation.capturePosition?())
        coordinator.suspendSceneViewport(in: textView)
        coordinator.resumeSceneViewport(in: textView)
        for _ in 0..<4 { await flushMainQueue() }
        try await Task.sleep(for: .milliseconds(40))

        NotificationCenter.default.post(
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil
        )
        textView.setContentOffset(CGPoint(x: 0, y: 500), animated: false)
        coordinator.scrollViewDidScroll(textView)
        for _ in 0..<4 { await flushMainQueue() }
        XCTAssertEqual(textView.contentOffset.y, offset, accuracy: 0.5)
        XCTAssertEqual(navigation.capturePosition?(), position)
        try await Task.sleep(for: .milliseconds(150))
        for _ in 0..<4 { await flushMainQueue() }
        textView.setContentOffset(CGPoint(x: 0, y: 900), animated: false)
        XCTAssertNotEqual(navigation.capturePosition?(), position)
        XCTAssertTrue(textView.isFirstResponder)
    }

    func testUserInteractionCancelsSceneRecoveryDuringQuietInterval() async throws {
        let source = (0..<300).map { "Fictional observation \($0)." }
            .joined(separator: "\n")
        for interaction in ["drag", "focus loss"] {
            let navigation = MarkdownEditorNavigation()
            let mounted = mount(text: source, navigation: navigation,
                                size: CGSize(width: 390, height: 400))
            defer { mounted.tearDown() }
            let textView = try XCTUnwrap(mounted.textView as? MarkdownTextView)
            let coordinator = try XCTUnwrap(
                textView.delegate as? MarkdownEditor.Coordinator
            )
            try prepareFocusedViewport(textView, source: source)
            let position = try XCTUnwrap(navigation.capturePosition?())
            coordinator.suspendSceneViewport(in: textView)
            coordinator.resumeSceneViewport(in: textView)
            for _ in 0..<4 { await flushMainQueue() }
            try await Task.sleep(for: .milliseconds(40))
            if interaction == "drag" {
                coordinator.scrollViewWillBeginDragging(textView)
            } else {
                XCTAssertTrue(textView.resignFirstResponder())
                coordinator.textViewDidEndEditing(textView)
            }
            textView.setContentOffset(CGPoint(x: 0, y: 500), animated: false)
            coordinator.scrollViewDidScroll(textView)
            try await Task.sleep(for: .milliseconds(150))
            for _ in 0..<4 { await flushMainQueue() }
            XCTAssertEqual(textView.contentOffset.y, 500, accuracy: 0.5)
            XCTAssertNotEqual(navigation.capturePosition?(), position)
            XCTAssertEqual(textView.isFirstResponder, interaction == "drag")
        }
    }

    func testSceneReturnDoesNotOverrideNewEditorInteraction() async throws {
        let source = (0..<300).map { "Fictional observation \($0)." }
            .joined(separator: "\n")
        for interaction in ["drag", "navigation", "selection", "text",
                            "marked", "unfocused"] {
            let navigation = MarkdownEditorNavigation()
            let mounted = mount(text: source, navigation: navigation,
                                size: CGSize(width: 390, height: 400))
            defer { mounted.tearDown() }
            let textView = try XCTUnwrap(mounted.textView as? MarkdownTextView)
            let coordinator = try XCTUnwrap(
                textView.delegate as? MarkdownEditor.Coordinator
            )
            try prepareFocusedViewport(textView, source: source)
            if interaction == "unfocused" {
                XCTAssertTrue(textView.resignFirstResponder())
            }
            coordinator.suspendSceneViewport(in: textView)
            switch interaction {
            case "drag": coordinator.scrollViewWillBeginDragging(textView)
            case "navigation":
                navigation.restorePosition?(MarkdownEditorPosition(
                    selection: NSRange(location: 0, length: 0),
                    scrollAnchor: 0, scrollAnchorOffset: 0
                ))
                for _ in 0..<4 { await flushMainQueue() }
            case "selection":
                textView.selectedRange = NSRange(location: 1, length: 0)
            case "text":
                textView.text = source + "\nNew observation."
                coordinator.textViewDidChange(textView)
                // The constant fixture binding can reapply its source when
                // SwiftUI processes the edit. Settle it before the offset
                // assertion, while verifying the edit canceled suspension.
                for _ in 0..<4 { await flushMainQueue() }
            case "marked":
                textView.setMarkedText("composition", selectedRange:
                    NSRange(location: 2, length: 0))
            default: break
            }
            textView.setContentOffset(CGPoint(x: 0, y: 500), animated: false)
            let offset = textView.contentOffset
            let selection = textView.selectedRange
            let text = textView.text
            let marked = textView.markedTextRange != nil
            coordinator.resumeSceneViewport(in: textView)
            for _ in 0..<4 { await flushMainQueue() }

            XCTAssertEqual(textView.contentOffset.y, offset.y,
                           accuracy: 0.5, interaction)
            XCTAssertEqual(textView.selectedRange, selection, interaction)
            XCTAssertEqual(textView.text, text, interaction)
            XCTAssertEqual(textView.markedTextRange != nil, marked, interaction)
        }
    }

    private func prepareFocusedViewport(_ textView: MarkdownTextView,
                                        source: String) throws {
        XCTAssertTrue(textView.becomeFirstResponder())
        let manager = try XCTUnwrap(textView.textLayoutManager)
        let content = try XCTUnwrap(manager.textContentManager)
        manager.ensureLayout(for: content.documentRange)
        textView.selectedRange = NSRange(location: source.utf16.count, length: 0)
        textView.layoutIfNeeded()
        textView.setContentOffset(CGPoint(x: 0, y: 1_500), animated: false)
        // Settle the reading viewport before simulating a scene transition.
        textView.setNeedsLayout()
        textView.layoutIfNeeded()
        XCTAssertGreaterThan(textView.contentOffset.y, 1_000)
    }

    func testCaptureOfLongFocusedEditorPreservesViewportAndState()
        async throws {
        let lines = (0..<1_200).map {
            "Observation \($0) records **bright stars** across the quiet sky."
        }
        let source = lines.joined(separator: "\n\n")
        for mode in [MarkdownEditorMode.source, .livePreview] {
            let navigation = MarkdownEditorNavigation()
            // Model the available height above a software keyboard without
            // depending on simulator keyboard settings or animations.
            let mounted = mount(
                text: source, navigation: navigation,
                size: CGSize(width: 390, height: 400), mode: mode
            )
            defer { mounted.tearDown() }
            let textView = try XCTUnwrap(mounted.textView)
            XCTAssertNotNil(textView.textLayoutManager)
            XCTAssertTrue(textView.becomeFirstResponder())
            if let manager = textView.textLayoutManager,
               let contentManager = manager.textContentManager {
                // Materialize the fixture before placing the reading viewport;
                // UIKit otherwise clamps its provisional extent to the top.
                manager.ensureLayout(for: contentManager.documentRange)
            }
            let middle = (source as NSString).range(of: lines[600])
            textView.selectedRange = middle
            textView.scrollRangeToVisible(middle)
            layout(mounted)
            await flushMainQueue()
            layout(mounted)
            let middleOffset = CGPoint(x: 0, y: 3_000)

            // Keep the caret away from the reading viewport. A position
            // capture must not let TextKit reveal it or move the viewport.
            let selection = NSRange(location: source.utf16.count, length: 0)
            textView.selectedRange = selection
            layout(mounted)
            await flushMainQueue()
            layout(mounted)
            textView.setContentOffset(middleOffset, animated: false)
            layout(mounted)
            await flushMainQueue()
            layout(mounted)
            let offset = textView.contentOffset
            XCTAssertGreaterThan(offset.y, 0)
            let undoManager = try XCTUnwrap(textView.undoManager)
            undoManager.removeAllActions()
            undoManager.registerUndo(withTarget: textView) { _ in }

            let captured = try XCTUnwrap(navigation.capturePosition?())

            XCTAssertEqual(captured.selection, selection, mode.rawValue)
            XCTAssertLessThan(captured.scrollAnchor, selection.location)
            XCTAssertEqual(textView.contentOffset.y, offset.y,
                           accuracy: 0.5, mode.rawValue)
            XCTAssertEqual(textView.contentOffset.x, offset.x,
                           accuracy: 0.5, mode.rawValue)
            XCTAssertEqual(textView.selectedRange, selection, mode.rawValue)
            XCTAssertTrue(textView.isFirstResponder, mode.rawValue)
            XCTAssertTrue(undoManager.canUndo, mode.rawValue)
            XCTAssertEqual(textView.text, source, mode.rawValue)
            await flushMainQueue()
            layout(mounted)
            XCTAssertEqual(textView.contentOffset.y, offset.y,
                           accuracy: 0.5, mode.rawValue)
            XCTAssertEqual(textView.selectedRange, selection, mode.rawValue)
        }
    }
    #endif

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

    #if os(iOS)
    func testNavigationPreviewStartsAtSavedAnchorBeforeAsyncAttachment() async throws {
        let source = (0..<180).map { "Fictional observation \($0) across the page." }
            .joined(separator: "\n")
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
        let insets = originalNavigation.captureViewportInsets?()
        original.tearDown()

        let navigation = MarkdownEditorNavigation()
        let preview = mount(text: source, navigation: navigation, isReadOnly: true,
                            initialPreviewPosition: position, initialPreviewInsets: insets)
        defer { preview.tearDown() }
        let restored = try XCTUnwrap(navigation.capturePosition?())
        XCTAssertEqual(restored.scrollAnchor, position.scrollAnchor)
        XCTAssertEqual(restored.scrollAnchorOffset, position.scrollAnchorOffset, accuracy: 1)
        XCTAssertGreaterThan(try XCTUnwrap(preview.textView).contentOffset.y, 0)
    }

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
        size: CGSize = CGSize(width: 390, height: 844),
        isReadOnly: Bool = false,
        initialPreviewPosition: MarkdownEditorPosition? = nil,
        initialPreviewInsets: UIEdgeInsets? = nil,
        mode: MarkdownEditorMode = .source
    ) -> MountedEditor {
        let editor = MarkdownEditor(
            text: .constant(text),
            isReadOnly: isReadOnly, navigation: navigation, mode: mode,
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
