import XCTest

final class NoteHistoryUITests: XCTestCase {
    func testBrowsingKeepsCurrentTextAndOffersBothRestorePaths() throws {
        continueAfterFailure = false
        let app = makeApp(run: "history-pr-after-\(UUID().uuidString)")
        app.launch()

        let title = "Aurora Observatory"
        let firstBody = """
        # September sky log

        The first telescope scan found three pale rings.

        North ridge was clear. Valley station was cloudy.

        """
        let addition = "\nNew scan."
        createNote(in: app, title: title, body: firstBody)
        let editor = app.textViews["markdown-editor"]
        XCTAssertEqual(editor.value as? String, firstBody)
        reopenCurrentNote(in: app, expectedText: firstBody)
        editor.typeText(addition)
        let currentBody = firstBody + addition
        XCTAssertEqual(editor.value as? String, currentBody)
        dismissKeyboardTipIfNeeded(in: app)
        reopenCurrentNote(in: app, expectedText: currentBody)
        #if os(iOS)
        editor.swipeDown()
        editor.swipeDown()
        #endif

        #if os(macOS)
        let actions = app.menuButtons["notebook-note-actions"]
        #else
        let actions = app.buttons["notebook-note-actions"]
        #endif
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        activate(actions)
        let history = app.descendants(matching: .any)
            .matching(identifier: "notebook-version-history").firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        if !history.isHittable {
            let menu = app.collectionViews.containing(
                .button, identifier: "notebook-version-history"
            ).firstMatch
            XCTAssertTrue(menu.exists)
            for _ in 0..<3 where !history.isHittable { menu.swipeUp() }
        }
        XCTAssertTrue(history.isHittable)
        capture(app, name: "Aurora Observatory current note actions")
        activate(history)

        let preview = app.textViews["note-history-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertEqual(preview.value as? String, currentBody)
        let previous = app.buttons["note-history-previous"]
        XCTAssertTrue(previous.exists)
        activate(previous)
        XCTAssertEqual(preview.value as? String, firstBody)
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "note-history-status").firstMatch.exists)
        capture(app, name: "Aurora Observatory earlier text in History")

        #if os(macOS)
        let dateList = app.menuButtons["note-history-date-list"]
        #else
        let dateList = app.buttons["note-history-date-list"]
        #endif
        XCTAssertTrue(dateList.exists)
        #if os(iOS)
        XCTAssertGreaterThanOrEqual(dateList.frame.height, 44)
        dateList.coordinate(
            withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)
        ).tap()
        XCTAssertTrue(app.buttons["Current version"].waitForExistence(timeout: 5))
        capture(app, name: "Aurora Observatory dated versions menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.3)).tap()
        #endif

        let restore = app.buttons["note-history-restore"]
        XCTAssertTrue(restore.exists)
        activate(restore)
        XCTAssertTrue(app.buttons["Restore This Note…"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Restore as New Note"].exists)
        activate(app.buttons["Restore This Note…"])
        XCTAssertTrue(app.buttons["Restore This Note"].waitForExistence(timeout: 5))
        activate(app.buttons["Cancel"].firstMatch)

        activate(app.buttons["note-history-done"])
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, currentBody)
        XCTAssertFalse(app.textViews["note-history-preview"].exists)
    }

    func testRestoreAsNewNoteKeepsOriginalCurrentText() throws {
        #if os(macOS)
        throw XCTSkip("Restore as New Note navigation is covered on iPhone")
        #else
        continueAfterFailure = false
        let app = makeApp(run: "history-copy-test-\(UUID().uuidString)")
        app.launch()

        let title = "Recovery Sketch"
        let firstBody = "Morning light over the ridge."
        let currentBody = firstBody + "\nClear."
        createNote(in: app, title: title, body: firstBody)
        reopenCurrentNote(in: app, expectedText: firstBody)
        let editor = app.textViews["markdown-editor"]
        editor.typeText("\nClear.")
        XCTAssertEqual(editor.value as? String, currentBody)
        reopenCurrentNote(in: app, expectedText: currentBody)

        let actions = app.buttons["notebook-note-actions"]
        activate(actions)
        let history = app.descendants(matching: .any)
            .matching(identifier: "notebook-version-history").firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        activate(history)
        let preview = app.textViews["note-history-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        activate(app.buttons["note-history-detail-toggle"])
        let previous = app.buttons["note-history-previous"]
        for _ in 0..<12 where (preview.value as? String) != firstBody {
            XCTAssertTrue(previous.isEnabled)
            activate(previous)
        }
        XCTAssertEqual(preview.value as? String, firstBody)
        activate(app.buttons["note-history-restore"])
        activate(app.buttons["Restore as New Note"])

        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["note-title"].label, "Recovery Sketch (Restored)")
        XCTAssertEqual(editor.value as? String, firstBody)
        let back = app.navigationBars.buttons.firstMatch
        activate(back)
        let original = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@"
                + " AND NOT label CONTAINS[c] %@",
            "notebook-recent-", title, "(Restored)"
        )).firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        activate(original)
        XCTAssertEqual(app.buttons["note-title"].label, title)
        XCTAssertEqual(editor.value as? String, currentBody)
        #endif
    }

    private func makeApp(run: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = run
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "source"]
        return app
    }

    private func createNote(in app: XCUIApplication, title: String, body: String) {
        let newNote = app.buttons["notebook-new-item"].firstMatch
        XCTAssertTrue(newNote.waitForExistence(timeout: 15))
        activate(newNote)
        let titleField = app.textFields["title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 10))
        replaceTitle(in: titleField, app: app, with: title)
        XCTAssertEqual(titleField.value as? String, title)
        #if os(macOS)
        titleField.typeKey(.return, modifierFlags: [])
        #else
        titleField.typeText("\n")
        #endif
        XCTAssertEqual(app.buttons["note-title"].label, title)
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.typeText(body)
    }

    private func replaceTitle(
        in field: XCUIElement, app: XCUIApplication, with title: String
    ) {
        #if os(macOS)
        field.typeKey("a", modifierFlags: .command)
        field.typeText(title)
        #else
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
        #endif
    }

    private func activate(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    private func dismissKeyboardTipIfNeeded(in app: XCUIApplication) {
        let continueButton = app.buttons["Continue"].firstMatch
        if continueButton.waitForExistence(timeout: 1) {
            activate(continueButton)
        }
    }

    private func reopenCurrentNote(in app: XCUIApplication, expectedText: String) {
        #if os(iOS)
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        activate(back)
        let recent = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "notebook-recent-"
        )).firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        activate(recent)
        #else
        _ = app.flushCurrentEditorBySwitchingNotes()
        #endif
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, expectedText)
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
