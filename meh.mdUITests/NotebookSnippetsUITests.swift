import XCTest

#if os(iOS)
@MainActor
final class NotebookSnippetsUITests: XCTestCase {
    private let noteSnippet =
        "## {{title}}\n\n{{date}} {{time}} {{unknown}}\n"
    private let folderSnippet =
        "### {{title}} agenda\n\n{{date}} {{time}}\n"

    func testInsertNoteAndNestedFolderSnippets() throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launch()

        createNote(in: app, named: "Reusable intro", body: noteSnippet)
        showFiles(app)
        let noteID = itemID(named: "Reusable intro", in: app)
        markSnippet(noteID, named: "Reusable intro", in: app)

        createFolder(in: app, named: "Work")
        createFolder(in: app, named: "Meetings", parent: "Work")
        let meetingsID = itemID(named: "Meetings", in: app)
        createFolder(in: app, named: "Weekly", parent: "Meetings")
        createNote(in: app, named: "Agenda", body: folderSnippet,
                   parent: "Weekly")
        showFiles(app)
        let workID = itemID(named: "Work", in: app)
        markSnippet(workID, named: "Work", in: app, isFolder: true)

        createNote(in: app, named: "Project notes",
                   body: "# Project notes\n\nNext steps:\n")
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        revealSnippetMenu(in: app)
        capture(app, "snippet-toolbar-after")

        openSnippetMenu(in: app)
        capture(app, "snippet-menu-after")
        chooseMenuItem("Reusable intro", in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let noteBody = editor.value as? String ?? ""
        capture(app, "note-snippet-inserted-after")
        XCTAssertTrue(noteBody.contains("## Project notes\n\n"))
        XCTAssertTrue(noteBody.range(
            of: dateAndTimePattern(suffix: " {{unknown}}"),
            options: .regularExpression
        ) != nil)

        openSnippetMenu(in: app)
        XCTAssertFalse(menuItem("Work", in: app).exists,
                       "A single snippet folder should flatten its root")
        XCTAssertTrue(menuItem("Reusable intro", in: app).exists,
                      "A direct note snippet should stay at the menu root")
        let meetings = menuItem("Meetings", in: app)
        XCTAssertTrue(meetings.waitForExistence(timeout: 5))
        meetings.tap()
        let weekly = menuItem("Weekly", in: app)
        XCTAssertTrue(weekly.waitForExistence(timeout: 5))
        weekly.tap()
        capture(app, "nested-snippet-category-after")
        chooseMenuItem("Agenda", in: app)

        let finalBody = editor.value as? String ?? ""
        XCTAssertTrue(finalBody.contains("## Project notes\n\n"))
        XCTAssertTrue(finalBody.contains("### Project notes agenda\n\n"))
        XCTAssertTrue(finalBody.range(
            of: dateAndTimePattern(suffix: " {{unknown}}"),
            options: .regularExpression
        ) != nil)
        XCTAssertTrue(finalBody.range(
            of: dateAndTimePattern(suffix: ""),
            options: .regularExpression
        ) != nil)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "Inserting a snippet should leave the keyboard open")

        showFiles(app)
        app.terminate()
        app.launch()
        let target = fileTitle("Project notes", in: app)
        XCTAssertTrue(target.waitForExistence(timeout: 15))
        target.tap()
        XCTAssertEqual(app.textViews["markdown-editor"].value as? String,
                       finalBody)

        showFiles(app)
        fileTitle("Reusable intro", in: app).tap()
        XCTAssertEqual(app.textViews["markdown-editor"].value as? String,
                       noteSnippet,
                       "Inserting a snippet must leave its source unchanged")
        showFiles(app)
        let agenda = fileTitle("Agenda", in: app)
        if !agenda.exists {
            if !fileTitle("Meetings", in: app).exists {
                app.buttons["notebook-disclosure-\(workID)"].tap()
            }
            if !fileTitle("Weekly", in: app).exists {
                app.buttons["notebook-disclosure-\(meetingsID)"].tap()
            }
        }
        agenda.tap()
        XCTAssertEqual(app.textViews["markdown-editor"].value as? String,
                       folderSnippet,
                       "Folder snippets must preserve the source note")
    }

    func testInsertSnippetInLivePreview() throws {
        continueAfterFailure = false
        let app = makeApp(mode: "livePreview")
        app.launch()

        let source = "**{{title}}** {{unknown}}"
        createNote(in: app, named: "Live preview snippet", body: source)
        showFiles(app)
        let sourceID = itemID(named: "Live preview snippet", in: app)
        markSnippet(sourceID, named: "Live preview snippet", in: app)
        createNote(in: app, named: "Preview target", body: "Start: ")

        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        revealSnippetMenu(in: app)
        openSnippetMenu(in: app)
        chooseMenuItem("Live preview snippet", in: app)

        let inserted = editor.value as? String ?? ""
        XCTAssertEqual(inserted, "Start: **Preview target** {{unknown}}")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "Live Preview insertion should leave the keyboard open")
        showFiles(app)
        fileTitle("Live preview snippet", in: app).tap()
        XCTAssertEqual(app.textViews["markdown-editor"].value as? String,
                       source,
                       "Live Preview insertion must preserve its source note")
    }

    func testVariableReturnCompletionInLivePreview() throws {
        continueAfterFailure = false
        let app = makeApp(mode: "livePreview")
        app.launch()

        createNote(in: app, named: "Live variable source", body: "")
        showFiles(app)
        let sourceID = itemID(named: "Live variable source", in: app)
        markSnippet(sourceID, named: "Live variable source", in: app)
        fileTitle("Live variable source", in: app).tap()

        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        editor.typeText("{{tit")
        XCTAssertTrue(app.buttons["snippet-variable-title"]
            .waitForExistence(timeout: 5))
        editor.typeText("\n")
        XCTAssertEqual(editor.value as? String, "{{title}}")
        XCTAssertTrue(app.keyboards.firstMatch.exists,
                      "Accepting a variable with Return should keep editing active")
    }

    func testVariableCompletionForNoteAndFolderSnippets() throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launch()

        createNote(in: app, named: "Variable source", body: "")
        showFiles(app)
        let sourceID = itemID(named: "Variable source", in: app)
        markSnippet(sourceID, named: "Variable source", in: app)
        fileTitle("Variable source", in: app).tap()

        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        editor.typeText("{{")
        XCTAssertEqual(editor.value as? String, "{{")
        capture(app, "snippet-variable-popup-attempt")
        XCTAssertTrue(app.buttons["snippet-variable-date"]
            .waitForExistence(timeout: 5))
        capture(app, "snippet-variable-popup-after")
        XCTAssertTrue(app.buttons["snippet-variable-date"].exists)
        XCTAssertTrue(app.buttons["snippet-variable-date:short"].exists)
        XCTAssertTrue(app.buttons["snippet-variable-date:long"].exists)

        editor.typeText("date:")
        XCTAssertTrue(app.buttons["snippet-variable-date:short"]
            .waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["snippet-variable-time"].exists)
        app.buttons["snippet-variable-date:short"].tap()
        XCTAssertEqual(editor.value as? String, "{{date:short}}")
        XCTAssertTrue(app.keyboards.firstMatch.exists,
                      "Choosing a variable should keep the keyboard open")

        showFiles(app)
        createFolder(in: app, named: "Work")
        createFolder(in: app, named: "Meetings", parent: "Work")
        createNote(in: app, named: "Agenda", body: "", parent: "Meetings")
        showFiles(app)
        let workID = itemID(named: "Work", in: app)
        markSnippet(workID, named: "Work", in: app, isFolder: true)
        fileTitle("Agenda", in: app).tap()

        let agenda = app.textViews["markdown-editor"]
        XCTAssertTrue(agenda.waitForExistence(timeout: 5))
        agenda.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        agenda.typeText("{{date:iso")
        XCTAssertEqual(agenda.value as? String, "{{date:iso")
        XCTAssertTrue(app.buttons["snippet-variable-date:iso"]
            .waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["snippet-variable-time"].exists)
        app.buttons["snippet-variable-date:iso"].tap()
        XCTAssertEqual(agenda.value as? String, "{{date:iso}}")
        XCTAssertTrue(app.keyboards.firstMatch.exists,
                      "Choosing a folder variable should keep editing active")
    }

    func testOrdinaryNoteKeepsLinkCompletionWithoutVariableSuggestions() throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launch()

        createNote(in: app, named: "Link target", body: "Target text")
        showFiles(app)
        createNote(in: app, named: "Ordinary note", body: "See [[Link")
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let linkSuggestion = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "link-suggestion-"
        )).firstMatch
        XCTAssertTrue(linkSuggestion.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["snippet-variable-date"].exists)

        editor.typeText("\n{{")
        XCTAssertFalse(app.buttons["snippet-variable-date"].exists)
        XCTAssertTrue((editor.value as? String ?? "").contains("{{"),
                      "Ordinary notes should retain literal braces")
    }

    func testMultipleSnippetFolderRootsKeepTheirNames() throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launch()

        createFolder(in: app, named: "Work")
        createFolder(in: app, named: "Meetings", parent: "Work")
        createNote(in: app, named: "Agenda", body: "",
                   parent: "Meetings")
        showFiles(app)
        markSnippet(itemID(named: "Work", in: app), named: "Work", in: app,
                    isFolder: true)

        createFolder(in: app, named: "Home")
        createFolder(in: app, named: "Journal", parent: "Home")
        createNote(in: app, named: "Entry", body: "", parent: "Journal")
        showFiles(app)
        markSnippet(itemID(named: "Home", in: app), named: "Home", in: app,
                    isFolder: true)

        createNote(in: app, named: "Target", body: "")
        openSnippetMenu(in: app)
        XCTAssertTrue(menuItem("Work", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(menuItem("Home", in: app).exists)
    }

    func testSnippetOverviewShowsEffectiveSourcesAndTemplateSeparation() throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launch()

        createFolder(in: app, named: "Work")
        createFolder(in: app, named: "Meetings", parent: "Work")
        createNote(in: app, named: "Agenda", body: "Agenda source",
                   parent: "Meetings")
        showFiles(app)
        let workID = itemID(named: "Work", in: app)
        let agendaID = itemID(named: "Agenda", in: app)
        markSnippet(workID, named: "Work", in: app, isFolder: true)

        createNote(in: app, named: "Quick intro", body: "Direct source")
        showFiles(app)
        let introID = itemID(named: "Quick intro", in: app)
        markSnippet(introID, named: "Quick intro", in: app)

        createNote(in: app, named: "Template only", body: "Template source")
        showFiles(app)
        let templateID = itemID(named: "Template only", in: app)
        markTemplate(templateID, named: "Template only", in: app)

        openSnippetSettings(app)
        capture(app, "snippet-overview-after")
        let folder = app.buttons["notebook-snippet-folder-overview-" + workID]
        let agenda = app.buttons["notebook-snippet-overview-" + agendaID]
        let intro = app.buttons["notebook-snippet-overview-" + introID]
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        XCTAssertTrue(folder.label.contains("Work"))
        XCTAssertTrue(agenda.exists,
                      "Folder descendants should have effective snippet rows")
        XCTAssertTrue(agenda.label.contains("Work/Meetings"),
                      "Snippet rows should retain their folder path")
        XCTAssertTrue(intro.exists,
                      "Individually registered notes should appear as snippets")
        XCTAssertTrue(app.buttons["notebook-template-options-" + templateID]
            .exists)
        XCTAssertFalse(app.buttons["notebook-snippet-overview-" + templateID]
            .exists,
                       "Template registration alone should not create a snippet")

        agenda.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(
            identifier: "notebook-snippet-source-detail"
        ).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["notebook-remove-snippet-source"].exists,
                       "An inherited note cannot be unregistered by itself")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "stop using those folders"
        )).firstMatch.exists,
                       "Inherited notes should explain how availability works")
    }

    func testSnippetDetailEditsSourceAndRemovalPreservesTemplateAndNote() throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launch()

        let source = "Original Markdown"
        createNote(in: app, named: "Shared source", body: source)
        showFiles(app)
        let sourceID = itemID(named: "Shared source", in: app)
        markSnippet(sourceID, named: "Shared source", in: app)
        markTemplate(sourceID, named: "Shared source", in: app)

        openSnippetSettings(app)
        app.buttons["notebook-snippet-overview-" + sourceID].tap()
        capture(app, "snippet-source-detail-after")
        let edit = app.buttons["notebook-open-snippet-source"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        XCTAssertEqual(edit.label, "Edit Snippet")
        edit.tap()

        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, source,
                       "Edit Snippet should open the original Markdown note")
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        editor.typeText("{{")
        XCTAssertTrue(app.buttons["snippet-variable-date"]
            .waitForExistence(timeout: 5),
                       "The opened source should support variable completion")

        showFiles(app)
        openSnippetSettings(app)
        app.buttons["notebook-snippet-overview-" + sourceID].tap()
        app.buttons["notebook-remove-snippet-source"].tap()
        XCTAssertFalse(app.buttons["notebook-snippet-overview-" + sourceID]
            .waitForExistence(timeout: 2),
                       "Removing explicit registration should remove snippet metadata")
        XCTAssertTrue(app.buttons["notebook-template-options-" + sourceID].exists,
                      "Removing snippet registration should preserve template use")
        closeSnippetSettings(app)
        XCTAssertTrue(fileTitle("Shared source", in: app).exists,
                      "Removing registration must keep the original note")
    }

    func testEmptySnippetFolderOverviewAndRemovalKeepFolder() throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launch()

        createFolder(in: app, named: "Empty ideas")
        showFiles(app)
        let folderID = itemID(named: "Empty ideas", in: app)
        markSnippet(folderID, named: "Empty ideas", in: app, isFolder: true)

        openSnippetSettings(app)
        let folder = app.buttons["notebook-snippet-folder-overview-" + folderID]
        XCTAssertTrue(folder.waitForExistence(timeout: 5),
                      "Registered folders should remain visible when empty")
        folder.tap()
        let showFolder = app.buttons["notebook-open-snippet-source"]
        XCTAssertTrue(showFolder.waitForExistence(timeout: 5))
        XCTAssertEqual(showFolder.label, "Show Folder in Files")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Edit those Markdown notes in Files"
        )).firstMatch.exists)
        showFolder.tap()

        XCTAssertTrue(fileTitle("Empty ideas", in: app).waitForExistence(
            timeout: 5), "Show Folder in Files should reveal the registered folder")
        openSnippetSettings(app)
        app.buttons["notebook-snippet-folder-overview-" + folderID].tap()
        app.buttons["notebook-remove-snippet-source"].tap()
        closeSnippetSettings(app)
        XCTAssertTrue(fileTitle("Empty ideas", in: app).waitForExistence(
            timeout: 5), "Stopping registration must preserve the folder")
        openSnippetSettings(app)
        XCTAssertFalse(app.buttons["notebook-snippet-folder-overview-" + folderID]
            .exists)
    }

    private func makeApp(mode: String = "source") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", mode]
        return app
    }

    private func createNote(in app: XCUIApplication, named name: String,
                            body: String, parent: String? = nil) {
        if let parent {
            fileTitle(parent, in: app).press(forDuration: 1)
            app.collectionViews.buttons["New Note"].firstMatch.tap()
        } else {
            let plus = app.buttons["notebook-new-item"].firstMatch
            XCTAssertTrue(plus.waitForExistence(timeout: 15))
            plus.tap()
        }
        let title = app.textFields["title-field"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        clearAndEnterText(title, name, in: app)
        title.typeText("\n")
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.typeText(body)
        XCTAssertEqual(editor.value as? String, body)
    }

    private func createFolder(in app: XCUIApplication, named name: String,
                              parent: String? = nil) {
        if let parent {
            fileTitle(parent, in: app).press(forDuration: 1)
        } else {
            app.buttons["notebook-app-menu"].tap()
        }
        app.buttons["New Folder"].tap()
        let field = app.textFields["Name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(name + "\n")
        XCTAssertTrue(fileTitle(name, in: app).waitForExistence(timeout: 5))
    }

    private func clearAndEnterText(_ field: XCUIElement, _ text: String,
                                   in app: XCUIApplication) {
        replaceFieldText(field, with: text, in: app)
        if field.value as? String != text {
            replaceFieldText(field, with: text, in: app)
        }
        XCTAssertEqual(field.value as? String, text)
    }

    private func replaceFieldText(_ field: XCUIElement, with text: String,
                                  in app: XCUIApplication) {
        let current = field.value as? String ?? ""
        field.tap()
        field.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) {
            app.menuItems["Select All"].tap()
            field.typeText(text)
        } else {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                                  count: current.count + 8))
            field.typeText(text)
        }
    }

    private func markSnippet(_ id: String, named name: String,
                             in app: XCUIApplication, isFolder: Bool = false) {
        fileTitle(name, in: app).press(forDuration: 1)
        let identified = app.buttons["notebook-use-as-snippet-" + id]
        let label = isFolder ? "Use as Snippet Folder" : "Use as Snippet"
        let action = identified.waitForExistence(timeout: 1)
            ? identified : app.buttons[label].firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.tap()
    }

    private func markTemplate(_ id: String, named name: String,
                              in app: XCUIApplication) {
        fileTitle(name, in: app).press(forDuration: 1)
        let identified = app.buttons["notebook-use-as-template-" + id]
        let action = identified.waitForExistence(timeout: 1) ? identified
            : app.buttons["Use as Template"].firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.tap()
    }

    private func openSnippetSettings(_ app: XCUIApplication) {
        app.buttons["notebook-app-menu"].tap()
        app.buttons["notebook-settings"].tap()
        app.buttons["notebook-templates-settings"].tap()
        XCTAssertTrue(app.navigationBars["Templates & Snippets"]
            .waitForExistence(timeout: 5))
    }

    private func closeSnippetSettings(_ app: XCUIApplication) {
        app.navigationBars["Templates & Snippets"].buttons.firstMatch.tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["notebook-app-menu"].waitForExistence(timeout: 5))
    }

    private func openSnippetMenu(in app: XCUIApplication) {
        revealSnippetMenu(in: app)
        let menu = app.buttons["editor-snippet-menu"]
        menu.tap()
    }

    private func revealSnippetMenu(in app: XCUIApplication) {
        let menu = app.buttons["editor-snippet-menu"]
        let toolbar = app.collectionViews["editor-keyboard-toolbar"]
        XCTAssertTrue(toolbar.waitForExistence(timeout: 5))
        for _ in 0..<5 where !menu.isHittable {
            toolbar.swipeLeft()
        }
        XCTAssertTrue(menu.isHittable,
                      "Swipe the formatting bar until Insert Snippet is visible")
    }

    private func menuItem(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons[name].firstMatch
    }

    private func chooseMenuItem(_ name: String, in app: XCUIApplication) {
        let item = menuItem(name, in: app)
        XCTAssertTrue(item.waitForExistence(timeout: 5),
                      "Expected the snippet menu to contain \(name)")
        item.tap()
    }

    private func dateAndTimePattern(suffix: String) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale.current
        dateFormatter.calendar = Calendar.current
        dateFormatter.timeZone = .current
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .none
        let date = NSRegularExpression.escapedPattern(
            for: dateFormatter.string(from: Date())
        )
        let escapedSuffix = NSRegularExpression.escapedPattern(for: suffix)
        return "(?m)^\(date) [^\\n]+\(escapedSuffix)$"
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
        return title.identifier.replacingOccurrences(
            of: "notebook-sidebar-title-", with: ""
        )
    }

    private func showFiles(_ app: XCUIApplication) {
        if !app.buttons["notebook-app-menu"].isHittable {
            app.navigationBars.buttons.firstMatch.tap()
        }
        XCTAssertTrue(app.buttons["notebook-app-menu"].waitForExistence(
            timeout: 5))
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
