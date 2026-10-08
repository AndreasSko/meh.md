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
        XCTAssertTrue(command.wantsPriorityOverSystemBehavior)
        XCTAssertTrue(cell.canPerformAction(command.action, withSender: command))
        XCTAssertTrue(UIApplication.shared.sendAction(command.action, to: nil,
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
        XCTAssertFalse(cell.canPerformAction(command.action, withSender: command))
        // The disabled command must not resolve an enabled responder target.
        XCTAssertFalse(UIApplication.shared.sendAction(command.action, to: nil,
                                                       from: command, for: nil))
        XCTAssertEqual(owner.text, edited)
        XCTAssertEqual(source, edited)
        // A selector queued before composition began must also be harmless.
        _ = cell.perform(command.action, with: command)
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
