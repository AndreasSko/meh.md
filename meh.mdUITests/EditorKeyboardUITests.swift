import XCTest

#if os(iOS)
import UIKit

final class EditorKeyboardUITests: XCTestCase {
    func testScrollDismissesKeyboardAndEditingCanResume() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .phone,
            "iPad keeps the editor focused while scrolling"
        )
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launch()
        let newItem = app.buttons["notebook-new-item"]
        XCTAssertTrue(newItem.waitForExistence(timeout: 15))
        newItem.tap()
        commitDefaultTitle(in: app)
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        editor.typeText("> Sky\n\n* > Stars\n")
        let editedText = try XCTUnwrap(editor.value as? String)
        XCTAssertFalse(app.buttons["dismiss-editor-keyboard"].exists)
        dragEditor(editor)
        let hidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.keyboards.firstMatch
        )
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        XCTAssertEqual(editor.value as? String, editedText)
        capture(app, name: "Short quotes with keyboard dismissed")
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        capture(app, name: "Short quotes after keyboard reopening")
        editor.typeText("Still editable")
        XCTAssertTrue((editor.value as? String)?.contains("Still editable") == true)
        dragEditor(editor)
    }

    func testIPadScrollKeepsCaretAndTypingRevealsIt() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "iPad-specific editor focus behavior"
        )
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launch()
        let newItem = app.buttons["notebook-new-item"]
        XCTAssertTrue(newItem.waitForExistence(timeout: 15))
        newItem.tap()
        commitDefaultTitle(in: app)
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))

        let lines = (1...40).map { "Line \($0)" }.joined(separator: "\n")
        editor.typeText(lines)
        capture(app, name: "iPad caret before scrolling")
        dragEditor(editor)

        XCTAssertTrue(app.keyboards.firstMatch.exists)
        capture(app, name: "iPad caret scrolled offscreen")
        app.typeText(" resumed")
        let typingAtCaret = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value ENDSWITH %@", "Line 40 resumed"),
            object: editor
        )
        XCTAssertEqual(XCTWaiter.wait(for: [typingAtCaret], timeout: 5), .completed)
        XCTAssertEqual(editor.value as? String, lines + " resumed")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 2))
        capture(app, name: "iPad typing reveals caret after scrolling")
    }

    func testWritingControlsContinueListsAndSwitchModes() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launch()
        let newItem = app.buttons["notebook-new-item"]
        XCTAssertTrue(newItem.waitForExistence(timeout: 15))
        newItem.tap()
        commitDefaultTitle(in: app)
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText("* Moon\n")
        XCTAssertEqual(editor.value as? String, "* Moon\n* ")
        editor.typeText("Orbit")
        let bold = app.buttons["editor-command-bold"]
        XCTAssertTrue(bold.waitForExistence(timeout: 5))
        XCTAssertLessThan(bold.frame.midY, app.keyboards.firstMatch.frame.minY)
        let toolbarButtons = [
            "editor-command-indent", "editor-command-outdent",
            "editor-command-bold", "editor-command-italic", "editor-formatting",
        ].map { app.buttons[$0] }
        let centers = toolbarButtons.map { $0.frame.midX }
        let spacing = centers[1] - centers[0]
        XCTAssertGreaterThan(spacing, 44)
        for index in 1..<centers.count {
            XCTAssertEqual(centers[index] - centers[index - 1], spacing, accuracy: 2)
        }
        bold.tap()
        editor.typeText("bright")
        XCTAssertTrue((editor.value as? String)?.contains("**bright**") == true)
        app.buttons["editor-formatting"].tap()
        let highlight = app.cells["editor-command-highlight"]
        XCTAssertTrue(highlight.waitForExistence(timeout: 5))
        XCTAssertLessThan(highlight.frame.maxY, app.keyboards.firstMatch.frame.minY)
        highlight.tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        editor.typeText("glow")
        XCTAssertTrue((editor.value as? String)?.contains("==glow==") == true)
        let source = try XCTUnwrap(editor.value as? String)
        dragEditor(editor)
        app.buttons["notebook-note-actions"].tap()
        app.buttons["Source"].tap()
        XCTAssertEqual(editor.value as? String, source)
        capture(app, name: "Writing tools in Source mode")
        app.buttons["notebook-note-actions"].tap()
        app.buttons["Live Preview"].tap()
        XCTAssertEqual(editor.value as? String, source)
        capture(app, name: "Writing tools in Live Preview")
    }

    func testTypingStrikethroughAfterBoldRemainsResponsive() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "livePreview"]
        app.launch()
        let editor = openToolbarTestNote(app)
        editor.typeText("**B** ")
        editor.typeText("~")
        editor.typeText("~")
        editor.typeText("orbit~~ continues")
        XCTAssertEqual(editor.value as? String, "**B** ~~orbit~~ continues")
        capture(app, name: "Typing after bold and strikethrough")
    }

    func testLivePreviewListAndQuotePresentationPreservesSource() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "livePreview"]
        app.launch()
        let editor = openToolbarTestNote(app)
        editor.typeText("* Moon\nOrbit\n\n> Sky\nLight\n\nPlain")
        let source = try XCTUnwrap(editor.value as? String)
        XCTAssertTrue(source.contains("* Moon"))
        XCTAssertTrue(source.contains("> Sky"))
        capture(app, name: "Live Preview native bullets and quote rail")
        dragEditor(editor)
        XCTAssertEqual(editor.value as? String, source)
        capture(app, name: "Preview markers after keyboard dismissal")
        app.buttons["notebook-note-actions"].tap()
        app.buttons["Source"].tap()
        XCTAssertEqual(editor.value as? String, source)
        capture(app, name: "Original list and quote source markers")
    }

    func testFontPickerPreservesNoteAndShowsChoices() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launch()
        let editor = openToolbarTestNote(app)
        editor.typeText("A fictional font sample")
        let source = try XCTUnwrap(editor.value as? String)
        dragEditor(editor)
        app.buttons["notebook-note-actions"].tap()
        app.buttons["Font & Text Size…"].tap()
        let picker = app.buttons["editor-font-family"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        app.buttons["Serif"].tap()
        XCTAssertEqual(editor.value as? String, source)
        capture(app, name: "Native font and text size settings")
    }

    func testToolbarOrderPersistsWithoutChangingNote() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launch()
        let editor = openToolbarTestNote(app)
        editor.typeText("Fictional toolbar sample")
        let source = try XCTUnwrap(editor.value as? String)
        let more = app.buttons["editor-formatting"]
        more.tap()
        app.cells["editor-reset-toolbar-order"].tap()
        XCTAssertTrue(app.cells["editor-reset-toolbar-order"].waitForNonExistence(timeout: 5))
        let bold = app.buttons["editor-command-bold"]
        let indent = app.buttons["editor-command-indent"]
        capture(app, name: "Formatting bar before reorder")
        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: bold.frame.midX, dy: bold.frame.midY))
        let end = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: indent.frame.midX, dy: indent.frame.midY))
        start.press(forDuration: 0.8, thenDragTo: end)
        XCTAssertLessThan(bold.frame.midX, indent.frame.midX)
        XCTAssertEqual(editor.value as? String, source)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        capture(app, name: "Reordered formatting bar")
        app.terminate()
        app.launch()
        _ = openToolbarTestNote(app)
        XCTAssertLessThan(bold.frame.midX, indent.frame.midX)
        more.tap()
        app.cells["editor-reset-toolbar-order"].tap()
        XCTAssertTrue(app.cells["editor-reset-toolbar-order"].waitForNonExistence(timeout: 5))
        XCTAssertLessThan(indent.frame.midX, bold.frame.midX)
    }

    private func openToolbarTestNote(_ app: XCUIApplication) -> XCUIElement {
        let newItem = app.buttons["notebook-new-item"]
        XCTAssertTrue(newItem.waitForExistence(timeout: 15))
        newItem.tap()
        commitDefaultTitle(in: app)
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        return editor
    }

    private func commitDefaultTitle(in app: XCUIApplication) {
        let titleField = app.textFields["title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 10))
        #if os(macOS)
        titleField.typeKey(.return, modifierFlags: [])
        #else
        titleField.typeText("\n")
        #endif
    }

    private func dragEditor(_ editor: XCUIElement) {
        let start = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let end = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
