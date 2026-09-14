import XCTest

final class WritingFlowUITests: XCTestCase {
    func testNewNoteTitleCommitsIntoBodyWithoutTitleActions() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
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
        replaceTitle(in: titleField, app: app, with: proposedTitle)
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
        let revisedTitle = proposedTitle + " revised"
        replaceTitle(in: titleField, app: app, with: revisedTitle)
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
        XCTAssertNotEqual(title.label, revisedTitle)
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
        let cloud = app.buttons["notebook-sync-details"].firstMatch
        XCTAssertTrue(cloud.waitForExistence(timeout: 5))
        app.openSyncDetails()
        activate(app.buttons["sync-now"])
        let paused = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                        "Sync paused", "Sync paused")
        ).firstMatch
        XCTAssertTrue(paused.waitForExistence(timeout: 20))
        app.closeSyncDetails()
        XCTAssertTrue(cloud.label.contains("paused"))
        XCTAssertFalse(app.staticTexts["note-sync-status"].exists)
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
}
