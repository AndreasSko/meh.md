import XCTest

final class NotebookOrderingUITests: XCTestCase {
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
        XCTAssertTrue(app.buttons["2 selected"].waitForExistence(timeout: 5))
        let trashSelected = app.descendants(matching: .any)[
            "notebook-trash-selected"
        ]
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
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Folder \(suffix)")
        field.typeKey(.return, modifierFlags: [])
        #else
        replaceTitle(in: field, app: app, with: "Folder \(suffix)")
        field.typeText("\n")
        #endif
        let folder = row(named: "Folder \(suffix)", kind: .folder, in: app)
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        enterSelectionMode(in: app)
        select(alpha, in: app)
        select(bravo, addingToSelection: true, in: app)
        XCTAssertTrue(app.buttons["2 selected"].waitForExistence(timeout: 5))

        openMoveSheet(in: app)
        let path = app.staticTexts["notebook-move-path"]
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        XCTAssertEqual(path.label, "Notebook")
        XCTAssertEqual(app.staticTexts["notebook-move-source"].label, "2 items")
        browseMoveSheet(to: folder, in: app)
        XCTAssertEqual(path.label, "Notebook / Folder \(suffix)")
        let moveUp = app.buttons["notebook-move-up"]
        XCTAssertTrue(moveUp.waitForExistence(timeout: 5))
        activate(moveUp)
        XCTAssertEqual(path.label, "Notebook")
        XCTAssertFalse(moveUp.exists)
        browseMoveSheet(to: folder, in: app)
        XCTAssertEqual(path.label, "Notebook / Folder \(suffix)")
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
        XCTAssertTrue(app.buttons["3 selected"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["note-title"].label, "Alpha \(suffix)")
        let bravoTitle = title(of: bravo, in: app)
        XCUIElement.perform(withKeyModifiers: .command) { bravoTitle.click() }
        XCTAssertTrue(app.buttons["2 selected"].waitForExistence(timeout: 5))
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
        // A short drag reveals the action without committing a full swipe.
        let start = note.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        let end = note.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow,
                    thenHoldForDuration: 0.2)
        let trashAction = app.buttons["notebook-swipe-trash"]
        XCTAssertTrue(trashAction.waitForExistence(timeout: 5))
        XCTAssertTrue(note.exists, "Revealing the action must keep the note")
        capture(app, name: "Native swipe action revealed")
        trashAction.tap()
        XCTAssertTrue(note.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["notebook-browser-undo"].exists)
        XCTAssertFalse(app.buttons["notebook-browser-redo"].exists)
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
        let row = row(named: title, kind: .note, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        return row
    }

    private func row(
        named name: String,
        kind: RowKind,
        in app: XCUIApplication
    ) -> XCUIElement {
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

    private func enterSelectionMode(in app: XCUIApplication) {
        let menu = appMenu(in: app)
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        activate(menu)
        let select = app.descendants(matching: .any)["notebook-select-items"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        activate(select)
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
        let move = app.descendants(matching: .any)["notebook-move-selected"]
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

    private func restore(_ item: XCUIElement, in app: XCUIApplication) {
        #if os(macOS)
        visibleRowCenter(item).rightClick()
        let restore = app.menuItems["Restore"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        activate(restore)
        #else
        app.chooseRowAction("Restore", on: item)
        #endif
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
