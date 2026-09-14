import AutomergeSpike
import SwiftUI
import XCTest

@testable import NativeEditor

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

@MainActor
final class NativeEditorIntegrationTests: XCTestCase {
    private final class DocumentBinding {
        let note: SpikeNoteDocument
        var receivedTexts: [String] = []
        var receivedError: Error?

        init(note: SpikeNoteDocument) {
            self.note = note
        }

        var text: String {
            get {
                do {
                    return try note.text
                } catch {
                    receivedError = error
                    return ""
                }
            }
            set {
                receivedTexts.append(newValue)
                do {
                    try note.replaceAll(with: newValue)
                } catch {
                    receivedError = error
                }
            }
        }
    }

    func testNativeTypingUndoAndRedoReachAutomergeBinding() throws {
        let source = "* > ==hello== and ~~old~~"
        let boundary = try DocumentBinding(
            note: SpikeNoteDocument(text: source)
        )
        let editor = MarkdownEditor(
            text: Binding(
                get: { boundary.text },
                set: { boundary.text = $0 }
            )
        )
        let mounted = mount(editor)
        let textView = try XCTUnwrap(mounted.textView)
        defer { mounted.tearDown() }

        moveInsertionPointToEnd(of: textView)
        insert("!", in: textView)
        XCTAssertEqual(nativeText(in: textView), source + "!")
        XCTAssertEqual(try boundary.note.text, source + "!")

        let undoManager = try XCTUnwrap(textView.undoManager)
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        XCTAssertEqual(nativeText(in: textView), source)
        XCTAssertEqual(try boundary.note.text, source)

        XCTAssertTrue(undoManager.canRedo)
        undoManager.redo()
        XCTAssertEqual(nativeText(in: textView), source + "!")
        XCTAssertEqual(try boundary.note.text, source + "!")
        XCTAssertNil(boundary.receivedError)
        XCTAssertEqual(
            boundary.receivedTexts,
            [source + "!", source, source + "!"]
        )
    }

    func testCommittedMarkedTextReachesAutomergeBinding() throws {
        let boundary = try DocumentBinding(
            note: SpikeNoteDocument(text: "hello")
        )
        let editor = MarkdownEditor(
            text: Binding(
                get: { boundary.text },
                set: { boundary.text = $0 }
            )
        )
        let mounted = mount(editor)
        let textView = try XCTUnwrap(mounted.textView)
        defer { mounted.tearDown() }

        moveInsertionPointToEnd(of: textView)
        setMarkedText("世界", in: textView)
        XCTAssertTrue(hasMarkedText(in: textView))
        XCTAssertEqual(try boundary.note.text, "hello")

        unmarkText(in: textView)
        XCTAssertFalse(hasMarkedText(in: textView))
        XCTAssertEqual(nativeText(in: textView), "hello世界")
        XCTAssertEqual(try boundary.note.text, "hello世界")
        XCTAssertNil(boundary.receivedError)
        XCTAssertEqual(boundary.receivedTexts, ["hello世界"])
    }

    func testCanonicallyEquivalentNativeEditPreservesExactBytes() throws {
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        let boundary = try DocumentBinding(
            note: SpikeNoteDocument(text: composed)
        )
        let editor = MarkdownEditor(
            text: Binding(
                get: { boundary.text },
                set: { boundary.text = $0 }
            )
        )
        let mounted = mount(editor)
        let textView = try XCTUnwrap(mounted.textView)
        defer { mounted.tearDown() }

        replaceAllNativeText(with: decomposed, in: textView)

        XCTAssertTrue(
            nativeText(in: textView).utf8.elementsEqual(decomposed.utf8)
        )
        XCTAssertTrue(
            try boundary.note.text.utf8.elementsEqual(decomposed.utf8)
        )
        XCTAssertNil(boundary.receivedError)
        XCTAssertEqual(boundary.receivedTexts.count, 1)
        XCTAssertTrue(
            boundary.receivedTexts[0].utf8.elementsEqual(decomposed.utf8)
        )
    }

#if os(macOS)
    func testReturnKeepsCaretGeometryViewportAndBlockDecorations() async throws {
        var lines = (0..<80).map { "Line \($0) with ordinary body text" }
        lines[39] = "> Quote near the edit"
        lines[40] = "* Middle list item with ==highlight=="
        lines[41] = ""
        let source = lines.joined(separator: "\n")
        let boundary = try DocumentBinding(
            note: SpikeNoteDocument(text: source)
        )
        let editor = MarkdownEditor(
            text: Binding(
                get: { boundary.text },
                set: { boundary.text = $0 }
            )
        )
        let mounted = mount(editor)
        let textView = try XCTUnwrap(mounted.textView)
        let scrollView = try XCTUnwrap(textView.enclosingScrollView)
        defer { mounted.tearDown() }
        mounted.window.makeKeyAndOrderFront(nil)

        let lineRange = (source as NSString).range(of: lines[40])
        let insertion = NSRange(location: NSMaxRange(lineRange), length: 0)
        textView.setSelectedRange(insertion)
        textView.scrollRangeToVisible(insertion)
        let beforeOrigin = scrollView.contentView.bounds.origin
        let beforeCaret = textView.firstRect(
            forCharacterRange: insertion,
            actualRange: nil
        )

        textView.insertNewline(nil)

        let firstPresentationFinished = expectation(
            description: "first deferred presentation refresh"
        )
        DispatchQueue.main.async { firstPresentationFinished.fulfill() }
        await fulfillment(of: [firstPresentationFinished], timeout: 1)
        mounted.window.displayIfNeeded()

        let firstSelection = NSRange(
            location: insertion.location + 1,
            length: 0
        )
        let firstCaret = textView.firstRect(
            forCharacterRange: firstSelection,
            actualRange: nil
        )

        textView.insertNewline(nil)

        let secondPresentationFinished = expectation(
            description: "second deferred presentation refresh"
        )
        DispatchQueue.main.async { secondPresentationFinished.fulfill() }
        await fulfillment(of: [secondPresentationFinished], timeout: 1)
        mounted.window.displayIfNeeded()

        let expectedSelection = NSRange(
            location: insertion.location + 2,
            length: 0
        )
        let afterCaret = textView.firstRect(
            forCharacterRange: expectedSelection,
            actualRange: nil
        )
        let afterOrigin = scrollView.contentView.bounds.origin
        let layoutManager = try XCTUnwrap(textView.textLayoutManager)
        let visibleRange = try XCTUnwrap(
            MarkdownPresentation.visibleRange(in: layoutManager)
        )
        let decorations = MarkdownPresentation.blockDecorations(
            text: textView.string,
            layoutManager: layoutManager,
            containerWidth: try XCTUnwrap(textView.textContainer).size.width,
            visibleRange: visibleRange
        )
        XCTAssertEqual(textView.selectedRange(), expectedSelection)
        XCTAssertTrue(afterCaret.minX.isFinite)
        XCTAssertTrue(afterCaret.minY.isFinite)
        XCTAssertGreaterThan(afterCaret.height, 0)
        XCTAssertLessThan(firstCaret.minY, beforeCaret.minY)
        XCTAssertLessThan(afterCaret.minY, beforeCaret.minY)
        XCTAssertLessThanOrEqual(
            abs(afterOrigin.y - beforeOrigin.y),
            2 * max(beforeCaret.height, afterCaret.height) + 1
        )
        XCTAssertTrue(decorations.contains { $0.kind == .blockquote })
    }

    func testFiveReturnsPreserveSourceSelectionAndViewport() async throws {
        for fontSize in [17.0, 22.0] {
            for atEnd in [false, true] {
                let lines = (0..<80).map { "Invented paragraph \($0)." }
                let source = lines.joined(separator: "\n")
                let boundary = try DocumentBinding(
                    note: SpikeNoteDocument(text: source)
                )
                let editor = MarkdownEditor(
                    text: Binding(
                        get: { boundary.text },
                        set: { boundary.text = $0 }
                    ),
                    fontSize: fontSize
                )
                let mounted = mount(editor)
                let textView = try XCTUnwrap(mounted.textView)
                mounted.window.makeKeyAndOrderFront(nil)
                mounted.window.makeFirstResponder(textView)
                defer { mounted.tearDown() }
                let scrollView = try XCTUnwrap(textView.enclosingScrollView)

                let location: Int
                if atEnd {
                    location = (source as NSString).length
                } else {
                    let lineRange = (source as NSString).range(of: lines[40])
                    location = NSMaxRange(lineRange)
                }
                textView.setSelectedRange(
                    NSRange(location: location, length: 0)
                )
                textView.scrollRangeToVisible(textView.selectedRange())
                let beforeOrigin = scrollView.contentView.bounds.origin

                for returnCount in 1...5 {
                    textView.insertNewline(nil)
                    try await Task.sleep(for: .milliseconds(80))
                    mounted.window.displayIfNeeded()

                    XCTAssertEqual(
                        textView.selectedRange(),
                        NSRange(location: location + returnCount, length: 0)
                    )
                    XCTAssertTrue(textView.shouldDrawInsertionPoint)
                }

                let expected = NSMutableString(string: source)
                expected.insert(
                    String(repeating: "\n", count: 5),
                    at: location
                )
                let expectedString = expected as String
                XCTAssertEqual(textView.string, expectedString)
                XCTAssertEqual(try boundary.note.text, expectedString)
                XCTAssertLessThanOrEqual(
                    abs(scrollView.contentView.bounds.origin.y - beforeOrigin.y),
                    fontSize * 12
                )
            }
        }
    }

    func testFiveReturnsKeepNativeInsertionIndicatorVisible() async throws {
        let lines = (0..<80).map { "Invented paragraph \($0)." }
        let source = lines.joined(separator: "\n")
        let boundary = try DocumentBinding(
            note: SpikeNoteDocument(text: source)
        )
        let editor = MarkdownEditor(
            text: Binding(
                get: { boundary.text },
                set: { boundary.text = $0 }
            ),
            fontSize: 22
        )
        let mounted = mount(editor)
        let textView = try XCTUnwrap(mounted.textView)
        defer { mounted.tearDown() }
        mounted.window.makeKeyAndOrderFront(nil)
        mounted.window.makeFirstResponder(textView)

        let lineRange = (source as NSString).range(of: lines[40])
        let location = NSMaxRange(lineRange)
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        textView.updateInsertionPointStateAndRestartTimer(true)
        mounted.window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(50))

        guard textView.subviews.contains(where: {
            $0 is NSTextInsertionIndicator
        }) else {
            throw XCTSkip(
                "The SwiftPM test host has no native insertion indicator; "
                    + "run scripts/run_editor_caret_check.sh."
            )
        }

        for returnCount in 1...5 {
            textView.insertNewline(nil)
            try await Task.sleep(for: .milliseconds(80))
            mounted.window.displayIfNeeded()

            let indicator = try XCTUnwrap(
                textView.subviews.compactMap {
                    $0 as? NSTextInsertionIndicator
                }.first
            )
            XCTAssertEqual(indicator.displayMode, .automatic)
            XCTAssertFalse(
                indicator.isHidden,
                "hidden insertion indicator after Return \(returnCount)"
            )
            XCTAssertGreaterThan(indicator.alphaValue, 0)
            XCTAssertGreaterThan(indicator.frame.height, 0)
        }
    }
#endif
}

#if os(macOS)
@MainActor
private extension NativeEditorIntegrationTests {
    typealias NativeTextView = NSTextView

    struct MountedEditor {
        let window: NSWindow
        let textView: NSTextView?

        @MainActor func tearDown() {
            window.orderOut(nil)
        }
    }

    func mount(_ editor: MarkdownEditor) -> MountedEditor {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let host = NSHostingView(rootView: editor)
        window.contentView = host
        window.makeFirstResponder(host)
        host.layoutSubtreeIfNeeded()
        let textView = findTextView(in: host)
        if let textView {
            window.makeFirstResponder(textView)
        }
        return MountedEditor(window: window, textView: textView)
    }

    func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView {
            return textView
        }
        for subview in view.subviews {
            if let textView = findTextView(in: subview) {
                return textView
            }
        }
        return nil
    }

    func moveInsertionPointToEnd(of textView: NSTextView) {
        textView.setSelectedRange(
            NSRange(location: (textView.string as NSString).length, length: 0)
        )
    }

    func insert(_ text: String, in textView: NSTextView) {
        textView.insertText(
            text,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    func replaceAllNativeText(with text: String, in textView: NSTextView) {
        textView.setSelectedRange(
            NSRange(location: 0, length: (textView.string as NSString).length)
        )
        insert(text, in: textView)
    }

    func nativeText(in textView: NSTextView) -> String {
        textView.string
    }

    func setMarkedText(_ text: String, in textView: NSTextView) {
        textView.setMarkedText(
            text,
            selectedRange: NSRange(location: 2, length: 0),
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
private extension NativeEditorIntegrationTests {
    typealias NativeTextView = UITextView

    struct MountedEditor {
        let window: UIWindow
        let textView: UITextView?

        @MainActor func tearDown() {
            window.isHidden = true
        }
    }

    func mount(_ editor: MarkdownEditor) -> MountedEditor {
        let host = UIHostingController(rootView: editor)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let textView = findTextView(in: host.view)
        _ = textView?.becomeFirstResponder()
        return MountedEditor(window: window, textView: textView)
    }

    func findTextView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView {
            return textView
        }
        for subview in view.subviews {
            if let textView = findTextView(in: subview) {
                return textView
            }
        }
        return nil
    }

    func moveInsertionPointToEnd(of textView: UITextView) {
        textView.selectedRange = NSRange(
            location: (textView.text as NSString).length,
            length: 0
        )
    }

    func insert(_ text: String, in textView: UITextView) {
        textView.insertText(text)
    }

    func replaceAllNativeText(with text: String, in textView: UITextView) {
        textView.selectedRange = NSRange(
            location: 0,
            length: (textView.text as NSString).length
        )
        insert(text, in: textView)
    }

    func nativeText(in textView: UITextView) -> String {
        textView.text
    }

    func setMarkedText(_ text: String, in textView: UITextView) {
        textView.setMarkedText(
            text,
            selectedRange: NSRange(location: 2, length: 0)
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
