import XCTest

final class NoteHistoryUITests: XCTestCase {
    func testRestoreAsNewNoteKeepsOriginalCurrentText() throws {
#if os(macOS)
        throw XCTSkip("Restore as New Note navigation is covered on iPhone")
#else
        continueAfterFailure = false
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_NOTEBOOK_TEST_FIXTURE"] = "history-restore"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchEnvironment["MEH_SYNC_CLOUDKIT"] = "0"
        app.launchArguments += ["-editor.mode", "source"]
        app.launch()
        let title = "Recovery Sketch"
        let firstBody = "Morning light over the ridge."
        let currentBody = firstBody + "\nClear."
        let originalTitle = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (label == %@ OR value == %@)",
            "notebook-sidebar-title-", title, title
        )).firstMatch
        XCTAssertTrue(originalTitle.waitForExistence(timeout: 15))
        let originalID = originalTitle.identifier.replacingOccurrences(
            of: "notebook-sidebar-title-", with: ""
        )
        XCTAssertNotNil(UUID(uuidString: originalID))
        originalTitle.tap()
        let editor = app.textViews["markdown-editor"]
        waitForPreview(currentBody, in: editor)
        app.buttons["notebook-note-actions"].tap()
        let history = app.descendants(matching: .any)
            .matching(identifier: "notebook-version-history").firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        history.tap()
        let preview = app.textViews["note-history-preview"]
        waitForPreview(currentBody, in: preview)
        let previous = app.buttons["note-history-previous"]
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true"),
            object: previous
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        previous.tap()
        waitForPreview(firstBody, in: preview)
        app.buttons["note-history-restore"].tap()
        app.buttons["Restore This Note…"].tap()
        XCTAssertTrue(app.buttons["Restore This Note"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].firstMatch.tap()
        waitForPreview(firstBody, in: preview)
        app.buttons["note-history-restore"].tap()
        app.buttons["Restore as New Note"].tap()
        waitForPreview(firstBody, in: editor)
        XCTAssertEqual(app.buttons["note-title"].label, title + " (Restored)")
        app.revealNotebookSidebar()
        let restoredTitle = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (label == %@ OR value == %@)",
            "notebook-sidebar-title-", title + " (Restored)", title + " (Restored)"
        )).firstMatch
        XCTAssertTrue(restoredTitle.waitForExistence(timeout: 5))
        XCTAssertNotEqual(restoredTitle.identifier,
                          "notebook-sidebar-title-" + originalID)
        let original = app.staticTexts["notebook-sidebar-title-" + originalID]
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        original.tap()
        waitForPreview(currentBody, in: editor)
        XCTAssertEqual(app.buttons["note-title"].label, title)
#endif
    }

    private func waitForPreview(_ text: String, in preview: XCUIElement) {
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", text), object: preview
        )
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 10), .completed)
    }

}
