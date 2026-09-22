import XCTest

final class NotebookSearchUITests: XCTestCase {
    func testGlobalSearchFindsAndOpensBodyMatch() throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launch()

        let marker = "quasar-\(UUID().uuidString.prefix(8))"
        let title = "Fictional Observatory"
        let body = String(repeating: "Earlier observation.\n", count: 30)
            + "A quiet \(marker) passes Mars.\n"
            + String(repeating: "Later observation.\n", count: 30)
        createNote(in: app, title: title, body: body)
        showSidebar(in: app)
        capture(app, name: "Fictional notebook library before search")

#if os(iOS)
        if app.frame.width < 600 {
            let menu = app.buttons["notebook-app-menu"]
            XCTAssertTrue(menu.waitForExistence(timeout: 5))
            menu.tap()
            XCTAssertFalse(
                app.buttons["Quick Open…"].exists,
                "Quick Open should stay a keyboard command on compact layouts"
            )
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        }
#endif

        let search = revealGlobalSearch(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        XCTAssertTrue(
            search.placeholderValue == "Search all notes"
                || search.label == "Search all notes"
        )
        search.tap()
        search.typeText(marker)
        XCTAssertFalse(app.staticTexts["Preparing search…"].exists)

        let result = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "search-result-")
        ).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertTrue(result.label.contains(title))
        capture(app, name: "Global search with a fictional body match")
        activate(result)
        XCTAssertTrue(app.textViews["markdown-editor"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["note-title"].label, title)
        let keyboardHidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.keyboards.firstMatch
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [keyboardHidden], timeout: 3), .completed,
            "Opening a search result must dismiss search focus"
        )
        capture(app, name: "Search result opened without editing focus")
    }

    func testFindInNoteOpensNativeFind() throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launch()
        createNote(
            in: app,
            title: "Fictional Field Log",
            body: "North ridge\n\nA lantern crosses the valley."
        )

        #if os(macOS)
        let actions = app.menuButtons["notebook-note-actions"]
        #else
        let actions = app.buttons["notebook-note-actions"]
        #endif
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        activate(actions)
        let find = app.descendants(matching: .any)
            .matching(identifier: "notebook-find").firstMatch
        XCTAssertTrue(find.waitForExistence(timeout: 10))
        activate(find)
        let findField = app.searchFields.firstMatch.exists
            ? app.searchFields.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(
            findField.waitForExistence(timeout: 5),
            "Expected the native Find field"
        )
        findField.typeText("lantern")
        capture(app, name: "Native Find in a fictional note")
#if os(macOS)
        let matchIndicator = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH[c] %@", "1 match")
        ).firstMatch
#else
        let matchIndicator = app.staticTexts["1 of 1"]
#endif
        XCTAssertTrue(
            matchIndicator.waitForExistence(timeout: 5),
            "Expected native Find to report the matching occurrence"
        )
    }

#if os(macOS)
    func testQuickOpenShortcutSearchesAndOpensNote() throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launch()

        let marker = "nebula-\(UUID().uuidString.prefix(8))"
        createNote(in: app, title: "Fictional Nebula", body: marker)
        app.typeKey("o", modifierFlags: [.command, .shift])

        let query = app.textFields["quick-open-query"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        query.typeText(marker)
        let result = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "quick-result-")
        ).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        capture(app, name: "Quick Open results")
        query.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.textViews["markdown-editor"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["note-title"].label, "Fictional Nebula")
        capture(app, name: "Quick Open selected a fictional note")
    }
#endif

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "source"]
        return app
    }

    private func createNote(
        in app: XCUIApplication, title: String, body: String
    ) {
        let newNote = app.buttons["notebook-new-item"].firstMatch
        XCTAssertTrue(newNote.waitForExistence(timeout: 15))
        activate(newNote)
        let titleField = app.textFields["title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 10))
#if os(macOS)
        titleField.typeKey("a", modifierFlags: .command)
        titleField.typeText(title)
        titleField.typeKey(.return, modifierFlags: [])
#else
        titleField.tap()
        let existing = titleField.value as? String ?? ""
        titleField.typeText(
            String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count)
                + title
        )
        titleField.typeText("\n")
#endif
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.typeText(body)
        XCTAssertEqual(editor.value as? String, body)
    }

    private func showSidebar(in app: XCUIApplication) {
#if os(iOS)
        if app.frame.width < 600 && !app.searchFields.firstMatch.isHittable {
            app.navigationBars.buttons.firstMatch.tap()
        }
#endif
        XCTAssertTrue(
            app.buttons["notebook-app-menu"].waitForExistence(timeout: 10)
                || app.searchFields.firstMatch.waitForExistence(timeout: 10)
        )
    }

    private func revealGlobalSearch(in app: XCUIApplication) -> XCUIElement {
        let field = app.searchFields.firstMatch
        if field.exists { return field }
        let searchButton = app.buttons["Search"]
        if searchButton.waitForExistence(timeout: 3) {
            activate(searchButton)
        }
        return field
    }

    private func activate(_ element: XCUIElement) {
#if os(macOS)
        element.click()
#else
        element.tap()
#endif
    }

    private func capture(_ app: XCUIApplication, name: String) {
#if os(macOS)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
#else
        let attachment = XCTAttachment(screenshot: app.screenshot())
#endif
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
