import XCTest

#if os(iOS)
final class NotebookTrashUITests: XCTestCase {
    func testSelectAllExcludesCollapsedFolderContents() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launch()

        let noteID = createNote(in: app)
        app.buttons["notebook-app-menu"].tap()
        app.buttons["New Folder"].tap()
        let field = app.textFields["Name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let folderName = try XCTUnwrap(field.value as? String)
        field.typeText("\n")
        let folderTitle = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@",
            "notebook-sidebar-title-", folderName
        )).firstMatch
        XCTAssertTrue(folderTitle.waitForExistence(timeout: 5))
        let folderID = folderTitle.identifier.replacingOccurrences(
            of: "notebook-sidebar-title-", with: ""
        )

        app.buttons["notebook-app-menu"].tap()
        app.buttons["notebook-select-items"].tap()
        title(noteID, in: app).tap()
        app.buttons["notebook-move-selected"].tap()
        app.descendants(matching: .any)["notebook-move-folder-" + folderID].tap()
        app.buttons["notebook-confirm-move"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["notebook-move-sheet"]
            .waitForNonExistence(timeout: 10))
        if app.buttons["notebook-selection-done"].exists {
            app.buttons["notebook-selection-done"].tap()
        }
        app.buttons["notebook-app-menu"].tap()
        app.buttons["notebook-select-items"].tap()
        folderTitle.tap()
        app.buttons["notebook-trash-selected"].tap()
        app.buttons["notebook-app-menu"].tap()
        app.buttons["notebook-trash-toggle"].tap()

        let folderRow = app.collectionViews["notebook-trash-view"]
            .descendants(matching: .any)
            .matching(identifier: "notebook-sidebar-folder-" + folderID).firstMatch
        XCTAssertTrue(folderRow.waitForExistence(timeout: 5))
        XCTAssertFalse(trashRow(noteID, in: app).exists)
        app.buttons["notebook-trash-select"].tap()
        app.buttons["notebook-trash-select-all"].tap()
        XCTAssertEqual(app.staticTexts["notebook-trash-selection-count"].label,
                       "1 Selected")
        folderRow.tap()
        XCTAssertEqual(app.staticTexts["notebook-trash-selection-count"].label,
                       "0 Selected")
        XCTAssertFalse(app.buttons["notebook-trash-restore-selected"].isEnabled)

        app.buttons["Expand folder"].tap()
        XCTAssertTrue(trashRow(noteID, in: app).waitForExistence(timeout: 5))
        app.buttons["notebook-trash-select-all"].tap()
        XCTAssertEqual(app.staticTexts["notebook-trash-selection-count"].label,
                       "2 Selected")
        app.buttons["Collapse folder"].tap()
        XCTAssertFalse(trashRow(noteID, in: app).exists)
        XCTAssertEqual(app.staticTexts["notebook-trash-selection-count"].label,
                       "1 Selected")
    }

    func testTrashMenuHitAreaAndBatchActions() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launch()

        let ids = (0..<5).map { _ in createNote(in: app) }
        app.buttons["notebook-app-menu"].tap()
        app.buttons["notebook-select-items"].tap()
        for id in ids { title(id, in: app).tap() }
        app.buttons["notebook-trash-selected"].tap()
        app.buttons["notebook-app-menu"].tap()
        let openTrash = app.buttons["notebook-trash-toggle"]
        XCTAssertTrue(openTrash.waitForExistence(timeout: 5))
        openTrash.tap()

        let menu = app.buttons["notebook-trash-actions-" + ids[0]]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(menu.frame.width, 44)
        XCTAssertGreaterThanOrEqual(menu.frame.height, 44)
        capture(app, "Trash actions with larger touch target")
        menu.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()
        let restore = app.buttons["notebook-trash-restore-" + ids[0]]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textViews["markdown-editor"].exists)
        // Dismiss by tapping the navigation title, outside the action menu.
        app.navigationBars["Trash"].staticTexts["Trash"].tap()

        app.buttons["notebook-trash-select"].tap()
        trashRow(ids[0], in: app).tap()
        trashRow(ids[1], in: app).tap()
        XCTAssertTrue(app.staticTexts["notebook-trash-selection-count"]
            .waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["notebook-trash-selection-count"].label,
                       "2 Selected")
        XCTAssertFalse(app.textViews["markdown-editor"].exists)
        capture(app, "Trash multiple selection")
        app.buttons["notebook-trash-restore-selected"].tap()
        XCTAssertTrue(trashRow(ids[0], in: app).waitForNonExistence(timeout: 5))
        XCTAssertFalse(trashRow(ids[1], in: app).exists)
        XCTAssertTrue(trashRow(ids[2], in: app).exists)
        if app.buttons["notebook-trash-select"].exists {
            app.buttons["notebook-trash-select"].tap()
        }
        trashRow(ids[2], in: app).tap()
        trashRow(ids[3], in: app).tap()
        XCTAssertTrue(app.staticTexts["notebook-trash-selection-count"]
            .waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["notebook-trash-selection-count"].label,
                       "2 Selected")
        app.buttons["notebook-trash-delete-selected"].tap()
        XCTAssertTrue(app.buttons["Delete Permanently"].waitForExistence(timeout: 5))
        capture(app, "Trash permanent deletion confirmation")
        // Native popover confirmations cancel when tapping outside them.
        app.navigationBars["Trash"].staticTexts["Trash"].tap()
        XCTAssertTrue(app.buttons["Delete Permanently"]
            .waitForNonExistence(timeout: 5))
        XCTAssertTrue(trashRow(ids[2], in: app).exists)
        XCTAssertTrue(trashRow(ids[3], in: app).exists)
        app.buttons["notebook-trash-delete-selected"].tap()
        app.buttons["Delete Permanently"].tap()
        XCTAssertTrue(trashRow(ids[2], in: app).waitForNonExistence(timeout: 5))
        XCTAssertFalse(trashRow(ids[3], in: app).exists)
        XCTAssertTrue(trashRow(ids[4], in: app).exists)
        let doneSelecting = app.buttons["notebook-trash-done-selection"]
        XCTAssertTrue(doneSelecting.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["notebook-trash-close"].exists)
        doneSelecting.tap()
        XCTAssertTrue(app.buttons["notebook-trash-select"].waitForExistence(timeout: 5))
        XCTAssertTrue(trashRow(ids[4], in: app).exists)
        XCTAssertFalse(app.buttons["notebook-trash-restore-selected"].exists)
        app.closeTrash()
        XCTAssertTrue(title(ids[0], in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(title(ids[1], in: app).exists)
        XCTAssertFalse(title(ids[4], in: app).exists)
    }

    private func createNote(in app: XCUIApplication) -> String {
        let newNote = app.buttons["notebook-new-item"].firstMatch
        XCTAssertTrue(newNote.waitForExistence(timeout: 15))
        newNote.tap()
        let field = app.textFields["title-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        let name = field.value as? String ?? "Untitled"
        field.typeText("\n")
        XCTAssertTrue(app.textViews["markdown-editor"].waitForExistence(timeout: 5))
        let tree = app.buttons["notebook-tree-toggle"]
        if !tree.isHittable {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(tree.waitForExistence(timeout: 5))
        let recents = app.buttons["notebook-recents-toggle"]
        if recents.value as? String == "Expanded" { recents.tap() }
        if tree.value as? String == "Collapsed" { tree.tap() }
        let rowTitle = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@",
            "notebook-sidebar-title-", name
        )).firstMatch
        XCTAssertTrue(rowTitle.waitForExistence(timeout: 5))
        return rowTitle.identifier.replacingOccurrences(
            of: "notebook-sidebar-title-", with: ""
        )
    }

    private func title(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts["notebook-sidebar-title-" + id]
    }

    private func trashRow(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.collectionViews["notebook-trash-view"]
            .descendants(matching: .any)
            .matching(identifier: "notebook-sidebar-note-" + id).firstMatch
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
