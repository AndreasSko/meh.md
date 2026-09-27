#if os(macOS)
import XCTest

final class NotebookMacMenuUITests: XCTestCase {
    func testNewNoteAndSettingsMenusPreserveWriting() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "source"]
        app.launch()

        XCTAssertTrue(
            app.buttons["notebook-new-item"].firstMatch.waitForExistence(timeout: 15)
        )
        let fileMenu = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 5))
        fileMenu.click()
        let newNoteItem = app.menuItems["New Note"]
        XCTAssertTrue(newNoteItem.waitForExistence(timeout: 5))
        XCTAssertTrue(newNoteItem.isEnabled)
        newNoteItem.click()
        let titleField = app.textFields["title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 10))
        let title = "Fictional Mac menu note " + UUID().uuidString.prefix(8)
        titleField.typeKey("a", modifierFlags: .command)
        titleField.typeText(title)
        titleField.typeKey(.return, modifierFlags: [])

        let noteTitle = app.buttons["note-title"]
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(noteTitle.waitForExistence(timeout: 5))
        XCTAssertEqual(noteTitle.label, title)
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let body = "A fictional observation written before opening Settings."
        editor.typeText(body)
        XCTAssertEqual(editor.value as? String, body)

        let noteCount = sidebarNoteCount(in: app)
        XCTAssertEqual(noteCount, 1)

        let appMenu = app.menuBars.menuBarItems["meh.md"]
        XCTAssertTrue(appMenu.waitForExistence(timeout: 5))
        appMenu.click()
        let settingsItem = app.menuItems["Settings…"]
        XCTAssertTrue(settingsItem.waitForExistence(timeout: 5))
        settingsItem.click()
        let export = app.buttons["notebook-export"]
        XCTAssertTrue(export.waitForExistence(timeout: 10))
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(export.exists)
        app.buttons["Done"].click()
        XCTAssertFalse(export.waitForExistence(timeout: 1))
        XCTAssertEqual(sidebarNoteCount(in: app), noteCount)
        XCTAssertEqual(noteTitle.label, title)
        XCTAssertEqual(editor.value as? String, body)

        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(titleField.waitForExistence(timeout: 10))
        let shortcutTitle = "Fictional keyboard note " + UUID().uuidString.prefix(8)
        titleField.typeKey("a", modifierFlags: .command)
        titleField.typeText(shortcutTitle)
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(export.waitForExistence(timeout: 10))
        app.buttons["Done"].click()
        XCTAssertTrue(noteTitle.waitForExistence(timeout: 5))
        XCTAssertEqual(noteTitle.label, shortcutTitle)
        XCTAssertEqual(sidebarNoteCount(in: app), 2)
    }

    private func sidebarNoteCount(in app: XCUIApplication) -> Int {
        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@", "notebook-sidebar-note-"
            )
        ).count
    }
}
#endif
