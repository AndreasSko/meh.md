import XCTest

#if os(iOS)
final class FolderNavigationUITests: XCTestCase {
    func testFolderTitleTogglesUnlessSelectingItems() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launch()

        let menu = app.buttons["notebook-app-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.tap()
        app.buttons["New Folder"].tap()
        let nameField = app.textFields["Name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.typeText("\n")

        let title = app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
                        "notebook-sidebar-title-", "Untitled Folder")
        ).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let id = title.identifier.replacingOccurrences(
            of: "notebook-sidebar-title-", with: ""
        )
        let disclosure = app.buttons["notebook-disclosure-" + id]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        XCTAssertEqual(disclosure.value as? String, "Collapsed")

        title.tap()
        XCTAssertEqual(disclosure.value as? String, "Expanded")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Folder expanded by title tap"
        attachment.lifetime = .keepAlways
        add(attachment)
        title.tap()
        XCTAssertEqual(disclosure.value as? String, "Collapsed")

        // The Files row spans the sidebar, so its width tracks the column.
        let files = app.buttons["notebook-tree-toggle"]
        let sidebarWidth = files.frame.width
        menu.tap()
        app.buttons["notebook-select-items"].tap()
        title.tap()
        XCTAssertTrue(app.buttons["1 selected"].waitForExistence(timeout: 5))
        XCTAssertEqual(disclosure.value as? String, "Collapsed")
        XCTAssertEqual(files.frame.width, sidebarWidth, "Select mode resized the sidebar")

        // The folder is the only item, so the wider Deselect All shows.
        XCTAssertEqual(app.buttons["notebook-select-all"].label, "Deselect All")
        let done = app.buttons["notebook-selection-done"]
        XCTAssertTrue(done.isHittable, "Deselect All pushed Done out of the toolbar")
        done.tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertEqual(files.frame.width, sidebarWidth, "Leaving Select mode resized the sidebar")
    }
}
#endif
