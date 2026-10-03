import XCTest

#if os(iOS)
final class NotebookOfflineUITests: XCTestCase {
    func testFreshOfflineNotebookCanWriteAndReopenWithoutSetup() throws {
        let app = offlineApp()
        app.launch()
        XCTAssertTrue(app.buttons["notebook-new-item"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Notebook unavailable"].exists)
        app.buttons["notebook-sync-details"].tap()
        XCTAssertTrue(app.staticTexts["sync-local-saving-explanation"].waitForExistence(timeout: 10))
        app.buttons["notebook-sync-details-close"].tap()
        let closed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.buttons["sync-now"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)

        let editor = try app.openOrCreateNotebookEditor(timeout: 10)
        editor.tap()
        let text = "# Offline first\n\nWritten before iCloud. Café 👋🏽\n"
        editor.typeText(text)
        XCTAssertEqual(editor.value as? String, text)
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.tap()
        let notes = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "notebook-sidebar-note-"))
        XCTAssertTrue(notes.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(notes.count, 1)
        let noteID = notes.firstMatch.identifier
        app.terminate()
        app.launch()
        let savedNote = app.descendants(matching: .any)
            .matching(identifier: noteID).firstMatch
        XCTAssertTrue(savedNote.waitForExistence(timeout: 15))
        savedNote.tap()
        let reopened = app.textViews["markdown-editor"]
        XCTAssertTrue(reopened.waitForExistence(timeout: 10))
        XCTAssertEqual(reopened.value as? String, text)
        app.terminate()
    }

    private func offlineApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "0"
        app.launchEnvironment["MEH_SYNC_CLOUDKIT"] = "0"
        app.launchEnvironment["MEH_SYNC_TEST_TRANSPORT"] = "loopback"
        // A closed local endpoint exercises unavailable sync without an
        // account, external network, or another test's service/data.
        app.launchEnvironment["MEH_SYNC_URL"] = "http://127.0.0.1:1"
        app.launchEnvironment["MEH_SYNC_WORKSPACE"] = "OfflineUI-\(UUID().uuidString)"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "1"
        return app
    }
}
#endif
