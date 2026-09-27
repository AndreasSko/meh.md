import XCTest

#if os(iOS)
final class NewNoteDestinationUITests: XCTestCase {
    func testFolderBecomesDefaultForMainNewNoteButton() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "source"]
        app.launch()

        XCTAssertTrue(app.buttons["notebook-new-item"].firstMatch
            .waitForExistence(timeout: 15))
        app.buttons["notebook-app-menu"].tap()
        app.buttons["New Folder"].tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText("Inbox\n")

        let folderTitle = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@",
            "notebook-sidebar-title-", "Inbox"
        )).firstMatch
        XCTAssertTrue(folderTitle.waitForExistence(timeout: 5))
        let folderID = folderTitle.identifier.replacingOccurrences(
            of: "notebook-sidebar-title-", with: ""
        )
        folderTitle.press(forDuration: 1.0)
        let useForNewNotes = app.buttons["Use for New Notes"]
        XCTAssertTrue(useForNewNotes.waitForExistence(timeout: 5))
        useForNewNotes.tap()

        app.buttons["notebook-new-item"].firstMatch.tap()
        let title = app.textFields["title-field"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        let noteName = title.value as? String ?? ""
        XCTAssertFalse(noteName.isEmpty)
        title.typeText("\n")
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()

        let note = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@",
            "notebook-sidebar-title-", noteName
        )).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        app.buttons["notebook-disclosure-" + folderID].tap()
        XCTAssertFalse(note.exists)
        app.buttons["notebook-disclosure-" + folderID].tap()
        XCTAssertTrue(note.waitForExistence(timeout: 5))

        folderTitle.press(forDuration: 1.0)
        let useRoot = app.buttons["Use Root for New Notes"]
        XCTAssertTrue(useRoot.waitForExistence(timeout: 5))
        useRoot.tap()
        folderTitle.press(forDuration: 1.0)
        XCTAssertTrue(useForNewNotes.waitForExistence(timeout: 5))
    }
}
#endif
