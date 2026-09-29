import XCTest

final class NotebookMenuCommandsUITests: XCTestCase {
    func testKeyboardShortcutsCreateNotesAndFolders() throws {
        continueAfterFailure = false
        #if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Menu shortcuts need a hardware keyboard layout")
        }
        #endif
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launch()
        XCTAssertTrue(app.buttons["notebook-new-item"].firstMatch
            .waitForExistence(timeout: 15))
        #if os(macOS)
        let windows = app.windows.count
        #endif

        // Command-N creates a note in this window instead of a new window.
        app.typeKey("n", modifierFlags: .command)
        let title = app.textFields["title-field"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        #if os(macOS)
        XCTAssertEqual(app.windows.count, windows)
        #endif
        capture(app, name: "command-n-new-note")
        title.typeText("\n")

        app.typeKey("n", modifierFlags: [.command, .shift])
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText("Menu Folder\n")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@",
            "notebook-sidebar-title-", "Menu Folder"
        )).firstMatch.waitForExistence(timeout: 5))
    }

    #if os(macOS)
    func testMenuBarListsNotebookCommands() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launch()
        XCTAssertTrue(app.buttons["notebook-new-item"].firstMatch
            .waitForExistence(timeout: 15))

        app.menuBars.menuBarItems["File"].click()
        XCTAssertTrue(app.menuItems["New Note"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["New Folder"].exists)
        XCTAssertTrue(app.menuItems["New Window"].exists)
        capture(app, name: "file-menu")
        app.typeKey(.escape, modifierFlags: [])

        app.menuBars.menuBarItems["Edit"].click()
        XCTAssertTrue(app.menuItems["Move…"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Move to Trash"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }
    #endif

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
