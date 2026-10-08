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
        activate(title(of: bravo, in: app))
        XCTAssertEqual(app.buttons["note-title"].label, "Bravo \(suffix)")
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        activate(editor)
        editor.typeText("Fictional orbit")

        showSidebar(app)
        chooseSort("Name, A–Z", in: app)
        try assertOrder([alpha, bravo, charlie], in: app)
        capture(app, name: "Notebook sorted by name ascending")
        assertManualMoveActionsAbsent(on: charlie, in: app)

        chooseSort("Name, Z–A", in: app)
        try assertOrder([charlie, bravo, alpha], in: app)
        capture(app, name: "Notebook sorted by name descending")

        app.terminate()
        app.launch()
        showSidebar(app)
        try assertOrder([charlie, bravo, alpha], in: app)
        activate(title(of: bravo, in: app))
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "Fictional orbit")
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
        activate(title(of: bravo, in: app))
        XCTAssertEqual(app.buttons["note-title"].label, "Bravo \(suffix)")
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        activate(editor)
        editor.typeText("Fictional batch source")
        showSidebar(app)

        enterSelectionMode(in: app)
        select(alpha, in: app)
        select(bravo, addingToSelection: true, in: app)
        assertSelectionCount(2, in: app)
        let trashSelected = selectionAction(
            "notebook-trash-selected", title: "Trash", in: app
        )
        XCTAssertTrue(trashSelected.waitForExistence(timeout: 5))
        activate(trashSelected)
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

        activate(title(of: bravo, in: app))
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
        app.launchEnvironment["MEH_NOTEBOOK_MOVE_TEST_DELAY"] = "1"
        app.launch()
        let alpha = try createNote(named: "Alpha \(suffix)", in: app)
        let bravo = try createNote(named: "Bravo \(suffix)", in: app)
        activate(appMenu(in: app))
        #if os(macOS)
        activate(app.menuItems["New Folder"])
        #else
        activate(app.buttons["New Folder"])
        #endif
        let field = app.textFields["Name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        #if os(macOS)
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Folder \(suffix)")
        field.typeKey(.return, modifierFlags: [])
        #else
        replaceTitle(in: field, app: app, with: "Folder \(suffix)")
        field.typeText("\n")
        #endif
        let folder = row(named: "Folder \(suffix)", kind: .folder, in: app)
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.descendants(matching: .any)["notebook-files-menu"].exists
        )
        XCTAssertTrue(appMenu(in: app).waitForExistence(timeout: 5))
        capture(app, name: "Native browser normal toolbar")
        enterSelectionMode(in: app)
        select(alpha, in: app)
        select(bravo, addingToSelection: true, in: app)
        assertSelectionCount(2, in: app)
        XCTAssertFalse(
            app.descendants(matching: .any)["notebook-app-menu"].exists
        )
        var selectAll = selectionAction(
            "notebook-select-all", title: "Select All", in: app
        )
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
        assertSelectionActionTitle(selectAll, "Select All", in: app)
        XCTAssertFalse(newNoteControl(in: app).exists)
        capture(app, name: "Native browser selection toolbar")

        activate(selectAll)
        assertSelectionCount(3, in: app)
        selectAll = selectionAction(
            "notebook-select-all", title: "Deselect All", in: app
        )
        assertSelectionActionTitle(selectAll, "Deselect All", in: app)
        activate(selectAll)
        assertSelectionCount(0, in: app)
        let disabledMove = selectionAction(
            "notebook-move-selected", title: "Move", in: app
        )
        XCTAssertFalse(disabledMove.isEnabled)
        #if os(macOS)
        app.typeKey(.escape, modifierFlags: [])
        #endif
        select(alpha, in: app)
        select(bravo, addingToSelection: true, in: app)

        let rootSheet = openMoveSheet(in: app)
        let rootPath = app.staticTexts["notebook-move-path"]
        XCTAssertTrue(rootPath.waitForExistence(timeout: 5))
        XCTAssertEqual(rootPath.label, "Notebook")
        XCTAssertEqual(
            app.staticTexts["notebook-move-source"].label,
            "2 items"
        )
        activate(app.buttons["notebook-confirm-move"])
        XCTAssertTrue(rootSheet.waitForNonExistence(timeout: 10))
        try assertOrder([alpha, bravo, folder], in: app)
        activate(appMenu(in: app))
        XCTAssertFalse(
            app.descendants(matching: .any)["notebook-browser-undo"].exists
        )
        let selectItems = app.descendants(matching: .any)["notebook-select-items"]
        XCTAssertTrue(selectItems.waitForExistence(timeout: 5))
        activate(selectItems)
        select(alpha, in: app)
        select(bravo, addingToSelection: true, in: app)
        assertSelectionCount(2, in: app)

        openMoveSheet(in: app)
        let cancelMove = app.buttons["notebook-cancel-move"]
        let confirmMove = app.buttons["notebook-confirm-move"]
        XCTAssertTrue(cancelMove.waitForExistence(timeout: 5))
        XCTAssertTrue(confirmMove.waitForExistence(timeout: 5))
        XCTAssertTrue(cancelMove.isEnabled)
        XCTAssertTrue(confirmMove.isEnabled)
        let rootCancelFrame = cancelMove.frame
        let rootConfirmFrame = confirmMove.frame
        XCTAssertFalse(app.buttons["notebook-move-up"].exists)

        browseMoveSheet(to: folder, in: app)
        let path = app.staticTexts["notebook-move-path"]
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        XCTAssertEqual(path.label, "Notebook / Folder \(suffix)")
        XCTAssertTrue(cancelMove.isEnabled)
        XCTAssertTrue(confirmMove.isEnabled)
        XCTAssertEqual(cancelMove.frame, rootCancelFrame)
        XCTAssertEqual(confirmMove.frame, rootConfirmFrame)
        capture(app, name: "Move destination inside folder")

        let moveUp = app.buttons["notebook-move-up"]
        XCTAssertTrue(moveUp.waitForExistence(timeout: 5))
        activate(moveUp)
        XCTAssertEqual(path.label, "Notebook")
        XCTAssertFalse(moveUp.exists)
        XCTAssertTrue(cancelMove.isEnabled)
        XCTAssertTrue(confirmMove.isEnabled)
        XCTAssertEqual(cancelMove.frame, rootCancelFrame)
        XCTAssertEqual(confirmMove.frame, rootConfirmFrame)

        browseMoveSheet(to: folder, in: app)
        XCTAssertEqual(path.label, "Notebook / Folder \(suffix)")
        XCTAssertTrue(cancelMove.isEnabled)
        XCTAssertTrue(confirmMove.isEnabled)
        XCTAssertEqual(cancelMove.frame, rootCancelFrame)
        XCTAssertEqual(confirmMove.frame, rootConfirmFrame)
        activate(cancelMove)
        assertSelectionCount(2, in: app)
        XCTAssertTrue(alpha.exists)
        XCTAssertTrue(bravo.exists)
        finishSelection(in: app)
        XCTAssertTrue(appMenu(in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(newNoteControl(in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(selectAll.exists)

        enterSelectionMode(in: app)
        select(alpha, in: app)
        select(bravo, addingToSelection: true, in: app)
        assertSelectionCount(2, in: app)

        openMoveSheet(in: app)
        browseMoveSheet(to: folder, in: app)
        let moveSheet = app.descendants(matching: .any)["notebook-move-sheet"]
        let confirm = app.buttons["notebook-confirm-move"]
        let idleSize = confirm.frame.size
        capture(app, name: "Move confirmation before submission")
        activate(confirm)
        XCTAssertTrue(
            app.activityIndicators["notebook-move-progress"].waitForExistence(timeout: 3)
        )
        XCTAssertFalse(confirm.isEnabled)
        XCTAssertEqual(confirm.label, "Move Here")
        XCTAssertEqual(confirm.frame.width, idleSize.width, accuracy: 1)
        XCTAssertEqual(confirm.frame.height, idleSize.height, accuracy: 1)
        capture(app, name: "Move confirmation during submission")
        XCTAssertTrue(moveSheet.waitForNonExistence(timeout: 10))
        expand(folder, in: app)
        try assertOrder([folder, alpha, bravo], in: app)
        capture(app, name: "Batch moved into folder")
        collapse(folder, in: app)
        XCTAssertFalse(alpha.exists)
        XCTAssertFalse(bravo.exists)
        activate(appMenu(in: app))
        let undo = app.descendants(matching: .any)["notebook-browser-undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        activate(undo)
        XCTAssertTrue(alpha.waitForExistence(timeout: 5))
        try assertOrder([alpha, bravo, folder], in: app)
    }

    #if os(macOS)
    func testNativeSelectionUsesMacModifiersWithoutOpeningNotes() throws {
        continueAfterFailure = false
        let suffix = String(UUID().uuidString.prefix(8))
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = suffix
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launch()
        let alpha = try createNote(named: "Alpha \(suffix)", in: app)
        let bravo = try createNote(named: "Bravo \(suffix)", in: app)
        let charlie = try createNote(named: "Charlie \(suffix)", in: app)
        XCTAssertEqual(app.buttons["note-title"].label, "Charlie \(suffix)")

        activate(title(of: alpha, in: app))
        XCTAssertEqual(app.buttons["note-title"].label, "Alpha \(suffix)")
        let charlieTitle = title(of: charlie, in: app)
        XCUIElement.perform(withKeyModifiers: .shift) { charlieTitle.click() }
        assertSelectionCount(3, in: app)
        XCTAssertEqual(app.buttons["note-title"].label, "Alpha \(suffix)")
        let bravoTitle = title(of: bravo, in: app)
        XCUIElement.perform(withKeyModifiers: .command) { bravoTitle.click() }
        assertSelectionCount(2, in: app)
        XCTAssertEqual(app.buttons["note-title"].label, "Alpha \(suffix)")

        activate(title(of: bravo, in: app))
        XCTAssertEqual(app.buttons["note-title"].label, "Bravo \(suffix)")
        XCTAssertFalse(app.buttons["notebook-selection-done"].exists)
        app.typeKey("m", modifierFlags: [.command, .shift])
        let cancel = app.buttons["notebook-cancel-move"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        activate(cancel)
        let editor = app.textViews["markdown-editor"]
        activate(editor)
        app.typeKey("m", modifierFlags: [.command, .shift])
        XCTAssertFalse(cancel.exists)

    }
    #endif

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
        title(of: note, in: app).swipeLeft(velocity: .slow)
        capture(app, name: "Native swipe action revealed")
        let trashAction = app.buttons["notebook-swipe-trash"]
        if trashAction.waitForExistence(timeout: 2), trashAction.isHittable {
            trashAction.tap()
        }
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

    private enum RowKind {
        case note
        case folder

        var prefix: String {
            switch self {
            case .note: "notebook-sidebar-note-"
            case .folder: "notebook-sidebar-folder-"
            }
        }
    }

    private func assertSelectionCount(
        _ count: Int, in app: XCUIApplication,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let control = app.buttons["notebook-selection-count"]
        XCTAssertTrue(control.waitForExistence(timeout: 5), file: file, line: line)
        let expected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "\(count) selected"),
            object: control
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed,
                       file: file, line: line)
    }

    private func newNoteControl(in app: XCUIApplication) -> XCUIElement {
        #if os(macOS)
        app.descendants(matching: .any)
            .matching(identifier: "notebook-new-item").firstMatch
        #else
        app.buttons["notebook-new-item"].firstMatch
        #endif
    }

    private func createNote(
        named title: String,
        in app: XCUIApplication
    ) throws -> XCUIElement {
        let control = newNoteControl(in: app)
        XCTAssertTrue(control.waitForExistence(timeout: 15))
        #if os(macOS)
        let newNote = control.buttons.firstMatch
        XCTAssertTrue(newNote.waitForExistence(timeout: 5))
        #else
        let newNote = control
        #endif
        activate(newNote)
        #if os(macOS)
        let field = app.descendants(matching: .any)
            .matching(identifier: "title-field").firstMatch
        #else
        let field = app.textFields["title-field"]
        #endif
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
        let row = row(named: title, kind: .note, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        return row
    }

    private func row(
        named name: String,
        kind: RowKind,
        in app: XCUIApplication
    ) -> XCUIElement {
        #if os(macOS)
        return app.notebookMacFileRow(named: name, identifierPrefix: kind.prefix)
        #else
        let title = app.staticTexts.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label == %@",
                "notebook-sidebar-title-", name
            )
        ).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let id = title.identifier.replacingOccurrences(
            of: "notebook-sidebar-title-", with: ""
        )
        return app.descendants(matching: .any)[kind.prefix + id]
        #endif
    }

    private func title(
        of row: XCUIElement,
        in app: XCUIApplication
    ) -> XCUIElement {
        let id = row.identifier
            .replacingOccurrences(of: "notebook-sidebar-note-", with: "")
            .replacingOccurrences(of: "notebook-sidebar-folder-", with: "")
        let title = app.staticTexts["notebook-sidebar-title-" + id]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        return title
    }

    private func disclosure(
        for folder: XCUIElement,
        in app: XCUIApplication
    ) -> XCUIElement {
        let id = folder.identifier.replacingOccurrences(
            of: "notebook-sidebar-folder-", with: ""
        )
        return app.descendants(matching: .any)["notebook-disclosure-" + id]
    }

    private func expand(_ folder: XCUIElement, in app: XCUIApplication) {
        let control = disclosure(for: folder, in: app)
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        if control.value as? String == "Collapsed" { activate(control) }
    }

    private func collapse(_ folder: XCUIElement, in app: XCUIApplication) {
        let control = disclosure(for: folder, in: app)
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        if control.value as? String == "Expanded" { activate(control) }
    }

    private func chooseSort(_ title: String, in app: XCUIApplication) {
        let menu = appMenu(in: app)
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        activate(menu)
        let sort = app.descendants(matching: .any)["notebook-sort-root"]
        XCTAssertTrue(sort.waitForExistence(timeout: 5))
        activate(sort)
        #if os(macOS)
        let action = app.menuItems[title]
        #else
        let action = app.buttons[title]
        #endif
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        activate(action)
    }

    private func enterSelectionMode(in app: XCUIApplication) {
        let menu = appMenu(in: app)
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        activate(menu)
        let select = app.descendants(matching: .any)["notebook-select-items"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        activate(select)
    }

    private func selectionAction(
        _ identifier: String, title: String, in app: XCUIApplication
    ) -> XCUIElement {
        let control = app.descendants(matching: .any)[identifier]
        #if os(macOS)
        if control.exists && control.isHittable { return control }
        // AppKit places selection actions in its native overflow menu when
        // the toolbar cannot fit them beside the editor's controls.
        let overflow = app.popUpButtons["more toolbar items"]
        XCTAssertTrue(overflow.waitForExistence(timeout: 5))
        overflow.click()
        let item = overflow.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        return item
        #else
        return control
        #endif
    }

    private func assertSelectionActionTitle(
        _ action: XCUIElement, _ title: String, in app: XCUIApplication
    ) {
        #if os(macOS)
        if action.elementType == .menuItem {
            // Native menu items expose their title through keyed lookup.
            XCTAssertTrue(app.popUpButtons["more toolbar items"].menuItems[title].exists)
            return
        }
        #endif
        XCTAssertEqual(action.label, title)
    }

    private func finishSelection(in app: XCUIApplication) {
        let done = selectionAction(
            "notebook-selection-done", title: "Done", in: app
        )
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        activate(done)
    }

    private func select(
        _ row: XCUIElement,
        addingToSelection: Bool = false,
        in app: XCUIApplication
    ) {
        let rowTitle = title(of: row, in: app)
        #if os(macOS)
        if addingToSelection {
            XCUIElement.perform(withKeyModifiers: .command) { rowTitle.click() }
        } else {
            rowTitle.click()
        }
        #else
        rowTitle.tap()
        #endif
    }

    @discardableResult
    private func openMoveSheet(in app: XCUIApplication) -> XCUIElement {
        let move = selectionAction(
            "notebook-move-selected", title: "Move", in: app
        )
        XCTAssertTrue(move.waitForExistence(timeout: 5))
        activate(move)
        let sheet = app.descendants(matching: .any)["notebook-move-sheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        return sheet
    }

    private func browseMoveSheet(
        to folder: XCUIElement,
        in app: XCUIApplication
    ) {
        let id = folder.identifier.replacingOccurrences(
            of: "notebook-sidebar-folder-", with: ""
        )
        let destination = app.descendants(matching: .any)[
            "notebook-move-folder-" + id
        ]
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
        activate(destination)
        XCTAssertTrue(
            app.buttons["notebook-confirm-move"].waitForExistence(timeout: 5)
        )
        XCTAssertEqual(app.buttons["notebook-confirm-move"].label, "Move Here")
    }

    private func assertManualMoveActionsAbsent(
        on note: XCUIElement,
        in app: XCUIApplication
    ) {
        #if os(macOS)
        title(of: note, in: app).rightClick()
        XCTAssertTrue(app.menuItems["Move…"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.menuItems["Move Up"].exists)
        XCTAssertFalse(app.menuItems["Move Down"].exists)
        app.typeKey(.escape, modifierFlags: [])
        #else
        title(of: note, in: app).press(forDuration: 1.0)
        XCTAssertFalse(app.buttons["Move Up"].exists)
        XCTAssertFalse(app.buttons["Move Down"].exists)
        activate(app.buttons["Move…"])
        let cancel = app.buttons["notebook-cancel-move"]
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
        let tree = app.buttons["notebook-tree-toggle"]
        #if os(iOS)
        if !tree.isHittable {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        #endif
        XCTAssertTrue(tree.waitForExistence(timeout: 5))
        let recents = app.buttons["notebook-recents-toggle"]
        if recents.value as? String == "Expanded" {
            activate(recents)
        }
        if tree.value as? String == "Collapsed" {
            activate(tree)
        }
    }

    private func appMenu(in app: XCUIApplication) -> XCUIElement {
        #if os(macOS)
        app.menuButtons["notebook-app-menu"]
        #else
        app.buttons["notebook-app-menu"]
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
