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

        18 September — North ridge
        The team recorded a faint light beyond the valley.
        Trail conditions were dry, with a gentle northern wind.
        Supplies included water, a notebook, and wool gloves.
        The return route passed the old fictional shelter.

        19 September — Forest station
        Clouds lifted shortly after noon above the river.
        The telescope remained beside the narrow crossing.
        A quiet observation followed the afternoon walk.
        We left enough time to return before sunset.

        20 September — Quiet campsite
        The final scan found three rings above the ridge.
        We packed the tent after the morning dew dried.
        The route continued past the hill toward the valley.
        Tomorrow the observatory will compare these notes.

        """
        let addition = "\nNew scan."
        createNote(in: app, title: title, body: firstBody)
        let editor = app.textViews["markdown-editor"]
        XCTAssertEqual(editor.value as? String, firstBody)
        reopenCurrentNote(in: app, expectedText: firstBody)
        activate(editor)
        editor.typeText(addition)
        let currentBody = try bodyAfterInserting(addition, into: editor,
                                               original: firstBody)
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
        waitForPreview(currentBody, in: preview)
        let previous = app.buttons["note-history-previous"]
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true"),
            object: previous
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        activate(previous)
        waitForPreview(firstBody, in: preview)
        activate(app.buttons["note-history-next"])
        waitForPreview(currentBody, in: preview)
        activate(previous)
        waitForPreview(firstBody, in: preview)
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "note-history-status").firstMatch.exists)
        capture(app, name: "Aurora Observatory earlier text in History")

        #if os(iOS)
        let timeline = app.sliders["note-history-timeline"]
        XCTAssertTrue(timeline.exists)
        timeline.adjust(toNormalizedSliderPosition: 0)
        timeline.coordinate(
            withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)
        ).press(
            forDuration: 0.1,
            thenDragTo: timeline.coordinate(
                withNormalizedOffset: CGVector(dx: 1.05, dy: 0.5)
            )
        )
        waitForPreview(currentBody, in: preview)
        activate(previous)
        waitForPreview(firstBody, in: preview)
        #endif
        let detail = app.buttons["note-history-detail-toggle"]
        XCTAssertTrue(detail.exists)
        activate(detail)
        XCTAssertTrue(app.buttons["Overview"].waitForExistence(timeout: 5))
        waitForPreview(firstBody, in: preview)
        activate(detail)
        XCTAssertTrue(app.buttons["More Detail"].waitForExistence(timeout: 5))
        waitForPreview(firstBody, in: preview)

        #if os(iOS)
        preview.swipeUp()
        preview.swipeUp()
        capture(app, name: "Aurora Observatory final lines above History controls")
        #endif

        #if os(macOS)
        let dateList = app.menuButtons["note-history-date-list"]
        #else
        let dateList = app.buttons["note-history-date-list"]
        #endif
        XCTAssertTrue(dateList.exists)
        #if os(iOS)
        XCTAssertGreaterThanOrEqual(dateList.frame.height, 44)
        activate(dateList)
        capture(app, name: "Aurora Observatory dated versions menu")
        let currentVersion = app.buttons["Current version"]
        if !currentVersion.exists {
            let menu = app.collectionViews.firstMatch
            XCTAssertTrue(menu.waitForExistence(timeout: 5))
            for _ in 0..<3 where !currentVersion.exists { menu.swipeDown() }
        }
        XCTAssertTrue(currentVersion.waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.3)).tap()
        #endif

        let restore = app.buttons["note-history-restore"]
        XCTAssertTrue(restore.exists)
        activate(restore)
        #if os(macOS)
        // Native confirmation sheets mirror their actions in the Touch Bar.
        // Target the visible sheet rather than those duplicate controls.
        let restoreActions = app.sheets.buttons
        #else
        let restoreActions = app.buttons
        #endif
        XCTAssertTrue(restoreActions["Restore This Note…"].waitForExistence(timeout: 5))
        XCTAssertTrue(restoreActions["Restore as New Note"].exists)
        activate(restoreActions["Restore This Note…"])
        XCTAssertTrue(restoreActions["Restore This Note"].waitForExistence(timeout: 5))
        activate(restoreActions["Cancel"].firstMatch)

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
        let addition = "\nClear."
        createNote(in: app, title: title, body: firstBody)
        reopenCurrentNote(in: app, expectedText: firstBody)
        let editor = app.textViews["markdown-editor"]
        activate(editor)
        editor.typeText(addition)
        let currentBody = try bodyAfterInserting(addition, into: editor,
                                               original: firstBody)
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
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true"),
            object: previous
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        for _ in 0..<12 where (preview.value as? String) != firstBody {
            XCTAssertTrue(previous.isEnabled)
            let oldText = preview.value as? String ?? ""
            activate(previous)
            let changed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value != %@", oldText),
                object: preview
            )
            XCTAssertEqual(
                XCTWaiter.wait(for: [changed], timeout: 10), .completed
            )
        }
        waitForPreview(firstBody, in: preview)
        activate(app.buttons["note-history-restore"])
        activate(app.buttons["Restore as New Note"])

        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["note-title"].label, "Recovery Sketch (Restored)")
        XCTAssertEqual(editor.value as? String, firstBody)
        revealFiles(in: app)
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

    private func bodyAfterInserting(
        _ addition: String, into editor: XCUIElement, original: String
    ) throws -> String {
        let inserted = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", addition),
            object: editor
        )
        XCTAssertEqual(XCTWaiter.wait(for: [inserted], timeout: 10), .completed)
        let actual = try XCTUnwrap(editor.value as? String)
        XCTAssertEqual(actual.components(separatedBy: addition).count - 1, 1)
        XCTAssertEqual(actual.replacingOccurrences(of: addition, with: ""), original)
        return actual
    }

    private func waitForPreview(_ text: String, in preview: XCUIElement) {
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", text), object: preview
        )
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 10), .completed)
    }

    private func makeApp(run: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = run
        app.launchEnvironment.removeValue(forKey: "MEH_SYNC_URL")
        app.launchEnvironment.removeValue(forKey: "MEH_SYNC_CLOUDKIT")

        app.launchArguments += ["-editor.mode", "source"]
        return app
    }

    private func createNote(in app: XCUIApplication, title: String, body: String) {
        #if os(macOS)
        let newNoteControl = app.descendants(matching: .any)
            .matching(identifier: "notebook-new-item").firstMatch
        XCTAssertTrue(newNoteControl.waitForExistence(timeout: 15))
        let newNote = newNoteControl.buttons.firstMatch
        #else
        let newNote = app.buttons["notebook-new-item"].firstMatch
        #endif
        XCTAssertTrue(newNote.waitForExistence(timeout: 15))
        activate(newNote)
        #if os(macOS)
        let titleField = app.descendants(matching: .any)
            .matching(identifier: "title-field").firstMatch
        #else
        let titleField = app.textFields["title-field"]
        #endif
        XCTAssertTrue(titleField.waitForExistence(timeout: 10))
        replaceTitle(in: titleField, app: app, with: title)
        let titleEntered = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", title),
            object: titleField
        )
        XCTAssertEqual(XCTWaiter.wait(for: [titleEntered], timeout: 10), .completed)
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
        field.click()
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

    #if os(iOS)
    private func revealFiles(in app: XCUIApplication) {
        let tree = app.buttons["notebook-tree-toggle"]
        if !tree.isHittable {
            let back = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            activate(back)
        }
        XCTAssertTrue(tree.isHittable)
    }
    #endif

    private func reopenCurrentNote(in app: XCUIApplication, expectedText: String) {
        #if os(iOS)
        revealFiles(in: app)
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
