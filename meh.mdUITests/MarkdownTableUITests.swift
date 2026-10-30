import XCTest

#if os(iOS)
@MainActor
final class MarkdownTableUITests: XCTestCase {
    func testTableCommandsEditLiteralMarkdown() throws {
        continueAfterFailure = false
        let app = isolatedApplication()
        app.launch()

        let newNote = app.buttons["notebook-new-item"].firstMatch
        XCTAssertTrue(newNote.waitForExistence(timeout: 15))
        newNote.tap()
        let title = app.textFields["title-field"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        title.typeText("\n")
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        app.buttons["notebook-note-actions"].tap()
        app.buttons["Editor Display"].tap()
        app.buttons["Live Preview"].tap()
        editor.tap()
        editor.typeText("A fictional coastal itinerary.")

        let insertTable = toolbarCommand("editor-command-insert-table", in: app)
        XCTAssertEqual(insertTable.label, "Insert Table")
        insertTable.tap()
        XCTAssertTrue(waitForSource(editor) { $0.contains("| Column 1 | Column 2 |") })
        let inserted = try XCTUnwrap(editor.value as? String)
        XCTAssertTrue(inserted.hasPrefix("A fictional coastal itinerary."))
        XCTAssertTrue(inserted.contains("| --- | --- |"))
        capture(app, name: "New table with selected header")

        // The inserted header is selected in the native cell editor.
        let cellEditor = app.textViews["markdown.table.cell.editor"]
        XCTAssertTrue(cellEditor.waitForExistence(timeout: 5))
        XCTAssertEqual(cellEditor.value as? String, "Column 1")
        XCTAssertTrue(cellEditor.isHittable)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertEqual(app.buttons["editor-table-menu"].label, "Table")
        cellEditor.typeText("Activity")
        XCTAssertTrue(waitForSource(editor) { $0.contains("| Activity | Column 2 |") })
        toolbarCommand("editor-command-table-next-cell", in: app).tap()
        XCTAssertTrue(waitForSource(cellEditor) { $0 == "Column 2" })
        cellEditor.typeText("When")
        XCTAssertTrue(waitForSource(editor) { $0.contains("| Activity | When |") })
        capture(app, name: "Next Cell selects the header contents")

        toolbarCommand("editor-command-table-row-below", in: app).tap()
        XCTAssertTrue(waitForSource(editor) {
            $0.components(separatedBy: "|  |  |").count == 3
        })
        capture(app, name: "Added table row")

        toolbarCommand("editor-command-table-column-after", in: app).tap()
        XCTAssertTrue(waitForSource(editor) {
            $0.contains("| Activity |  | When |")
        })
        capture(app, name: "Added table column")

        toolbarCommand("editor-command-table-align-right", in: app).tap()
        XCTAssertTrue(waitForSource(editor) { $0.contains("---:") })
        let right = toolbarCommand("editor-command-table-align-right", in: app)
        XCTAssertTrue(right.waitForExistence(timeout: 5))
        XCTAssertTrue(right.isSelected, "Active alignment should have a checkmark")
        capture(app, name: "Right alignment has a checkmark")
        let beforeDelete = try XCTUnwrap(editor.value as? String)

        toolbarCommand("editor-command-table-delete-column", in: app).tap()
        let delete = app.buttons["Delete Column"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertTrue(waitForSource(editor) { $0 != beforeDelete })
        let finalSource = try XCTUnwrap(editor.value as? String)
        XCTAssertTrue(finalSource.hasPrefix("A fictional coastal itinerary."))
        XCTAssertTrue(finalSource.contains("| Activity | When |"))
        capture(app, name: "Edited table remains Markdown")
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func isolatedApplication() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = "table-ui-\(UUID().uuidString)"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        return app
    }

    @discardableResult
    private func toolbarCommand(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let titles: [String: String] = [
            "editor-command-insert-table": "Insert Table",
            "editor-command-table-row-above": "Add Row Above",
            "editor-command-table-row-below": "Add Row Below",
            "editor-command-table-column-before": "Add Column Left",
            "editor-command-table-column-after": "Add Column Right",
            "editor-command-table-next-cell": "Next Cell",
            "editor-command-table-previous-cell": "Previous Cell",
            "editor-command-table-delete-row": "Delete Row…",
            "editor-command-table-delete-column": "Delete Column…",
            "editor-command-table-align-left": "Align Left",
            "editor-command-table-align-center": "Align Center",
            "editor-command-table-align-right": "Align Right",
        ]
        let title = titles[identifier] ?? identifier
        let action = app.buttons[title].firstMatch
        if action.exists { return action }
        let menu = app.buttons["editor-table-menu"].firstMatch
        let nativeMenu = app.collectionViews.allElementsBoundByIndex.first {
            $0.identifier != "editor-keyboard-toolbar" && $0.frame.width > 100
                && $0.buttons.count > 0
        }
        if nativeMenu != nil {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        }
        let toolbar = app.collectionViews["editor-keyboard-toolbar"]
        XCTAssertTrue(toolbar.waitForExistence(timeout: 5))
        for _ in 0..<4 where !menu.isHittable { toolbar.swipeRight() }
        for _ in 0..<8 where !menu.isHittable { toolbar.swipeLeft() }
        XCTAssertTrue(menu.isHittable)
        if identifier == "editor-command-insert-table" { return menu }
        menu.tap()
        let group: String?
        if identifier.contains("table-align-") { group = "Column Alignment" }
        else if identifier.contains("table-row-") || identifier == "editor-command-table-delete-row" { group = "Row" }
        else if identifier.contains("table-column-") || identifier == "editor-command-table-delete-column" { group = "Column" }
        else { group = nil }
        if let group {
            let submenu = app.buttons[group].firstMatch
            XCTAssertTrue(submenu.waitForExistence(timeout: 5))
            submenu.tap()
        }
        XCTAssertTrue(action.waitForExistence(timeout: 5), "Missing Table action \(title)")
        return action
    }

    private func waitForSource(
        _ editor: XCUIElement,
        where predicate: (String) -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if let source = editor.value as? String, predicate(source) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return false
    }
}
#endif
