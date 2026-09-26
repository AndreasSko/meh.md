import XCTest

#if os(iOS)
final class MarkdownTableUITests: XCTestCase {
    func testTableMenuCaptureAtCurrentTextSize() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "livePreview"]
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
        editor.tap()
        editor.typeText("A fictional coastal itinerary.")
        openTableMenu(in: app)
        XCTAssertTrue(command("editor-command-insert-table", in: app).exists)
        capture(app, name: "Table menu at current text size")

        command("editor-command-insert-table", in: app).tap()
        XCTAssertTrue(waitForSource(editor) { $0.contains("| Column 1 | Column 2 |") })
        openTableMenu(in: app)
        let groups = ["Row", "Column", "Alignment", "Cell", "Delete"].map {
            menuButton($0, in: app)
        }
        for group in groups {
            XCTAssertTrue(group.exists, "Missing \(group.label) table submenu")
        }
        let visibleGroups = groups.filter(\.isHittable)
        XCTAssertFalse(visibleGroups.isEmpty)
        for (upper, lower) in zip(visibleGroups, visibleGroups.dropFirst()) {
            XCTAssertGreaterThanOrEqual(lower.frame.minY, upper.frame.maxY - 1,
                                        "Table menu rows should not overlap")
        }
        capture(app, name: "Grouped table menu at current text size")
        let deleteGroup = menuButton("Delete", in: app)
        if !deleteGroup.isHittable {
            let menuScroll = app.collectionViews.containing(
                .button, identifier: "Row"
            ).firstMatch
            XCTAssertTrue(menuScroll.exists, "Expected a scrollable native menu")
            for _ in 0..<3 where !deleteGroup.isHittable {
                menuScroll.swipeUp()
            }
            XCTAssertTrue(deleteGroup.isHittable,
                          "Delete submenu should be reachable by scrolling")
            capture(app, name: "Bottom of grouped table menu")
        }
    }

    func testTableCommandsEditLiteralMarkdown() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "livePreview"]
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
        editor.tap()
        editor.typeText("A fictional coastal itinerary.")

        let formatting = app.buttons["editor-formatting"].firstMatch
        XCTAssertTrue(formatting.waitForExistence(timeout: 5))
        formatting.tap()
        capture(app, name: "Formatting menu with Table entry")
        command("editor-table-menu", in: app).tap()
        capture(app, name: "Table commands in Formatting")
        command("editor-command-insert-table", in: app).tap()
        XCTAssertTrue(waitForSource(editor) { $0.contains("| Column 1 | Column 2 |") })
        let inserted = try XCTUnwrap(editor.value as? String)
        XCTAssertTrue(inserted.hasPrefix("A fictional coastal itinerary."))
        XCTAssertTrue(inserted.contains("| --- | --- |"))
        capture(app, name: "New table with selected header")

        // The inserted header is selected so typing names it directly.
        editor.typeText("Activity")
        XCTAssertTrue(waitForSource(editor) { $0.contains("| Activity | Column 2 |") })
        openTableMenu(in: app)
        tapTableAction("editor-command-table-next-cell", group: "Cell", in: app)
        editor.typeText("When")
        XCTAssertTrue(waitForSource(editor) { $0.contains("| Activity | When |") })
        capture(app, name: "Next Cell selects the header contents")

        openTableMenu(in: app)
        capture(app, name: "Commands while editing a table cell")
        for group in ["Row", "Column", "Alignment", "Cell", "Delete"] {
            XCTAssertTrue(menuButton(group, in: app).exists,
                          "Missing \(group) table submenu")
        }
        tapTableAction("editor-command-table-row-below", group: "Row", in: app)
        XCTAssertTrue(waitForSource(editor) {
            $0.components(separatedBy: "|  |  |").count == 3
        })
        capture(app, name: "Added table row")

        openTableMenu(in: app)
        tapTableAction("editor-command-table-column-after", group: "Column", in: app)
        XCTAssertTrue(waitForSource(editor) {
            $0.contains("| Activity |  | When |")
        })
        capture(app, name: "Added table column")

        openTableMenu(in: app)
        tapTableAction("editor-command-table-align-right", group: "Alignment", in: app)
        XCTAssertTrue(waitForSource(editor) { $0.contains("---:") })
        openTableMenu(in: app)
        let alignment = menuButton("Alignment", in: app)
        XCTAssertTrue(alignment.waitForExistence(timeout: 5))
        alignment.tap()
        let right = command("editor-command-table-align-right", in: app)
        XCTAssertTrue(right.waitForExistence(timeout: 5))
        XCTAssertTrue(right.isSelected, "Active alignment should have a checkmark")
        capture(app, name: "Right alignment has a checkmark")
        app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: 10, dy: 200)
        ).tap()
        let beforeDelete = try XCTUnwrap(editor.value as? String)

        openTableMenu(in: app)
        tapTableAction("editor-command-table-delete-column", group: "Delete", in: app)
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        capture(app, name: "Confirm deletion of table column")
        cancel.tap()
        XCTAssertEqual(editor.value as? String, beforeDelete)

        openTableMenu(in: app)
        tapTableAction("editor-command-table-delete-column", group: "Delete", in: app)
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertTrue(waitForSource(editor) { $0 != beforeDelete })
        let finalSource = try XCTUnwrap(editor.value as? String)
        XCTAssertTrue(finalSource.hasPrefix("A fictional coastal itinerary."))
        XCTAssertTrue(finalSource.contains("| Activity | When |"))
        capture(app, name: "Edited table remains Markdown")
    }

    func testTablePreviewAndSourceEditingKeepMarkdown() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "livePreview"]
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
        editor.tap()
        let source = """
        | Activity | Time | Status |
        | :--- | :---: | ---: |
        | **Coastal walk** | 09:30 | Ready |
        | Museum and a relaxed lunch by the harbour | 12:00 | Planned |
        | Cafe | 15:00 | Open |

        A quiet afternoon by the sea.
        """
        editor.typeText(source)
        XCTAssertEqual(editor.value as? String, source)
        editor.swipeDown()
        capture(app, name: "Rendered table in the app")

        let header = command("markdown-table-cell-0-0", in: app)
        let bodyCell = command("markdown-table-cell-1-0", in: app)
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        XCTAssertTrue(bodyCell.waitForExistence(timeout: 5))
        XCTAssertTrue(header.label.contains("Activity"))
        XCTAssertTrue(bodyCell.label.contains("Activity"))
        XCTAssertTrue(bodyCell.label.contains("Coastal walk"))
        XCTAssertTrue(editor.exists, "The native Markdown source editor remains available")

        // A native hit inside the first few table rows must enter ordinary
        // source editing. The complete source remains the accessibility value.
        let noteTitle = app.buttons["note-title"]
        XCTAssertTrue(noteTitle.waitForExistence(timeout: 5))
        editor.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: editor.frame.width * 0.5,
                     dy: noteTitle.frame.maxY - editor.frame.minY + 70)
        ).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, source)
        capture(app, name: "Table revealed for editing")
        editor.typeText("!")
        let edited = try XCTUnwrap(editor.value as? String)
        XCTAssertEqual(edited.replacingOccurrences(of: "!", with: ""), source)
        XCTAssertEqual(edited.utf16.count, source.utf16.count + 1)
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openTableMenu(in app: XCUIApplication) {
        let formatting = app.buttons["editor-formatting"].firstMatch
        XCTAssertTrue(formatting.waitForExistence(timeout: 5))
        formatting.tap()
        let table = command("editor-table-menu", in: app)
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        table.tap()
    }

    private func tapTableAction(
        _ identifier: String,
        group: String,
        in app: XCUIApplication
    ) {
        let submenu = menuButton(group, in: app)
        XCTAssertTrue(submenu.waitForExistence(timeout: 5))
        submenu.tap()
        let action = command(identifier, in: app)
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.tap()
    }

    private func command(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let identified = app.descendants(matching: .any)[identifier].firstMatch
        if identified.exists { return identified }
        let titles = [
            "editor-table-menu": "Table",
            "editor-command-insert-table": "Insert Table",
            "editor-command-table-next-cell": "Next Cell",
            "editor-command-table-row-below": "Add Row Below",
            "editor-command-table-column-after": "Add Column After",
            "editor-command-table-align-right": "Align Right",
            "editor-command-table-delete-column": "Delete Column",
        ]
        return menuButton(titles[identifier] ?? identifier, in: app)
    }

    private func menuButton(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons[title].firstMatch
        return button.exists ? button : app.menuItems[title].firstMatch
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
