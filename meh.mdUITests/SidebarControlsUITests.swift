import XCTest

final class SidebarControlsUITests: XCTestCase {
    func testEmptyTrashClosesBackToSelectedNote() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "source"]
        app.launch()

        let newNote = app.buttons["notebook-new-item"].firstMatch
        XCTAssertTrue(newNote.waitForExistence(timeout: 15))
        activate(newNote)
        let titleField = app.textFields["title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 10))
        #if os(macOS)
        titleField.typeKey(.return, modifierFlags: [])
        #else
        titleField.typeText("\n")
        #endif

        let editor = app.textViews["markdown-editor"]
        let title = app.buttons["note-title"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let originalTitle = title.label
        let source = (1...12).map { "Line \($0)" }.joined(separator: "\n")
            + "\nFinal visible line"
        activate(editor)
        editor.typeText(source)
        XCTAssertEqual(editor.value as? String, source)
        showSidebar(app)

        let settings = app.buttons["notebook-settings"]
        let trash = app.buttons["notebook-trash-toggle"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(trash.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(settings.frame.width, 60)
        XCTAssertLessThanOrEqual(trash.frame.width, 60)
        XCTAssertEqual(settings.frame.midY, trash.frame.midY, accuracy: 4)
        XCTAssertLessThan(settings.frame.midX, trash.frame.midX)

        app.openTrash()
        XCTAssertTrue(app.buttons["notebook-trash-close"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Trash is empty"].waitForExistence(timeout: 5))
        capture(app, name: "Dedicated empty Trash")
        app.closeTrash()

        let originalNote = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label == %@",
                "notebook-sidebar-note-", originalTitle
            )
        ).firstMatch
        XCTAssertTrue(originalNote.waitForExistence(timeout: 5))
        activate(originalNote)
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, originalTitle)
        XCTAssertEqual(editor.value as? String, source)
        XCTAssertFalse(
            app.descendants(matching: .any)
                .matching(identifier: "note-save-status").firstMatch.exists
        )
        #if os(iOS)
        if app.frame.width < 600 {
            XCTAssertFalse(settings.isHittable)
            XCTAssertFalse(trash.isHittable)
            if app.keyboards.firstMatch.exists {
                XCTAssertLessThanOrEqual(
                    editor.frame.maxY, app.keyboards.firstMatch.frame.minY + 1,
                    "The editor must remain above the keyboard"
                )
            } else {
                XCTAssertGreaterThanOrEqual(
                    editor.frame.maxY, app.frame.maxY - 1,
                    "The editor must extend through the bottom container safe area"
                )
            }
        }
        #endif
        capture(app, name: "Selected note after closing Trash")
    }

    #if os(iOS)
    func testEmptyTrashRequiresConfirmation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launch()

        let newNote = app.buttons["notebook-new-item"].firstMatch
        XCTAssertTrue(newNote.waitForExistence(timeout: 15))
        newNote.tap()
        let titleField = app.textFields["title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 10))
        titleField.typeText("\n")
        let title = app.buttons["note-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let noteTitle = title.label
        showSidebar(app)

        let note = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label == %@",
                "notebook-sidebar-note-", noteTitle
            )
        ).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.swipeLeft(velocity: .slow)
        let trashAction = app.buttons["notebook-swipe-trash"]
        if trashAction.waitForExistence(timeout: 2), trashAction.isHittable {
            trashAction.tap()
        }
        XCTAssertFalse(note.exists)

        app.openTrash()
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        let emptyTrash = app.buttons["notebook-empty-trash"]
        XCTAssertTrue(emptyTrash.waitForExistence(timeout: 5))
        emptyTrash.tap()
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(app.buttons["Delete Permanently"].waitForExistence(timeout: 5))
        if cancel.exists {
            cancel.tap()
        } else {
            // iPad confirmations cancel by dismissing the popover.
            let dismiss = try XCTUnwrap(app.otherElements.matching(
                identifier: "PopoverDismissRegion"
            ).allElementsBoundByIndex.last)
            XCTAssertTrue(dismiss.exists)
            dismiss.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        }
        XCTAssertTrue(note.waitForExistence(timeout: 5))

        emptyTrash.tap()
        let delete = app.buttons["Delete Permanently"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertTrue(
            app.staticTexts["Trash is empty"].waitForExistence(timeout: 10)
        )
        XCTAssertFalse(note.exists)
    }
    #endif

    private func showSidebar(_ app: XCUIApplication) {
        #if os(iOS)
        if !app.buttons["notebook-trash-toggle"].isHittable {
            app.navigationBars.buttons.firstMatch.tap()
        }
        #endif
        XCTAssertTrue(
            app.buttons["notebook-trash-toggle"].waitForExistence(timeout: 5)
        )
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
