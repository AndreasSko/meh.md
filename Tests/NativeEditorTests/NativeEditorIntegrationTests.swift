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
        insert("!", in: textView)
        XCTAssertEqual(nativeText(in: textView), "hello!")
        XCTAssertEqual(try boundary.note.text, "hello!")

        let undoManager = try XCTUnwrap(textView.undoManager)
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        XCTAssertEqual(nativeText(in: textView), "hello")
        XCTAssertEqual(try boundary.note.text, "hello")

        XCTAssertTrue(undoManager.canRedo)
        undoManager.redo()
        XCTAssertEqual(nativeText(in: textView), "hello!")
        XCTAssertEqual(try boundary.note.text, "hello!")
        XCTAssertNil(boundary.receivedError)
        XCTAssertEqual(boundary.receivedTexts, ["hello!", "hello", "hello!"])
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
