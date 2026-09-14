import XCTest

final class NotebookOrderingUITests: XCTestCase {
    func testOneTimeSortPersistsAndPreservesEditorUndo() throws {
        continueAfterFailure = false
        let suffix = String(UUID().uuidString.prefix(8))
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = suffix
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "source"]
        app.launch()

        let charlie = try createNote(named: "Charlie \(suffix)", in: app)
        let alpha = try createNote(named: "Alpha \(suffix)", in: app)
        let bravo = try createNote(named: "Bravo \(suffix)", in: app)
        activate(bravo)
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        activate(editor)
        editor.typeText("Fictional orbit")

        showSidebar(app)
        chooseSort("Name, A–Z", in: app)
        try assertOrder([alpha, bravo, charlie], in: app)
        capture(app, name: "Notebook sorted by name ascending")

        #if os(macOS)
        charlie.rightClick()
        activate(app.menuItems["Move Up"])
        #else
        charlie.press(forDuration: 1.0)
        activate(app.buttons["Move Up"])
        #endif
        try assertOrder([alpha, charlie, bravo], in: app)
        capture(app, name: "Notebook manually reordered with Move Up")

        chooseSort("Name, Z–A", in: app)
        try assertOrder([charlie, bravo, alpha], in: app)
        capture(app, name: "Notebook sorted by name descending")

        #if os(macOS)
        editor.click()
        editor.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(editor.value as? String, "")
        #endif

        app.terminate()
        app.launch()
        showSidebar(app)
        try assertOrder([charlie, bravo, alpha], in: app)
    }

    private func createNote(
        named title: String,
        in app: XCUIApplication
    ) throws -> XCUIElement {
        let newNote = app.buttons["notebook-new-item"].firstMatch
        XCTAssertTrue(newNote.waitForExistence(timeout: 15))
        activate(newNote)
        let field = app.textFields["title-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        #if os(macOS)
        field.typeKey("a", modifierFlags: .command)
        field.typeText(title)
        field.typeKey(.return, modifierFlags: [])
        #else
        replaceTitle(in: field, app: app, with: title)
        field.typeText("\n")
        #endif
        XCTAssertTrue(app.textViews["markdown-editor"].waitForExistence(timeout: 5))
        showSidebar(app)
        let label = app.staticTexts.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label == %@",
                "notebook-sidebar-title-", title + ".md"
            )
        ).firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        return label
    }

    private func chooseSort(_ title: String, in app: XCUIApplication) {
        let menu = app.buttons["notebook-sort-root"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        activate(menu)
        #if os(macOS)
        let action = app.menuItems[title]
        #else
        let action = app.buttons[title]
        #endif
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        activate(action)
    }

    private func assertOrder(
        _ elements: [XCUIElement],
        in app: XCUIApplication
    ) throws {
        let ordered = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let positions = elements.map { $0.frame.minY }
                return zip(positions, positions.dropFirst()).allSatisfy {
                    $0.0 < $0.1
                }
            },
            object: app
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ordered], timeout: 10), .completed)
    }

    private func replaceTitle(
        in field: XCUIElement,
        app: XCUIApplication,
        with title: String
    ) {
        let existing = field.value as? String ?? ""
        field.tap()
        field.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) {
            app.menuItems["Select All"].tap()
            field.typeText(title)
        } else {
            field.typeText(
                String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count)
                    + title
            )
        }
    }

    private func showSidebar(_ app: XCUIApplication) {
        #if os(iOS)
        if !app.buttons["notebook-sort-root"].isHittable {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        #endif
        XCTAssertTrue(app.buttons["notebook-sort-root"].waitForExistence(timeout: 5))
        let tree = app.buttons["notebook-tree-toggle"]
        XCTAssertTrue(tree.waitForExistence(timeout: 5))
        if tree.value as? String == "Collapsed" {
            activate(tree)
        }
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
        let attachment = XCTAttachment(
            screenshot: app.windows.firstMatch.screenshot()
        )
        #else
        let attachment = XCTAttachment(screenshot: app.screenshot())
        #endif
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
