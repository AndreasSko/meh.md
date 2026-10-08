import SwiftUI
import XCTest
@testable import NativeEditor

#if os(iOS)
import UIKit

@MainActor
final class MarkdownTableNativeCommandTests: XCTestCase {
    func testResponderUndoCommandPreservesCellAndRejectsMarkedComposition() async throws {
        let initial = "| Name |\n| --- |\n| Moon |\n"
        var source = initial
        let host = UIHostingController(rootView: MarkdownEditor(
            text: Binding(get: { source }, set: { source = $0 }),
            mode: .livePreview
        ))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        // Let SwiftUI finish the initial host mount before native routing.
        await Task.yield()
        host.view.layoutIfNeeded()
        let owner = try XCTUnwrap(findOwner(in: host.view))
        MarkdownPresentation.refresh(owner, mode: .livePreview)
        let table = try XCTUnwrap(owner.markdownSyntaxCache.result(for: initial).tables.first)
        let controller = owner.markdownCellController
        XCTAssertTrue(controller.begin(tableRange: table.range, row: 1, column: 0))
        let cell = controller.editor
        XCTAssertTrue(cell.isFirstResponder)
        let undo = try XCTUnwrap(owner.undoManager)
        XCTAssertTrue(cell.undoManager === undo)
        undo.removeAllActions()
        cell.insertText("!")
        let edited = initial.replacingOccurrences(of: "Moon", with: "Moon!")
        XCTAssertEqual(owner.text, edited)
        XCTAssertEqual(source, edited)
        XCTAssertTrue(undo.canUndo)
        let command = try XCTUnwrap(cell.keyCommands?.first {
            $0.input == "z" && $0.modifierFlags == .command
        })
        let action = try XCTUnwrap(command.action)
        XCTAssertTrue(command.wantsPriorityOverSystemBehavior)
        XCTAssertTrue(cell.canPerformAction(action, withSender: command))
        XCTAssertTrue(UIApplication.shared.sendAction(action, to: nil,
                                                      from: command, for: nil))
        XCTAssertEqual(owner.text, initial)
        XCTAssertEqual(source, initial)
        XCTAssertEqual(cell.text, "Moon")
        XCTAssertTrue(cell.isFirstResponder)
        XCTAssertTrue(controller.isActive)

        cell.insertText("!")
        XCTAssertEqual(owner.text, edited)
        cell.setMarkedText("候", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertNotNil(cell.markedTextRange)
        XCTAssertTrue(controller.hasMarkedText)
        XCTAssertFalse(cell.canPerformAction(action, withSender: command))
        let composingText = cell.text
        let composingSelection = cell.selectedRange
        func markedOffsets() throws -> NSRange {
            let marked = try XCTUnwrap(cell.markedTextRange)
            return NSRange(
                location: cell.offset(from: cell.beginningOfDocument, to: marked.start),
                length: cell.offset(from: marked.start, to: marked.end)
            )
        }
        let composingMarkedRange = try markedOffsets()
        func assertCompositionPreserved(file: StaticString = #filePath,
                                        line: UInt = #line) throws {
            XCTAssertEqual(cell.text, composingText, file: file, line: line)
            XCTAssertEqual(cell.selectedRange, composingSelection, file: file, line: line)
            XCTAssertEqual(try markedOffsets(), composingMarkedRange, file: file, line: line)
            XCTAssertTrue(controller.hasMarkedText, file: file, line: line)
            XCTAssertTrue(cell.isFirstResponder, file: file, line: line)
            XCTAssertTrue(controller.isActive, file: file, line: line)
        }
        // sendAction routes an implemented selector; its return value does
        // not prove native command eligibility. A routed action must still
        // preserve the source while composition is active.
        _ = UIApplication.shared.sendAction(action, to: nil,
                                             from: command, for: nil)
        try assertCompositionPreserved()
        XCTAssertEqual(owner.text, edited)
        XCTAssertEqual(source, edited)
        // A selector queued before composition began must also be harmless.
        _ = cell.perform(action, with: command)
        try assertCompositionPreserved()
        XCTAssertEqual(owner.text, edited)
        XCTAssertEqual(source, edited)
        XCTAssertTrue(controller.isActive)
        XCTAssertTrue(cell.isFirstResponder)
        cell.unmarkText()
        XCTAssertFalse(controller.hasMarkedText)
        XCTAssertTrue(cell.isFirstResponder)
        XCTAssertTrue(controller.isActive)
    }

    private func findOwner(in view: UIView) -> MarkdownTextView? {
        if let owner = view as? MarkdownTextView { return owner }
        for child in view.subviews {
            if let owner = findOwner(in: child) { return owner }
        }
        return nil
    }
}
#endif
