import XCTest

/// Runs against a fictional, isolated notebook, including in iCloud Dev.
final class LargeNoteHistoryUITests: XCTestCase {
    @MainActor
    func testLargeHistoryLoadsBrowsesAndReopens() throws {
        #if os(macOS)
        throw XCTSkip("Large History interaction regression runs on iPhone and iPad")
        #endif
        continueAfterFailure = false
        let app = makeApp()
        app.launch()
        openFixture(in: app)
        let current = try XCTUnwrap(app.textViews["markdown-editor"].value as? String)

        openHistory(in: app)
        let preview = app.textViews["note-history-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10),
                      "Large History should show its current preview promptly")
        waitForValue(current, in: preview)
        let heading = app.descendants(matching: .any)
            .matching(identifier: "note-history-title").firstMatch
        XCTAssertTrue(heading.exists)
        let navigationBar = app.navigationBars.firstMatch
        XCTAssertTrue(navigationBar.exists)
        XCTAssertGreaterThanOrEqual(heading.frame.minY, navigationBar.frame.maxY)
        let loading = app.descendants(matching: .any)
            .matching(identifier: "note-history-index-loading").firstMatch
        let completionStarted = Date()
        var completionPolls = 0
        // A large accessibility snapshot can consume 20 seconds on CI. This
        // functional wait allows polling; Swift Release guards enforce timing.
        let finished = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                completionPolls += 1
                guard let indicator = object as? XCUIElement else { return false }
                return !indicator.exists
            }, object: loading
        )
        let completionResult = XCTWaiter.wait(for: [finished], timeout: 60)
        XCTAssertEqual(completionResult, .completed,
                       "Index completion polls: \(completionPolls), elapsed: " +
                       "\(Date().timeIntervalSince(completionStarted)) seconds")
        let previous = app.buttons["note-history-previous"]
        waitUntilEnabled(previous, timeout: 20)
        previous.tap()
        waitForDifferentValue(current, in: preview)
        let earlier = try XCTUnwrap(preview.value as? String)
        XCTAssertNotEqual(earlier, current)

        // Each tap can supersede a still-running preview request. The last
        // selected version must win, even if an older request finishes later.
        let next = app.buttons["note-history-next"]
        for _ in 0..<3 {
            waitUntilEnabled(next, timeout: 30)
            next.tap()
            waitUntilEnabled(previous, timeout: 30)
            previous.tap()
        }
        waitUntilEnabled(next, timeout: 30)
        next.tap()
        waitForValue(current, in: preview)
        let stalePreview = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let actual = (object as? XCUIElement)?.value as? String else {
                    return false
                }
                return actual != current
            }, object: preview
        )
        stalePreview.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [stalePreview], timeout: 2), .completed)
        capture(app, name: "Large History current version after rapid browsing")
        let detail = app.buttons["note-history-detail-toggle"]
        detail.tap()
        XCTAssertTrue(app.buttons["Overview"].waitForExistence(timeout: 5))
        previous.tap()
        waitForDifferentValue(current, in: preview)
        app.buttons["note-history-date-list"].tap()
        let currentVersion = app.buttons["Current version"]
        let menu = app.collectionViews.firstMatch
        for _ in 0..<3 where !currentVersion.exists {
            if menu.exists { menu.swipeDown() }
        }
        XCTAssertTrue(currentVersion.waitForExistence(timeout: 5))
        currentVersion.tap()
        waitForValue(current, in: preview)
        detail.tap()
        XCTAssertTrue(app.buttons["More Detail"].waitForExistence(timeout: 5))

        app.buttons["note-history-done"].tap()
        XCTAssertTrue(app.textViews["markdown-editor"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textViews["markdown-editor"].value as? String, current)
        openHistory(in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        // Accessibility snapshots of the large preview can take over 20
        // seconds on CI. Core tests separately enforce cache timing.
        waitUntilEnabled(previous, timeout: 30)
        previous.tap()
        waitForValue(earlier, in: preview)
        capture(app, name: "Large History reopened with cached versions")
    }

    @MainActor
    func testClosingLargeHistoryKeepsEditorAvailable() throws {
        #if os(macOS)
        throw XCTSkip("Large History interaction regression runs on iPhone and iPad")
        #endif
        continueAfterFailure = false
        let app = makeApp()
        app.launch()
        openFixture(in: app)
        let editor = app.textViews["markdown-editor"]
        let current = try XCTUnwrap(editor.value as? String)
        openHistory(in: app)
        let done = app.buttons["note-history-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5),
                      "History must remain dismissible during indexing")
        XCTAssertTrue(done.isEnabled)
        done.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, current)
        editor.tap()
        editor.typeText("\nFictional cancellation check.")
        let updated = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@",
                                   "Fictional cancellation check."),
            object: editor
        )
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 5), .completed)
        XCTAssertFalse(app.textViews["note-history-preview"].exists)
    }

    @MainActor
    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] =
            "history-large-\(UUID().uuidString)"
        app.launchEnvironment["MEH_NOTEBOOK_HISTORY_FIXTURE"] = "1"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchEnvironment.removeValue(forKey: "MEH_SYNC_URL")
        app.launchEnvironment.removeValue(forKey: "MEH_SYNC_CLOUDKIT")
        app.launchArguments += ["-editor.mode", "source"]
        return app
    }

    @MainActor
    private func openFixture(in app: XCUIApplication) {
        if app.textViews["markdown-editor"].waitForExistence(timeout: 1) {
            XCTAssertEqual(app.buttons["note-title"].label, "Aurora Observatory")
            return
        }
        let note = app.descendants(matching: .any).matching(identifier:
            "notebook-sidebar-note-11111111-2222-4333-8444-555555555555"
        ).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 60))
        note.tap()
        XCTAssertTrue(app.textViews["markdown-editor"].waitForExistence(timeout: 20))
    }

    @MainActor
    private func openHistory(in app: XCUIApplication) {
        app.buttons["notebook-note-actions"].tap()
        let history = app.descendants(matching: .any)
            .matching(identifier: "notebook-version-history").firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        if !history.isHittable {
            let menu = app.collectionViews.containing(
                .button, identifier: "notebook-version-history"
            ).firstMatch
            for _ in 0..<3 where !history.isHittable { menu.swipeUp() }
        }
        history.tap()
    }

    @MainActor
    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval) {
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: timeout), .completed)
    }

    @MainActor
    private func waitForValue(_ value: String, in element: XCUIElement) {
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                (object as? XCUIElement)?.value as? String == value
            }, object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 10), .completed)
    }

    @MainActor
    private func waitForDifferentValue(_ value: String, in element: XCUIElement) {
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let actual = (object as? XCUIElement)?.value as? String else {
                    return false
                }
                return actual != value
            }, object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 10), .completed)
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
