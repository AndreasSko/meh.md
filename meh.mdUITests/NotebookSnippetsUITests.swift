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
        let folderID = itemID(named: "Work", in: app)
        markSnippet(folderID, named: "Work", in: app, isFolder: true)

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
            of: dateAndTimePattern(suffix: " \\{\\{unknown\\}\\}"),
            options: .regularExpression
        ) != nil)

        openSnippetMenu(in: app)
        let work = menuItem("Work", in: app)
        XCTAssertTrue(work.waitForExistence(timeout: 5))
        work.tap()
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
            of: dateAndTimePattern(suffix: " \\{\\{unknown\\}\\}"),
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
                app.buttons["notebook-disclosure-\(folderID)"].tap()
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
        clearAndEnterText(title, name)
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

    private func clearAndEnterText(_ field: XCUIElement, _ text: String) {
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                              count: current.count + 4))
        field.typeText(text)
        if field.value as? String != text {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
                .tap()
            let retryValue = field.value as? String ?? ""
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                                  count: retryValue.count + 4))
            field.typeText(text)
        }
        XCTAssertEqual(field.value as? String, text)
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
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.timeZone = .current
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())
        return "(?m)^\(today) \\d{2}:\\d{2}\(suffix)$"
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
