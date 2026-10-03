import Foundation
import SwiftUI
import XCTest

@testable import NativeEditor

#if os(macOS)
import AppKit

@MainActor
final class MarkdownSnippetInsertionTests: XCTestCase {
    func testLiteralMultilineReplacementAndUndoRedoInBothModes() throws {
        for mode in [MarkdownEditorMode.source, .livePreview] {
            let source = "Before 🪐 café after"
            let (view, window) = makeView(source)
            defer { window.orderOut(nil) }
            let selection = (source as NSString).range(of: "🪐 café")
            view.setSelectedRange(selection)
            MarkdownPresentation.configure(view, mode: mode)
            view.undoManager?.removeAllActions()
            let insert = try XCTUnwrap(view.preparedSnippetInsertion())
            let snippet = "# Plan\n\n- 🦋 task\n"
            XCTAssertTrue(insert(snippet))
            let expected = "Before " + snippet + " after"
            XCTAssertEqual(view.string, expected)
            XCTAssertEqual(view.selectedRange(), NSRange(
                location: selection.location + snippet.utf16.count, length: 0
            ))
            XCTAssertTrue(window.firstResponder === view)
            let undo = try XCTUnwrap(view.undoManager)
            undo.undo()
            XCTAssertEqual(view.string, source)
            undo.redo()
            XCTAssertEqual(view.string, expected)
        }
    }

    func testEmptySelectionInsertsAtCapturedCaret() throws {
        let (view, window) = makeView("🪐 tail")
        defer { window.orderOut(nil) }
        view.setSelectedRange(NSRange(location: 2, length: 0))
        let insert = try XCTUnwrap(view.preparedSnippetInsertion())
        XCTAssertTrue(insert("\n**Hello**\n"))
        XCTAssertEqual(view.string, "🪐\n**Hello**\n tail")
    }

    func testAsyncResultRejectsChangedSelectionSourceOrNavigation() throws {
        let (view, window) = makeView("Original")
        defer { window.orderOut(nil) }
        let navigation = MarkdownEditorNavigation()
        view.markdownLinkNavigation = navigation
        view.setSelectedRange(NSRange(location: 2, length: 0))
        let insert = try XCTUnwrap(view.preparedSnippetInsertion())
        view.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertFalse(insert("Snippet"))
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.string = "Modified"
        XCTAssertFalse(insert("Snippet"))
        view.string = "Original"
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.markdownLinkNavigation = MarkdownEditorNavigation()
        XCTAssertFalse(insert("Snippet"))
        view.markdownLinkNavigation = navigation
        navigation.invalidate()
        XCTAssertFalse(insert("Snippet"))
        XCTAssertEqual(view.string, "Original")
    }

    func testReadOnlyAndCompositionRejectPreparationAndCommit() throws {
        let (view, window) = makeView("Original")
        defer { window.orderOut(nil) }
        let insert = try XCTUnwrap(view.preparedSnippetInsertion())
        view.isEditable = false
        XCTAssertNil(view.preparedSnippetInsertion())
        XCTAssertFalse(insert("Snippet"))
        view.isEditable = true
        view.setMarkedText("字", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: 0, length: 0))
        XCTAssertNil(view.preparedSnippetInsertion())
        XCTAssertFalse(insert("Snippet"))
    }

    private func makeView(_ source: String) -> (MarkdownTextView, NSWindow) {
        _ = NSApplication.shared
        let view = MarkdownTextView(usingTextLayoutManager: true)
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 240)
        view.isEditable = true
        view.allowsUndo = true
        view.string = source
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        return (view, window)
    }
}
#endif
