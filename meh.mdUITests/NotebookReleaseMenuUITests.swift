#if os(macOS)
import XCTest

@MainActor
final class NotebookReleaseMenuUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] =
            "release-menus-\(UUID().uuidString)"
        app.launchEnvironment["MEH_NOTEBOOK_TEST_FIXTURE"] = "writing"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "source"]
        app.launch()
        let title = "Fictional field notes"
        let titleRow = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (label == %@ OR value == %@)",
            "notebook-sidebar-title-", title, title
        )).firstMatch
        XCTAssertTrue(titleRow.waitForExistence(timeout: 15))
        titleRow.click()
        XCTAssertTrue(app.textViews["markdown-editor"].waitForExistence(timeout: 20))
    }

    override func tearDownWithError() throws {
        if app.state == .runningForeground { app.terminate() }
    }

    func testFileMenuPickersAndNewWindowPreserveWriting() throws {
        let editor = app.textViews["markdown-editor"]
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        let source = "Fictional harbor observations."
        editor.typeText(source)

        openMenu("File")
        for title in ["New Note", "New Folder", "New Window", "Import Markdown…",
                      "Export All Notes…"] {
            XCTAssertTrue(app.menuItems[title].exists, title)
            XCTAssertTrue(app.menuItems[title].isEnabled, title)
        }
        capture("Mac File menu")
        app.menuItems["Import Markdown…"].click()
        cancelPicker()
        editor.click()
        editor.typeText(" Saved after import cancellation.")
        XCTAssertTrue((editor.value as? String)?.contains(source) == true)

        openMenu("File")
        app.menuItems["Export All Notes…"].click()
        cancelPicker()
        openMenu("meh.md iCloud Dev")
        app.menuItems["Settings…"].click()
        let settingsExport = app.buttons["notebook-export"]
        XCTAssertTrue(settingsExport.waitForExistence(timeout: 10))
        settingsExport.click()
        cancelPicker()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertTrue(done.isEnabled,
                      "Cancelling export must re-enable Settings dismissal")
        done.click()
        openMenu("File")
        let newNote = app.menuItems["New Note"]
        XCTAssertTrue(newNote.waitForExistence(timeout: 5))
        XCTAssertTrue(newNote.isEnabled,
                      "Cancelling export must leave File actions available")
        app.typeKey(.escape, modifierFlags: [])
        editor.click()
        editor.typeText(" Saved after export cancellation.")
        XCTAssertTrue((editor.value as? String)?
            .contains("Saved after export cancellation.") == true)

        let windows = app.windows.count
        openMenu("File")
        app.menuItems["New Window"].click()
        let added = NSPredicate { _, _ in self.app.windows.count > windows }
        expectation(for: added, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        capture("Mac second notebook window")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue((app.textViews["markdown-editor"].firstMatch.value as? String)?
            .contains("Saved after export cancellation.") == true)
    }

    func testSelectionCommandsRespectEditorAndTitleFocus() throws {
        let editor = app.textViews["markdown-editor"]
        editor.click()
        assertSelectionCommands(enabled: false)
        app.buttons["note-title"].click()
        XCTAssertTrue(app.textFields["title-field"].waitForExistence(timeout: 5))
        assertSelectionCommands(enabled: false)
        app.textFields["title-field"].typeKey(.return, modifierFlags: [])

        openMenu("File")
        app.menuItems["New Folder"].click()
        let name = app.textFields["notebook-inline-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeKey("a", modifierFlags: .command)
        name.typeText("Fictional project folder\n")
        let folder = app.staticTexts["Fictional project folder"].firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        let browserActions = app.descendants(matching: .any)["notebook-app-menu"]
        XCTAssertTrue(browserActions.waitForExistence(timeout: 5))
        browserActions.click()
        let selectItems = app.descendants(matching: .any)["notebook-select-items"]
        XCTAssertTrue(selectItems.waitForExistence(timeout: 5))
        selectItems.click()
        folder.click()
        app.typeKey("a", modifierFlags: .command)
        XCTAssertTrue(app.buttons["3 selected"].waitForExistence(timeout: 5))
        assertSelectionCommands(enabled: true)
        XCTAssertTrue((editor.value as? String)?.contains("Fictional voyage") == true)
    }

    private func openMenu(_ name: String) {
        let item = app.menuBars.menuBarItems[name]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
    }

    private func assertSelectionCommands(enabled: Bool) {
        openMenu("Edit")
        for title in ["Move Selected…", "Move Selected to Trash"] {
            XCTAssertTrue(app.menuItems[title].waitForExistence(timeout: 5))
            XCTAssertEqual(app.menuItems[title].isEnabled, enabled, title)
        }
        capture(enabled ? "Mac browser selection actions" : "Mac writing actions")
        app.typeKey(.escape, modifierFlags: [])
    }

    private func cancelPicker() {
        let cancel = app.sheets.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 15))
        capture("Mac native Markdown picker")
        cancel.click()
        XCTAssertFalse(cancel.waitForExistence(timeout: 1))
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
