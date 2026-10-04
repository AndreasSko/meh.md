import XCTest

final class WritingFlowUITests: XCTestCase {
    func testNewNoteSelectsTitleAndKeepsWritingFlowAcrossNotes() throws {
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
        assertKeyboardFocus(on: titleField)
        let generatedTitle = try XCTUnwrap(titleField.value as? String)
        XCTAssertFalse(generatedTitle.isEmpty)
        capture(app, name: "Generated title selected on new note")

        let replacement = "Fictional observatory log"
        titleField.typeText(replacement)
        XCTAssertEqual(titleField.value as? String, replacement)
        capture(app, name: "New note title replaced without tapping")

        submitTitle(titleField)
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        assertKeyboardFocus(on: editor)
        XCTAssertEqual(app.buttons["note-title"].label, replacement)
        let firstBody = "Fictional first note body."
        editor.typeText(firstBody)
        XCTAssertEqual(editor.value as? String, firstBody)
        capture(app, name: "First note body before creating another note")

        // Create another note while the body editor still owns keyboard focus.
        activate(newNote)
        let nextTitle = app.textFields["title-field"]
        XCTAssertTrue(nextTitle.waitForExistence(timeout: 10))
        assertKeyboardFocus(on: nextTitle)
        let nextGeneratedTitle = try XCTUnwrap(nextTitle.value as? String)
        XCTAssertFalse(nextGeneratedTitle.isEmpty)
        let nextReplacement = "Fictional second observatory log"
        nextTitle.typeText(nextReplacement)
        XCTAssertEqual(nextTitle.value as? String, nextReplacement)

        submitTitle(nextTitle)
        assertKeyboardFocus(on: editor)
        XCTAssertEqual(app.buttons["note-title"].label, nextReplacement)
        XCTAssertEqual(editor.value as? String, "")

        activate(newNote)
        let thirdTitle = app.textFields["title-field"]
        XCTAssertTrue(thirdTitle.waitForExistence(timeout: 10))
        assertKeyboardFocus(on: thirdTitle)
        let thirdGeneratedTitle = try XCTUnwrap(thirdTitle.value as? String)
        XCTAssertFalse(thirdGeneratedTitle.isEmpty)

        submitTitle(thirdTitle)
        assertKeyboardFocus(on: editor)
        XCTAssertEqual(app.buttons["note-title"].label, thirdGeneratedTitle)
        XCTAssertEqual(editor.value as? String, "")
    }

    func testRenamingTitleKeepsExistingTitleAndReturnsToBody() throws {
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
        assertKeyboardFocus(on: titleField)
        let title = "Fictional rename regression"
        titleField.typeText(title)
        XCTAssertEqual(titleField.value as? String, title)
        submitTitle(titleField)

        let titleButton = app.buttons["note-title"]
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        assertKeyboardFocus(on: editor)
        let body = "Text retained while renaming the note."
        editor.typeText(body)
        XCTAssertEqual(editor.value as? String, body)

        activate(titleButton)
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        assertKeyboardFocus(on: titleField)
        XCTAssertEqual(titleField.value as? String, title)
        titleField.typeText(" revised")
        let revisedTitle = try XCTUnwrap(titleField.value as? String)
        // A title tap places the native caret where the user tapped.
        XCTAssertNotEqual(revisedTitle, title)
        XCTAssertEqual(
            revisedTitle.replacingOccurrences(of: " revised", with: ""), title
        )
        submitTitle(titleField)

        assertKeyboardFocus(on: editor)
        XCTAssertEqual(titleButton.label, revisedTitle)
        XCTAssertEqual(editor.value as? String, body)
    }

    func testNewNoteTitleCommitsIntoBodyWithoutTitleActions() throws {
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
        let titleFocused = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"),
            object: titleField
        )
        XCTAssertEqual(XCTWaiter.wait(for: [titleFocused], timeout: 5), .completed)
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let proposedTitle = "Fictional observatory field notes about distant moons "
            + "and bright stars across the northern winter sky "
            + UUID().uuidString.prefix(8)
        #if os(iOS)
        let generatedTitle = try XCTUnwrap(titleField.value as? String)
        XCTAssertFalse(generatedTitle.isEmpty)
        let firstWord = "Fictional observatory"
        titleField.typeText(firstWord)
        XCTAssertEqual(titleField.value as? String, firstWord)
        capture(app, name: "Generated date replaced by first words")
        titleField.typeText(String(proposedTitle.dropFirst(firstWord.count)))
        XCTAssertEqual(titleField.value as? String, proposedTitle)
        #else
        // The generated title is selected on Mac as well.
        titleField.typeText(proposedTitle)
        XCTAssertEqual(titleField.value as? String, proposedTitle)
        #endif
        #if os(macOS)
        titleField.typeKey(.return, modifierFlags: [])
        #else
        titleField.typeText("\n")
        #endif
        let title = app.buttons["note-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, proposedTitle)
        XCTAssertFalse(title.label.lowercased().hasSuffix(".md"))
        let bodyFocused = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"),
            object: editor
        )
        XCTAssertEqual(XCTWaiter.wait(for: [bodyFocused], timeout: 5), .completed)
        let source = "Fictional observatory notes: café 👋🏽 and stars."
        editor.typeText(source)
        XCTAssertEqual(editor.value as? String, source)
        XCTAssertFalse(app.buttons["Done"].exists)
        XCTAssertFalse(app.buttons["Cancel"].exists)
        XCTAssertFalse(app.buttons["notebook-note-title-done"].exists)
        XCTAssertFalse(app.buttons["notebook-note-title-cancel"].exists)

        activate(title)
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        #if os(macOS)
        let revisedTitle = proposedTitle + " revised"
        replaceTitle(in: titleField, with: revisedTitle)
        #else
        let renameFocused = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"),
            object: titleField
        )
        XCTAssertEqual(XCTWaiter.wait(for: [renameFocused], timeout: 5), .completed)
        titleField.typeText(" revised")
        let revisedTitle = try XCTUnwrap(titleField.value as? String)
        XCTAssertNotEqual(revisedTitle, proposedTitle)
        XCTAssertEqual(
            revisedTitle.replacingOccurrences(of: " revised", with: ""),
            proposedTitle
        )
        #endif
        #if os(macOS)
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: 40, dy: 20)).click()
        #else
        editor.tap()
        #endif
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, revisedTitle)
        XCTAssertEqual(editor.value as? String, source)
        #if os(iOS)
        XCTAssertGreaterThan(title.frame.height, 45)
        #endif
        capture(app, name: "Wrapped title and fictional note")

        let nextNote = app.buttons["notebook-new-item"].firstMatch
        XCTAssertTrue(nextNote.waitForExistence(timeout: 5))
        activate(nextNote)
        let nextTitleField = app.textFields["title-field"]
        XCTAssertTrue(nextTitleField.waitForExistence(timeout: 5))
        let retainedDateTitle = try XCTUnwrap(nextTitleField.value as? String)
        XCTAssertFalse(retainedDateTitle.isEmpty)
        #if os(macOS)
        nextTitleField.typeKey(.return, modifierFlags: [])
        #else
        nextTitleField.typeText("\n")
        #endif
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let emptyEditor = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", ""), object: editor
        )
        XCTAssertEqual(XCTWaiter.wait(for: [emptyEditor], timeout: 5), .completed)
        let unchangedTitleFocusedBody = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"),
            object: editor
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [unchangedTitleFocusedBody], timeout: 5),
            .completed
        )
        XCTAssertEqual(title.label, retainedDateTitle)
        #if os(macOS)
        activate(title)
        let tabTitleField = app.textFields["title-field"]
        XCTAssertTrue(tabTitleField.waitForExistence(timeout: 5))
        tabTitleField.typeKey(.tab, modifierFlags: [])
        let bodyFocusedAfterTab = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"),
            object: editor
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [bodyFocusedAfterTab], timeout: 5),
            .completed
        )
        #endif
        capture(app, name: "New note ready for body writing")
    }

    func testSyncStatusLivesInCloudDetailsWhileWriting() throws {
        guard let endpoint = ProcessInfo.processInfo.environment["MEH_WAVE1_SYNC_URL"] else {
            throw XCTSkip("Requires the disposable loopback sync service")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_SYNC_URL"] = endpoint
        app.launchEnvironment["MEH_SYNC_WORKSPACE"] = "writing-ui-" + UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launch()
        let newNote = app.buttons["notebook-new-item"].firstMatch
        XCTAssertTrue(newNote.waitForExistence(timeout: 20))
        activate(newNote)
        let titleField = app.textFields["title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 10))
        #if os(macOS)
        titleField.typeKey(.return, modifierFlags: [])
        #else
        titleField.typeText("\n")
        #endif
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.typeText("A fictional cloud observatory entry")
        XCTAssertFalse(app.staticTexts["note-sync-status"].exists)
        XCTAssertFalse(saveStatus(in: app).exists)
        app.openSyncDetails()
        activate(app.buttons["sync-now"])
        let synced = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@",
                        "Last sync:", "Last sync:")
        ).firstMatch
        XCTAssertTrue(synced.waitForExistence(timeout: 20))
        capture(app, name: "Cloud details during fictional-note writing")
        app.closeSyncDetails()
        XCTAssertFalse(app.staticTexts["note-sync-status"].exists)

        app.terminate()
        app.launchEnvironment["MEH_SYNC_SIMULATE_OFFLINE"] = "1"
        app.launch()
        _ = try app.openOrCreateNotebookEditor(timeout: 20)
        #if os(iOS)
        if app.frame.width < 600 {
            XCTAssertFalse(app.buttons["notebook-sync-details"].isHittable)
        }
        #endif
        app.openSyncDetails()
        activate(app.buttons["sync-now"])
        let paused = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                        "Sync paused", "Sync paused")
        ).firstMatch
        XCTAssertTrue(paused.waitForExistence(timeout: 20))
        app.closeSyncDetails()
        XCTAssertFalse(app.staticTexts["note-sync-status"].exists)
        XCTAssertFalse(saveStatus(in: app).exists)
        capture(app, name: "Paused cloud indicator without a writing progress bar")
    }

    private func activate(_ element: XCUIElement) {
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed)
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    private func saveStatus(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "note-save-status").firstMatch
    }

    private func assertKeyboardFocus(on element: XCUIElement) {
        let focused = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 5), .completed)
    }

    private func submitTitle(_ field: XCUIElement) {
        #if os(macOS)
        field.typeKey(.return, modifierFlags: [])
        #else
        field.typeText("\n")
        #endif
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

    #if os(macOS)
    private func replaceTitle(in field: XCUIElement, with title: String) {
        field.typeKey("a", modifierFlags: .command)
        field.typeText(title)
    }
    #endif
}
