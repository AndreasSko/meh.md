import XCTest

#if os(iOS)
@MainActor
final class NotebookTemplatesUITests: XCTestCase {
    private let meetingBody = "# Meeting\n\n## Agenda\nProject update\n\n## Decisions\nNext steps"

    func testTemplateMenuAvailabilityTracksUsableNotes() throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launch()
        XCTAssertTrue(app.buttons["notebook-app-menu"].waitForExistence(timeout: 15))
        app.buttons["notebook-new-item"].firstMatch.press(forDuration: 1)
        let templateAction = app.buttons["notebook-new-from-template"]
        XCTAssertTrue(app.buttons["New from Template…"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["New from Template…"].isEnabled)
        // The plus button itself is labelled New Note too.
        let menuNewNote = app.buttons.matching(NSPredicate(
            format: "label == %@ AND identifier != %@", "New Note", "notebook-new-item"
        )).firstMatch
        XCTAssertTrue(menuNewNote.isEnabled)
        menuNewNote.tap()
        commitBlankNote(in: app)
        XCTAssertEqual(app.textViews["markdown-editor"].value as? String, "")
        showFiles(app)

        createNote(in: app, named: "Meeting", body: meetingBody)
        showFiles(app)
        let sourceID = itemID(named: "Meeting", in: app)
        markTemplate(sourceID, named: "Meeting", in: app)
        app.buttons["notebook-new-item"].firstMatch.press(forDuration: 1)
        let plusTemplateAction = app.buttons["New from Template…"]
        XCTAssertTrue(plusTemplateAction.waitForExistence(timeout: 5))
        XCTAssertTrue(plusTemplateAction.isEnabled)
        plusTemplateAction.tap()
        XCTAssertTrue(app.buttons["notebook-template-choice-" + sourceID]
            .waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        app.buttons["notebook-app-menu"].tap()
        XCTAssertTrue(templateAction.waitForExistence(timeout: 5))
        XCTAssertTrue(templateAction.isEnabled)
        templateAction.tap()
        XCTAssertTrue(app.buttons["notebook-template-choice-" + sourceID]
            .waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()

        openTemplatesSettings(app)
        app.buttons["notebook-template-options-" + sourceID].tap()
        app.buttons["Remove from Templates"].tap()
        closeTemplatesSettings(app)
        app.buttons["notebook-app-menu"].tap()
        XCTAssertTrue(templateAction.waitForExistence(timeout: 5))
        XCTAssertFalse(templateAction.isEnabled)
        app.buttons["New Folder"].tap()
        let folderName = app.textFields["Name"]
        XCTAssertTrue(folderName.waitForExistence(timeout: 5))
        folderName.typeText("Empty Templates\n")
        let folderID = itemID(named: "Empty Templates", in: app)
        markTemplate(folderID, named: "Empty Templates", in: app)
        app.buttons["notebook-app-menu"].tap()
        XCTAssertTrue(templateAction.waitForExistence(timeout: 5))
        XCTAssertFalse(templateAction.isEnabled,
                       "An empty registered folder offers no usable template")
    }

    func testAppIconTemplateAndNewNoteShortcuts() throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launch()
        createNote(in: app, named: "Meeting", body: meetingBody)
        showFiles(app)
        let sourceID = itemID(named: "Meeting", in: app)
        markTemplate(sourceID, named: "Meeting", in: app)
        openTemplatesSettings(app)

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        openAppIconMenu(springboard)
        let fromTemplate = springboard.buttons["New from Template"]
        XCTAssertTrue(fromTemplate.waitForExistence(timeout: 5))
        XCTAssertTrue(springboard.buttons["New Note"].exists)
        fromTemplate.tap()
        let choice = app.buttons["notebook-template-choice-" + sourceID]
        XCTAssertTrue(choice.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["notebook-template-options-" + sourceID].exists,
                       "The app-icon shortcut must dismiss existing Settings")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["notebook-app-menu"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@",
            "notebook-sidebar-title-", "Meeting"
        )).count, 1, "Opening the template picker must not create a note")

        openAppIconMenu(springboard)
        XCTAssertTrue(fromTemplate.waitForExistence(timeout: 5))
        fromTemplate.tap()
        XCTAssertTrue(choice.waitForExistence(timeout: 10))
        choice.tap()
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, meetingBody)
        XCTAssertNotEqual(app.buttons["note-title"].label, "Meeting")

        // The editor's ordinary plus tap must stay immediate after adding
        // feedback to its long press.
        app.buttons["notebook-new-item"].firstMatch.tap()
        commitBlankNote(in: app)
        XCTAssertEqual(editor.value as? String, "")

        openAppIconMenu(springboard)
        let newNote = springboard.buttons["New Note"]
        XCTAssertTrue(newNote.waitForExistence(timeout: 5))
        newNote.tap()
        commitBlankNote(in: app)
        XCTAssertEqual(editor.value as? String, "",
                       "The existing app-icon New Note shortcut must remain intact")
    }

    func testTemplateDefaultsCreateIndependentNoteAndPersist() throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launch()
        createNote(in: app, named: "Meeting", body: meetingBody)
        showFiles(app)
        let sourceID = itemID(named: "Meeting", in: app)
        markTemplate(sourceID, named: "Meeting", in: app)

        openTemplatesSettings(app)
        let sourceOptions = app.buttons["notebook-template-options-" + sourceID]
        XCTAssertTrue(sourceOptions.waitForExistence(timeout: 5))
        closeTemplatesSettings(app)

        createFolder(in: app, named: "Meetings")
        let destinationID = itemID(named: "Meetings", in: app)
        openTemplatesSettings(app)
        sourceOptions.tap()
        chooseDestination("Meetings", in: app)
        enableCustomFilename(app)
        replaceText(app.textFields["template-filename-pattern"],
                    with: "{{date}} — {{template}}", in: app)
        app.buttons["notebook-save-template-options"].tap()
        XCTAssertTrue(sourceOptions.waitForExistence(timeout: 5))
        closeTemplatesSettings(app)

        // A second launch verifies these are saved notebook settings.
        app.terminate()
        app.launch()
        XCTAssertTrue(fileTitle("Meeting", in: app).waitForExistence(timeout: 15))
        fileTitle("Meeting", in: app).tap()
        XCTAssertTrue(app.textViews["markdown-editor"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["notebook-new-item"].firstMatch
            .waitForExistence(timeout: 15))
        app.buttons["notebook-new-item"].firstMatch.press(forDuration: 1)
        app.buttons["New from Template…"].tap()
        let choice = app.buttons["notebook-template-choice-" + sourceID]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["template-destination"].exists)
        XCTAssertEqual(editor.value as? String, meetingBody)
        let copyName = app.buttons["note-title"].label
        XCTAssertNotNil(copyName.range(
            of: "^[0-9]{4}-[0-9]{2}-[0-9]{2} — Meeting$",
            options: .regularExpression
        ), "Selecting a template should immediately use its saved filename pattern")
        editor.tap()
        editor.typeText("Edited copy. ")
        XCTAssertNotEqual(editor.value as? String, meetingBody)
        showFiles(app)
        XCTAssertTrue(fileTitle(copyName, in: app).waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
            "notebook-sidebar-title-", copyName
        )).count, 1, "Selecting a template must create exactly one copy")
        app.buttons["notebook-disclosure-" + destinationID].tap()
        XCTAssertFalse(fileTitle(copyName, in: app).exists,
                       "The template default must place the copy in Meetings")
        fileTitle("Meeting", in: app).tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, meetingBody,
                       "Template registration and copy editing must preserve source Markdown")
    }

    func testTemplateFolderDiscoversNestedNotesAndCombinesSources() throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launch()
        createNote(in: app, named: "Meeting", body: meetingBody)
        showFiles(app)
        let meetingID = itemID(named: "Meeting", in: app)
        markTemplate(meetingID, named: "Meeting", in: app)
        createFolder(in: app, named: "Templates")
        let folderID = itemID(named: "Templates", in: app)
        createFolder(in: app, named: "Recurring", parent: "Templates")
        createNote(in: app, named: "Journal", body: "# Journal\n\nToday: ",
                   parent: "Recurring")
        showFiles(app)
        let journalID = itemID(named: "Journal", in: app)
        markTemplate(folderID, named: "Templates", in: app)
        // Explicit registration and recursive discovery must yield one choice.
        markTemplate(journalID, named: "Journal", in: app)
        openTemplatesSettings(app)
        let journalOptions = app.buttons["notebook-template-options-" + journalID]
        XCTAssertTrue(journalOptions.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(
            identifier: "notebook-template-options-" + journalID).count, 1)
        XCTAssertTrue(app.buttons["notebook-template-options-" + meetingID].exists)
        XCTAssertTrue(app.buttons[
            "notebook-template-folder-options-" + folderID].exists)
        app.buttons["notebook-template-folder-options-" + folderID].tap()
        chooseDestination("Templates", in: app)
        enableCustomFilename(app)
        replaceText(app.textFields["template-filename-pattern"],
                    with: "Folder {{template}}", in: app)
        app.buttons["notebook-save-template-options"].tap()
        journalOptions.tap()
        let inheritedPreview = app.descendants(matching: .any).matching(
            identifier: "notebook-template-filename-preview"
        ).firstMatch
        let inheritedName = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                   "Folder Journal.md", "Folder Journal.md"),
            object: inheritedPreview
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [inheritedName], timeout: 5), .completed,
            "Nested notes should inherit their template folder filename"
        )
        chooseDestination("Top Level", in: app)
        enableCustomFilename(app)
        replaceText(app.textFields["template-filename-pattern"],
                    with: "Journal entry", in: app)
        app.buttons["notebook-save-template-options"].tap()
        closeTemplatesSettings(app)
        app.buttons["notebook-app-menu"].tap()
        app.buttons["notebook-new-from-template"].tap()
        let journalChoice = app.buttons["notebook-template-choice-" + journalID]
        XCTAssertTrue(journalChoice.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(
            identifier: "notebook-template-choice-" + journalID).count, 1)
        journalChoice.tap()
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["template-destination"].exists)
        XCTAssertEqual(app.buttons["note-title"].label, "Journal entry")
        XCTAssertEqual(editor.value as? String, "# Journal\n\nToday: ")
        showFiles(app)
        app.buttons["notebook-disclosure-" + folderID].tap()
        XCTAssertTrue(fileTitle("Journal entry", in: app).exists,
                      "An individual destination override must place the copy at the top level")
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "source"]
        return app
    }

    private func openAppIconMenu(_ springboard: XCUIApplication) {
        let icon = springboard.icons.matching(NSPredicate(
            format: "label == %@ OR label == %@", "meh.md", "meh.md iCloud Dev"
        )).firstMatch
        // A press while the Home Screen still settles can miss the menu, so
        // go Home and press again until it opens.
        for _ in 0..<3 {
            XCUIDevice.shared.press(.home)
            if !icon.waitForExistence(timeout: 3) || !icon.isHittable {
                springboard.swipeLeft()
            }
            XCTAssertTrue(icon.waitForExistence(timeout: 5))
            XCTAssertTrue(icon.isHittable)
            icon.press(forDuration: 1)
            if springboard.buttons["New Note"].waitForExistence(timeout: 5) { return }
        }
        XCTFail("Expected the app icon's quick actions")
    }

    private func commitBlankNote(in app: XCUIApplication) {
        let title = app.textFields["title-field"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        title.typeText("\n")
        XCTAssertTrue(app.textViews["markdown-editor"].waitForExistence(timeout: 5))
    }

    private func createNote(in app: XCUIApplication, named name: String,
                            body: String, parent: String? = nil) {
        if let parent {
            app.chooseRowAction("New Note", on: fileTitle(parent, in: app))
        } else {
            let newNote = app.buttons["notebook-new-item"].firstMatch
            XCTAssertTrue(newNote.waitForExistence(timeout: 15))
            newNote.tap()
        }
        let title = app.textFields["title-field"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        replaceText(title, with: name, in: app)
        title.typeText("\n")
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.typeText(body)
        XCTAssertEqual(editor.value as? String, body)
    }

    private func createFolder(in app: XCUIApplication, named name: String,
                              parent: String? = nil) {
        if let parent {
            app.chooseRowAction("New Folder", on: fileTitle(parent, in: app))
        } else {
            app.buttons["notebook-app-menu"].tap()
            app.buttons["New Folder"].tap()
        }
        let field = app.textFields["Name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(name + "\n")
        XCTAssertTrue(fileTitle(name, in: app).waitForExistence(timeout: 5))
    }

    private func replaceText(_ field: XCUIElement, with text: String,
                             in app: XCUIApplication) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                              count: (field.value as? String ?? "").count + 4))
        field.typeText(text)
        if field.value as? String != text {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                                  count: (field.value as? String ?? "").count + 4))
            field.typeText(text)
        }
        XCTAssertEqual(field.value as? String, text)
    }

    private func markTemplate(_ id: String, named name: String,
                              in app: XCUIApplication) {
        app.withoutIdleWait {
            fileTitle(name, in: app).press(forDuration: 1)
            let submenu = app.buttons["Templates & Snippets"].firstMatch
            XCTAssertTrue(submenu.waitForExistence(timeout: 5))
            submenu.tap()
            let identified = app.buttons["notebook-use-as-template-" + id]
            let action = identified.waitForExistence(timeout: 1) ? identified
                : app.buttons.matching(NSPredicate(
                    format: "label == %@ OR label == %@",
                    "Use as Template", "Use as Template Folder"
                )).firstMatch
            XCTAssertTrue(action.waitForExistence(timeout: 5))
            action.tap()
        }
    }

    private func fileTitle(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@",
            "notebook-sidebar-title-", name
        )).firstMatch
    }

    private func itemID(named name: String, in app: XCUIApplication) -> String {
        let title = fileTitle(name, in: app)
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        return title.identifier.replacingOccurrences(of: "notebook-sidebar-title-",
                                                     with: "")
    }

    private func showFiles(_ app: XCUIApplication) {
        if !app.buttons["notebook-app-menu"].isHittable {
            app.navigationBars.buttons.firstMatch.tap()
        }
        XCTAssertTrue(app.buttons["notebook-app-menu"].waitForExistence(timeout: 5))
    }

    private func openTemplatesSettings(_ app: XCUIApplication) {
        app.openNotebookSettings()
        app.buttons["notebook-templates-settings"].tap()
    }

    private func closeTemplatesSettings(_ app: XCUIApplication) {
        let templates = app.navigationBars["Templates & Snippets"]
        XCTAssertTrue(templates.waitForExistence(timeout: 5))
        templates.buttons.firstMatch.tap()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(app.buttons["notebook-app-menu"].waitForExistence(timeout: 5))
    }

    private func chooseDestination(_ name: String, in app: XCUIApplication) {
        app.buttons["template-destination"].tap()
        let choice = app.collectionViews.buttons[name].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
    }

    private func enableCustomFilename(_ app: XCUIApplication) {
        let toggle = app.switches["notebook-template-custom-filename"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
    }
}
#endif
