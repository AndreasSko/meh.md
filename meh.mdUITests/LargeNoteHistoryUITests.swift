import XCTest

/// Runs against a fictional, isolated notebook, including in iCloud Dev.
final class LargeNoteHistoryUITests: XCTestCase {
    // UI readiness includes slow accessibility queries on hosted simulators.
    // App latency remains guarded by the separate History benchmarks.
    private let historyReadinessTimeout: TimeInterval = 180

    @MainActor
    func testLargeHistoryCanCloseWhileIndexingAndBrowseWithoutChangingNote() throws {
#if os(macOS)
        throw XCTSkip("Large History interaction regression runs on iPhone")
#else
        continueAfterFailure = false
        let app = makeApp()
        defer { app.terminate() }
        app.launch()
        openFixture(in: app)
        let editor = app.textViews["markdown-editor"]
        let current = try readSource(from: editor)
        let expectedFixture = "# Fictional Observatory\n" + String(repeating:
            "Café e\u{301} 👋🏽 observations from a fictional mountain station.\n",
            count: 1_800) + (0..<600).map { $0 % 19 == 0 ? "\n" : "x" }.joined()
        XCTAssertTrue(current.utf8.elementsEqual(expectedFixture.utf8),
                      "Editor must contain this complete fictional fixture")

        // Close immediately after opening, before waiting for the index.
        // This checks the cancellation path independently of completed browsing.
        openHistory(in: app)
        let done = app.buttons["note-history-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertTrue(done.isEnabled)
        done.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textViews["note-history-preview"].exists)
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        let addition = "\nFictional cancellation check."
        editor.typeText(addition)
        let updated = try readSource(from: editor)
        let unchangedParts = updated.components(separatedBy: addition)
        XCTAssertEqual(unchangedParts.count, 2,
                       "The editor must contain exactly one complete addition")
        XCTAssertTrue(unchangedParts.joined().utf8.elementsEqual(current.utf8),
                      "Typing must preserve every original source byte")

        openHistory(in: app)
        let preview = app.textViews["note-history-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        waitForIndexReady(in: app)
        let previous = app.buttons["note-history-previous"]
        waitUntilEnabled(previous, timeout: historyReadinessTimeout)
        previous.tap()
        waitForPreviewReady(in: app)
        let earlier = try readSource(from: preview)
        XCTAssertFalse(earlier.utf8.elementsEqual(updated.utf8))
        app.buttons["note-history-next"].tap()
        waitForPreviewReady(in: app)
        let nextSource = try readSource(from: preview)
        let firstDifference = zip(updated.utf8, nextSource.utf8)
            .prefix(while: { $0.0 == $0.1 }).count
        XCTAssertTrue(nextSource.utf8.elementsEqual(updated.utf8),
                      "Returning to Current must match the validated live edit; " +
                      "expected \(updated.utf8.count) UTF-8 bytes, " +
                      "actual \(nextSource.utf8.count), " +
                      "first differing byte offset \(firstDifference)")
        done.tap()
        XCTAssertTrue(try readSource(from: editor).utf8.elementsEqual(updated.utf8),
                      "Browsing historical text must leave current source intact")
        openHistory(in: app)
        waitForIndexReady(in: app)
        waitUntilEnabled(previous, timeout: historyReadinessTimeout)
        previous.tap()
        waitForPreviewReady(in: app)
        XCTAssertTrue(try readSource(from: preview).utf8.elementsEqual(earlier.utf8))
        capture(app, name: "Large History can close, browse and reopen safely")
        done.tap()
#endif
    }

#if os(iOS)
    @MainActor
    private func readSource(from textView: XCUIElement) throws -> String {
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        // Read the actual editor once after the small readiness markers settle.
        // Compare UTF-8 locally rather than polling the full source through AX.
        return try XCTUnwrap(textView.value as? String)
    }
#endif

    @MainActor
    private func waitForPreviewReady(in app: XCUIApplication) {
        waitForLoadingToFinish(
            "note-history-preview-loading", in: app, timeout: historyReadinessTimeout
        )
    }

    @MainActor
    private func waitForIndexReady(in app: XCUIApplication) {
        waitForLoadingToFinish(
            "note-history-index-loading", in: app, timeout: historyReadinessTimeout
        )
    }

    @MainActor
    private func waitForLoadingToFinish(
        _ identifier: String, in app: XCUIApplication, timeout: TimeInterval
    ) {
        let loading = app.descendants(matching: .any)
            .matching(identifier: identifier).firstMatch
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: loading
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed)
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
        app.launchEnvironment["MEH_SYNC_CLOUDKIT"] = "0"
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
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
