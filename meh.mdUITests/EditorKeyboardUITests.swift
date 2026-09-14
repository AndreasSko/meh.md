import XCTest

#if os(iOS)
final class EditorKeyboardUITests: XCTestCase {
    func testScrollDismissesKeyboardAndEditingCanResume() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launch()
        let newItem = app.buttons["notebook-new-item"]
        XCTAssertTrue(newItem.waitForExistence(timeout: 15))
        newItem.tap()
        app.buttons["New Note"].tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText("Keyboard regression\n")
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
