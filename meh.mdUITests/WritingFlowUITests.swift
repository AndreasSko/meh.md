import XCTest

final class WritingFlowUITests: XCTestCase {
    func testImmediateWritingAndInlineTitleKeepContent() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "source"]
        app.launch()

        let newNote = app.buttons["notebook-new-item"].firstMatch
        XCTAssertTrue(newNote.waitForExistence(timeout: 15))
        activate(newNote)
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["Name"].exists)
        let title = app.buttons["notebook-note-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let initialTitle = title.label
        XCTAssertFalse(initialTitle.lowercased().hasSuffix(".md"))
        #if os(iOS)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        #endif
        // No editor tap: creation must already have focused the native buffer.
        let source = "Fictional observatory notes: café 👋🏽 and stars."
        editor.typeText(source)
        XCTAssertEqual(editor.value as? String, source)
        activate(title)
        let titleField = app.descendants(matching: .any)
            .matching(identifier: "notebook-note-title-field").firstMatch
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        let proposedTitle = "Fictional observatory field notes about distant moons "
            + "and bright stars across the northern winter sky"
        #if os(macOS)
        titleField.typeKey("a", modifierFlags: .command)
        titleField.typeText(proposedTitle)
        #else
        titleField.tap()
        titleField.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) {
            app.menuItems["Select All"].tap()
            titleField.typeText(proposedTitle)
        } else {
            titleField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                                       count: initialTitle.count) + proposedTitle)
        }
        #endif
        let done = app.buttons["notebook-note-title-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        activate(done)
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, proposedTitle)
        XCTAssertEqual(editor.value as? String, source)
        #if os(iOS)
        XCTAssertGreaterThan(title.frame.height, 45)
        #endif
        capture(app, name: "Wrapped title and fictional note")

        let nextNote = app.buttons["notebook-new-item"].firstMatch
        XCTAssertTrue(nextNote.waitForExistence(timeout: 5))
        activate(nextNote)
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let emptyEditor = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", ""), object: editor
        )
        XCTAssertEqual(XCTWaiter.wait(for: [emptyEditor], timeout: 5), .completed)
        XCTAssertNotEqual(title.label, proposedTitle)
        capture(app, name: "New note ready for immediate writing")
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
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.typeText("A fictional cloud observatory entry")
        XCTAssertFalse(app.staticTexts["note-sync-status"].exists)
        app.openSyncDetails()
        activate(app.buttons["sync-now"])
        let synced = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Last sync:")
        ).firstMatch
        XCTAssertTrue(synced.waitForExistence(timeout: 20))
        capture(app, name: "Cloud details during fictional-note writing")
        app.closeSyncDetails()
        XCTAssertFalse(app.staticTexts["note-sync-status"].exists)

        app.terminate()
        app.launchEnvironment["MEH_SYNC_SIMULATE_OFFLINE"] = "1"
        app.launch()
        _ = try app.openOrCreateNotebookEditor(timeout: 20)
        let cloud = app.buttons["notebook-sync-details"].firstMatch
        XCTAssertTrue(cloud.waitForExistence(timeout: 5))
        app.openSyncDetails()
        activate(app.buttons["sync-now"])
        let paused = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Sync paused")
        ).firstMatch
        XCTAssertTrue(paused.waitForExistence(timeout: 20))
        app.closeSyncDetails()
        XCTAssertTrue(cloud.label.contains("paused"))
        XCTAssertFalse(app.staticTexts["note-sync-status"].exists)
        capture(app, name: "Paused cloud indicator without a writing progress bar")
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
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        #else
        let attachment = XCTAttachment(screenshot: app.screenshot())
        #endif
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
