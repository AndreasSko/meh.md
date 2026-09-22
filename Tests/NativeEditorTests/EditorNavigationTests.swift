import SwiftUI
import XCTest

@testable import NativeEditor

#if os(macOS)
import AppKit

@MainActor
final class EditorNavigationTests: XCTestCase {
    func testActivationWaitsForAttachmentAndIgnoresReplacedEditor() async {
        let outgoing = MarkdownEditorNavigation()
        let incoming = MarkdownEditorNavigation()
        var activated: [String] = []
        outgoing.didAttach()
        outgoing.whenAttached { activated.append("outgoing") }
        incoming.whenAttached { activated.append("incoming") }
        outgoing.invalidate()

        await drainMainQueue()
        XCTAssertTrue(activated.isEmpty)

        incoming.didAttach()
        await drainMainQueue()
        XCTAssertEqual(activated, ["incoming"])
    }

    private func drainMainQueue() async {
        let drained = expectation(description: "Attachment callbacks drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 1)
    }

    func testPrepareCommitsNativeBufferBeforeFreezingEditor() throws {
        let model = NavigationEditorModel()
        let fixture = makeFixture(model)
        fixture.textView.string = "hello!"
        var editableDuringCommit: Bool?
        model.onCommit = { editableDuringCommit = fixture.textView.isEditable }

        XCTAssertTrue(try XCTUnwrap(fixture.navigation.prepareToLeave)())

        XCTAssertEqual(model.committedTexts, ["hello!"])
        XCTAssertEqual(model.text, "hello!")
        XCTAssertEqual(editableDuringCommit, true)
        XCTAssertFalse(fixture.textView.isEditable)
    }

    func testFailedCommitPreventsLeavingAndKeepsEditorEditable() throws {
        let model = NavigationEditorModel()
        model.commitError = NavigationTestError.failed
        let fixture = makeFixture(model)
        fixture.textView.string = "not recorded"

        XCTAssertFalse(try XCTUnwrap(fixture.navigation.prepareToLeave)())

        XCTAssertEqual(model.committedTexts, ["not recorded"])
        XCTAssertEqual(model.text, "hello")
        XCTAssertEqual(model.errorCount, 1)
        XCTAssertTrue(fixture.textView.isEditable)
    }

    func testMarkedTextPreventsLeavingWithoutAttemptingCommit() throws {
        let model = NavigationEditorModel()
        let fixture = makeFixture(model)
        fixture.textView.setSelectedRange(
            NSRange(location: fixture.textView.string.utf16.count, length: 0)
        )
        fixture.textView.setMarkedText(
            "world",
            selectedRange: NSRange(location: 5, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(fixture.textView.hasMarkedText())

        XCTAssertFalse(try XCTUnwrap(fixture.navigation.prepareToLeave)())

        XCTAssertTrue(model.committedTexts.isEmpty)
        XCTAssertEqual(model.text, "hello")
        XCTAssertTrue(fixture.textView.isEditable)
    }

    func testResumeMakesFrozenEditorEditableAgain() throws {
        let fixture = makeFixture(NavigationEditorModel())

        XCTAssertTrue(try XCTUnwrap(fixture.navigation.prepareToLeave)())
        XCTAssertFalse(fixture.textView.isEditable)

        try XCTUnwrap(fixture.navigation.resumeEditing)()
        XCTAssertTrue(fixture.textView.isEditable)
    }

    func testRevealSearchMatchSelectsWithoutEditingOrFocus() throws {
        let model = NavigationEditorModel()
        model.text = "Start\nA😀B\nEnd"
        let fixture = makeFixture(model)
        let undoManager = try XCTUnwrap(fixture.textView.undoManager)
        undoManager.registerUndo(withTarget: fixture.textView) { _ in }
        let originalText = fixture.textView.string
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.textView))
        XCTAssertEqual(
            fixture.navigation.captureHasEditingFocus?(),
            true
        )

        fixture.navigation.revealSearchMatch?(
            NSRange(location: 7, length: 1)
        )

        XCTAssertEqual(
            fixture.textView.selectedRange(),
            (originalText as NSString).range(of: "😀")
        )
        XCTAssertTrue(
            renderingBackgroundRanges(in: fixture.textView).contains(
                (originalText as NSString).range(of: "😀")
            )
        )
        XCTAssertEqual(fixture.textView.string, originalText)
        XCTAssertEqual(model.text, originalText)
        XCTAssertTrue(undoManager.canUndo)
        XCTAssertEqual(
            fixture.navigation.captureHasEditingFocus?(),
            false
        )
        XCTAssertFalse(
            fixture.textView.window?.firstResponder === fixture.textView
        )

        fixture.textView.string.append("!")
        fixture.coordinator.textDidChange(
            Notification(name: NSText.didChangeNotification,
                         object: fixture.textView)
        )
        XCTAssertTrue(renderingBackgroundRanges(in: fixture.textView).isEmpty)
    }

    func testRevealSearchMatchWaitsForMarkedText() throws {
        let model = NavigationEditorModel()
        model.text = "hello world"
        let fixture = makeFixture(model)
        fixture.textView.setSelectedRange(NSRange(location: 5, length: 0))
        fixture.textView.setMarkedText(
            "!", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(fixture.textView.hasMarkedText())

        fixture.navigation.revealSearchMatch?(
            NSRange(location: 6, length: 5)
        )
        XCTAssertNotEqual(
            fixture.textView.selectedRange(),
            NSRange(location: 6, length: 5)
        )

        fixture.textView.unmarkText()
        fixture.coordinator.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification,
                         object: fixture.textView)
        )

        XCTAssertEqual(
            fixture.textView.selectedRange(),
            NSRange(location: 6, length: 5)
        )
    }

    func testEditingRevealedMatchClearsHighlightAndRemainsUndoable() throws {
        let model = NavigationEditorModel()
        model.text = "alpha target omega"
        let fixture = makeFixture(model)
        fixture.textView.delegate = fixture.coordinator
        fixture.coordinator.observeUndoAndRedo(for: fixture.textView)
        let originalText = fixture.textView.string
        let match = (originalText as NSString).range(of: "target")
        fixture.navigation.revealSearchMatch?(match)
        XCTAssertTrue(
            renderingBackgroundRanges(in: fixture.textView).contains(match)
        )
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.textView))

        fixture.textView.insertText(
            "replacement",
            replacementRange: fixture.textView.selectedRange()
        )

        XCTAssertEqual(fixture.textView.string, "alpha replacement omega")
        XCTAssertEqual(model.text, "alpha replacement omega")
        XCTAssertTrue(renderingBackgroundRanges(in: fixture.textView).isEmpty)
        let undoManager = try XCTUnwrap(fixture.textView.undoManager)
        XCTAssertTrue(undoManager.canUndo)

        undoManager.undo()

        XCTAssertEqual(fixture.textView.string, originalText)
        XCTAssertEqual(model.text, originalText)
        XCTAssertTrue(renderingBackgroundRanges(in: fixture.textView).isEmpty)
    }

    func testRevealCentersLongNoteAndRecentersAfterViewportResize() throws {
        var source = (0..<240).map {
            "Line \($0) contains enough fictional text for stable layout."
        }.joined(separator: "\n")
        let navigation = MarkdownEditorNavigation()
        let editor = MarkdownEditor(
            text: Binding(get: { source }, set: { source = $0 }),
            navigation: navigation
        )
        let host = NSHostingView(rootView: editor)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.layoutIfNeeded()
        let textView = try XCTUnwrap(findTextView(in: host))
        let match = (source as NSString).range(of: "Line 150 contains")

        navigation.revealSearchMatch?(match)
        window.layoutIfNeeded()

        assertCentered(match, in: textView, accuracy: 30)
        XCTAssertEqual(
            navigation.searchLandingPosition,
            navigation.capturePosition?()
        )

        window.setContentSize(NSSize(width: 560, height: 560))
        window.layoutIfNeeded()

        assertCentered(match, in: textView, accuracy: 30)
        let resizedLanding = try XCTUnwrap(navigation.searchLandingPosition)
        XCTAssertEqual(resizedLanding, navigation.capturePosition?())

        let scrollView = try XCTUnwrap(textView.enclosingScrollView)
        let manuallyScrolledY = scrollView.contentView.bounds.minY + 40
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: manuallyScrolledY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        window.layoutIfNeeded()
        XCTAssertEqual(
            scrollView.contentView.bounds.minY,
            manuallyScrolledY,
            accuracy: 1
        )
        XCTAssertEqual(navigation.searchLandingPosition, resizedLanding)
        XCTAssertNotEqual(navigation.capturePosition?(), resizedLanding)
    }

    private func makeFixture(_ model: NavigationEditorModel) -> NavigationFixture {
        let navigation = MarkdownEditorNavigation()
        let editor = MarkdownEditor(
            text: Binding(
                get: { model.text },
                set: { model.text = $0 }
            ),
            editRevision: model.revision,
            commitEdit: { text, revision in
                try model.commit(text, revision: revision)
            },
            onEditError: { _ in model.errorCount += 1 },
            navigation: navigation
        )
        let coordinator = editor.makeCoordinator()
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        textView.string = model.text
        textView.allowsUndo = true
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = scrollView
        coordinator.attachNavigation(to: textView)
        return NavigationFixture(
            navigation: navigation,
            coordinator: coordinator,
            textView: textView,
            window: window
        )
    }

    private func renderingBackgroundRanges(
        in textView: NSTextView
    ) -> [NSRange] {
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager else {
            return []
        }
        textView.layoutSubtreeIfNeeded()
        layoutManager.textViewportLayoutController.layoutViewport()
        let documentStart = contentManager.documentRange.location
        var ranges: [NSRange] = []
        layoutManager.enumerateRenderingAttributes(
            from: documentStart, reverse: false
        ) { _, attributes, range in
            guard attributes[.backgroundColor] != nil else { return true }
            let location = contentManager.offset(
                from: documentStart, to: range.location
            )
            let end = contentManager.offset(
                from: documentStart, to: range.endLocation
            )
            ranges.append(NSRange(
                location: location, length: max(0, end - location)
            ))
            return true
        }
        return ranges
    }

    private func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let textView = findTextView(in: subview) { return textView }
        }
        return nil
    }

    private func assertCentered(
        _ range: NSRange,
        in textView: NSTextView,
        accuracy: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let screenRect = textView.firstRect(
            forCharacterRange: range,
            actualRange: nil
        )
        let windowRect = textView.window?.convertFromScreen(screenRect)
            ?? .zero
        let localRect = textView.convert(windowRect, from: nil)
        XCTAssertEqual(
            localRect.midY,
            textView.visibleRect.midY,
            accuracy: accuracy,
            file: file,
            line: line
        )
    }
}

private enum NavigationTestError: Error {
    case failed
}

@MainActor
private final class NavigationEditorModel {
    var text = "hello"
    var revision = Data([0])
    var committedTexts: [String] = []
    var errorCount = 0
    var commitError: Error?
    var onCommit: (() -> Void)?

    func commit(_ text: String, revision: Data) throws -> MarkdownEditorCommit {
        committedTexts.append(text)
        onCommit?()
        if let commitError { throw commitError }
        self.text = text
        self.revision = Data([1])
        return MarkdownEditorCommit(text: text, revision: self.revision)
    }
}

@MainActor
private struct NavigationFixture {
    let navigation: MarkdownEditorNavigation
    let coordinator: MarkdownEditor.Coordinator
    let textView: NSTextView
    let window: NSWindow
}
#endif

#if os(iOS)
import UIKit

@MainActor
final class EditorSearchNavigationTests: XCTestCase {
    func testNativeFindAndMatchRevealDoNotEditOrFocusEditor() throws {
        var source = "Start\nA😀B\n" + String(repeating: "End\n", count: 80)
        let navigation = MarkdownEditorNavigation()
        let editor = MarkdownEditor(
            text: Binding(get: { source }, set: { source = $0 }),
            navigation: navigation
        )
        let host = UIHostingController(rootView: editor)
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        host.view.layoutIfNeeded()
        let textView = try XCTUnwrap(findTextView(in: host.view))
        let undoManager = try XCTUnwrap(textView.undoManager)
        undoManager.registerUndo(withTarget: textView) { _ in }

        XCTAssertTrue(textView.isFindInteractionEnabled)
        navigation.revealSearchMatch?(NSRange(location: 7, length: 1))

        XCTAssertEqual(
            textView.selectedRange,
            (source as NSString).range(of: "😀")
        )
        XCTAssertEqual(textView.text, source)
        XCTAssertTrue(undoManager.canUndo)
        XCTAssertFalse(textView.isFirstResponder)
    }

    private func findTextView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView { return textView }
        for subview in view.subviews {
            if let textView = findTextView(in: subview) { return textView }
        }
        return nil
    }
}
#endif
