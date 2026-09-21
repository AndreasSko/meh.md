import XCTest

final class NotebookOrderingUITests: XCTestCase {
    func testOneTimeSortPersistsWithoutManualMoveActions() throws {
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
        XCTAssertEqual(app.buttons["note-title"].label, bravo.label)
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        #if os(macOS)
        activate(editor)
        editor.typeText("Fictional orbit")
        #endif

        showSidebar(app)
        chooseSort("Name, A–Z", in: app)
        try assertOrder([alpha, bravo, charlie], in: app)
        capture(app, name: "Notebook sorted by name ascending")
        assertManualMoveActionsAbsent(on: charlie, in: app)

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

    func testBatchTrashRestoresFromTrashAndPreservesNoteSource() throws {
        continueAfterFailure = false
        let suffix = String(UUID().uuidString.prefix(8))
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = suffix
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "source"]
        app.launch()
        let alpha = try createNote(named: "Alpha \(suffix)", in: app)
        let bravo = try createNote(named: "Bravo \(suffix)", in: app)
        activate(bravo)
        XCTAssertEqual(app.buttons["note-title"].label, bravo.label)
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        activate(editor)
        editor.typeText("Fictional batch source")
        showSidebar(app)

        enterSelectionMode(in: app)
        activate(alpha)
        activate(bravo)
        XCTAssertTrue(app.staticTexts["2 selected"].waitForExistence(timeout: 5))
        openSelectionActions(in: app)
        #if os(macOS)
        activate(app.menuItems["Trash Selected"])
        #else
        activate(app.buttons["Trash Selected"])
        #endif
        let trash = app.buttons["notebook-trash-toggle"]
        XCTAssertTrue(trash.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["notebook-browser-undo"].exists)
        XCTAssertFalse(app.buttons["notebook-browser-redo"].exists)
        XCTAssertFalse(alpha.exists)
        XCTAssertFalse(bravo.exists)
        app.openTrash()
        XCTAssertTrue(alpha.waitForExistence(timeout: 5))
        XCTAssertTrue(bravo.waitForExistence(timeout: 5))
        try assertOrder([alpha, bravo], in: app)
        capture(app, name: "Batch selection moved to Trash")

        restore(alpha, in: app)
        restore(bravo, in: app)
        XCTAssertTrue(app.staticTexts["Trash is empty"].waitForExistence(timeout: 5))
        app.closeTrash()
        XCTAssertTrue(alpha.waitForExistence(timeout: 5))
        XCTAssertTrue(bravo.waitForExistence(timeout: 5))
        try assertOrder([alpha, bravo], in: app)
        capture(app, name: "Batch restored from Trash")

        activate(bravo)
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "Fictional batch source")
    }

    func testBatchMoveIntoFolderAndUndo() throws {
        continueAfterFailure = false
        let suffix = String(UUID().uuidString.prefix(8))
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = suffix
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launch()
        let alpha = try createNote(named: "Alpha \(suffix)", in: app)
        let bravo = try createNote(named: "Bravo \(suffix)", in: app)
        #if os(macOS)
        app.buttons["notebook-tree-toggle"].rightClick()
        activate(app.menuItems["New Folder"])
        #else
        app.buttons["notebook-tree-toggle"].press(forDuration: 1.2)
        activate(app.buttons["New Folder"])
        #endif
        let field = app.textFields["Name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        #if os(macOS)
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Folder \(suffix)")
        field.typeKey(.return, modifierFlags: [])
        #else
        replaceTitle(in: field, app: app, with: "Folder \(suffix)")
        field.typeText("\n")
        #endif
        let folder = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label == %@",
                "notebook-sidebar-folder-", "Folder \(suffix)"
            )
        ).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        enterSelectionMode(in: app)
        activate(alpha)
        activate(bravo)
        openSelectionActions(in: app)
        #if os(macOS)
        activate(app.menuItems["Move Selected…"])
        #else
        activate(app.buttons["Move Selected…"])
        #endif
        #if os(macOS)
        let destination = app.popUpButtons["notebook-move-destination"]
        #else
        let destination = app.buttons["notebook-move-destination"]
        #endif
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
        activate(destination)
        #if os(macOS)
        activate(app.menuItems["Folder \(suffix)"])
        #else
        activate(app.collectionViews.buttons["Folder \(suffix)"])
        #endif
        activate(app.buttons["notebook-confirm-move"])
        XCTAssertTrue(app.buttons["notebook-browser-undo"].waitForExistence(timeout: 5))
        try assertOrder([folder, alpha, bravo], in: app)
        capture(app, name: "Batch moved into folder")
        activate(folder)
        XCTAssertFalse(alpha.exists)
        XCTAssertFalse(bravo.exists)
        activate(app.buttons["notebook-browser-undo"])
        XCTAssertTrue(alpha.waitForExistence(timeout: 5))
        try assertOrder([alpha, bravo, folder], in: app)
    }

    #if os(iOS)
    func testSwipeToTrashCanBeRestored() throws {
        continueAfterFailure = false
        let suffix = String(UUID().uuidString.prefix(8))
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = suffix
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launch()
        let note = try createNote(named: "Swipe \(suffix)", in: app)
        note.swipeLeft(velocity: .slow)
        capture(app, name: "Native swipe action revealed")
        let trashAction = app.buttons["notebook-swipe-trash"]
        if trashAction.waitForExistence(timeout: 2), trashAction.isHittable {
            trashAction.tap()
        }
        let trash = app.buttons["notebook-trash-toggle"]
        XCTAssertTrue(trash.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["notebook-browser-undo"].exists)
        XCTAssertFalse(app.buttons["notebook-browser-redo"].exists)
        XCTAssertFalse(note.exists)
        app.openTrash()
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        capture(app, name: "Native swipe to Trash")
        restore(note, in: app)
        XCTAssertTrue(app.staticTexts["Trash is empty"].waitForExistence(timeout: 5))
        app.closeTrash()
        XCTAssertTrue(note.waitForExistence(timeout: 5))
    }
    #endif

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
        let label = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label == %@",
                "notebook-sidebar-note-", title
            )
        ).firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        return label
    }

    private func chooseSort(_ title: String, in app: XCUIApplication) {
        let filesMenu = filesMenu(in: app)
        XCTAssertTrue(filesMenu.waitForExistence(timeout: 5))
        activate(filesMenu)
        let menu = app.descendants(matching: .any)["notebook-sort-root"]
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

    private func openSelectionActions(in app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["2 selected"].waitForExistence(timeout: 5))
        #if os(macOS)
        let actions = app.menuButtons["notebook-selection-actions"]
        #else
        let actions = app.buttons["notebook-selection-actions"]
        #endif
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        activate(actions)
    }

    private func enterSelectionMode(in app: XCUIApplication) {
        let filesMenu = filesMenu(in: app)
        XCTAssertTrue(filesMenu.waitForExistence(timeout: 5))
        activate(filesMenu)
        let select = app.descendants(matching: .any)["notebook-select-items"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        activate(select)
    }

    private func assertManualMoveActionsAbsent(
        on note: XCUIElement,
        in app: XCUIApplication
    ) {
        #if os(macOS)
        visibleRowCenter(note).rightClick()
        XCTAssertTrue(app.menuItems["Move…"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.menuItems["Move Up"].exists)
        XCTAssertFalse(app.menuItems["Move Down"].exists)
        app.typeKey(.escape, modifierFlags: [])
        #else
        note.press(forDuration: 1.0)
        XCTAssertFalse(app.buttons["Move Up"].exists)
        XCTAssertFalse(app.buttons["Move Down"].exists)
        activate(app.buttons["Move…"])
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        activate(cancel)
        #endif
    }

    private func restore(_ item: XCUIElement, in app: XCUIApplication) {
        #if os(macOS)
        visibleRowCenter(item).rightClick()
        let restore = app.menuItems["Restore"]
        #else
        item.press(forDuration: 1.0)
        let restore = app.buttons["Restore"]
        #endif
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        activate(restore)
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
        if !app.buttons["notebook-files-menu"].isHittable {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        #endif
        XCTAssertTrue(filesMenu(in: app).waitForExistence(timeout: 5))
        let recents = app.buttons["notebook-recents-toggle"]
        if recents.value as? String == "Expanded" {
            activate(recents)
        }
        let tree = app.buttons["notebook-tree-toggle"]
        XCTAssertTrue(tree.waitForExistence(timeout: 5))
        if tree.value as? String == "Collapsed" {
            activate(tree)
        }
    }

    private func filesMenu(in app: XCUIApplication) -> XCUIElement {
        #if os(macOS)
        app.menuButtons["notebook-files-menu"]
        #else
        app.buttons["notebook-files-menu"]
        #endif
    }

    private func activate(_ element: XCUIElement) {
        #if os(macOS)
        if element.identifier.hasPrefix("notebook-sidebar-note-")
            || element.identifier.hasPrefix("notebook-sidebar-folder-") {
            visibleRowCenter(element).click()
        } else {
            element.click()
        }
        #else
        element.tap()
        #endif
    }

    #if os(macOS)
    private func visibleRowCenter(_ row: XCUIElement) -> XCUICoordinate {
        // SwiftUI sidebar rows can report isHittable=false even though a real
        // click at their current accessibility bounds selects the right note.
        // Bypass XCTest's erroneous auto-scroll only for these visible rows.
        XCTAssertTrue(row.exists)
        let frame = row.frame
        XCTAssertFalse(frame.isEmpty)
        let app = XCUIApplication()
        XCTAssertTrue(app.windows.allElementsBoundByIndex.contains {
            $0.frame.contains(frame)
        }, "Sidebar row must be fully inside an app window")
        XCTAssertTrue(app.scrollViews.allElementsBoundByIndex.contains {
            $0.frame.contains(frame)
        }, "Sidebar row must be fully inside a visible scroll viewport")
        return row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    }
    #endif

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
