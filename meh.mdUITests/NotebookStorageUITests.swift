import XCTest

/// Every launch uses a unique, local-only fictional notebook in iCloud Dev.
final class NotebookStorageUITests: XCTestCase {
    @MainActor
    func testStorageOverviewReopenAndOpenNote() throws {
#if os(macOS)
        throw XCTSkip("Storage navigation evidence runs on iPhone")
#else
        continueAfterFailure = false
        let app = makeApp(fixture: "storage-large")
        defer { app.terminate() }
        app.launch()
        openSettings(app)
        let backup = app.buttons["notebook-backup-now"]
        reveal(backup, in: app)
        backup.tap()
        let backedUp = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true AND label == %@", "Back Up Now"),
            object: backup)
        XCTAssertEqual(XCTWaiter.wait(for: [backedUp], timeout: 180), .completed)
        reveal(app.buttons["Reset All Local Data…"], in: app)
        capture(app, "Settings with fictional notebook")

        openStorage(app)
        let count = app.staticTexts["notebook-storage-note-count"]
        XCTAssertEqual(count.label, "320 notes")
        XCTAssertTrue(app.staticTexts["7 in Trash"].exists)
        XCTAssertEqual(count.frame.midY, app.staticTexts["7 in Trash"].frame.midY,
                       accuracy: 4, "Active and Trash counts share one row")
        XCTAssertFalse(app.staticTexts["notebook-storage-total"].label.isEmpty)
        capture(app, "Storage overview — 320 fictional notes")
        let back = app.navigationBars["Storage"].buttons["Settings"]
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.tap()
        openStorage(app)
        XCTAssertEqual(count.label, "320 notes")
        XCTAssertTrue(app.staticTexts["7 in Trash"].exists)

        let showAll = app.buttons["notebook-storage-show-all"]
        reveal(showAll, in: app)
        capture(app, "Largest fictional notes")
        showAll.tap()
        XCTAssertTrue(app.navigationBars["All Notes"].waitForExistence(timeout: 10))
        capture(app, "All notes ordered by disk size")
        let row = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "notebook-storage-note-"
        )).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("Fictional observation"))
        let selectedName = String(row.label.prefix(while: { $0 != "," }))
        let selectedIdentifier = row.identifier
        row.tap()
        XCTAssertTrue(app.navigationBars["Note Storage"].waitForExistence(timeout: 10))
        XCTAssertTrue(element("notebook-storage-note-history", in: app).exists)
        capture(app, "Note storage details")
        let open = app.buttons["notebook-storage-open-note"]
        reveal(open, in: app)
        open.tap()
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertTrue((editor.value as? String ?? "").hasPrefix("# "))
        XCTAssertTrue((editor.value as? String ?? "").contains("fictional Northwind station"))
        let title = app.buttons["note-title"].label
        let originalSource = try XCTUnwrap(editor.value as? String)
        XCTAssertTrue(selectedName.contains(title), "Open Note must open the measured note")
        capture(app, "Measured note opened in native editor")

        app.revealNotebookSidebar()
        openSettings(app)
        openStorage(app)
        XCTAssertEqual(count.label, "320 notes")
        XCTAssertFalse(element("notebook-storage-error", in: app).exists)
        let reopenedRow = app.buttons[selectedIdentifier]
        reveal(reopenedRow, in: app)
        reopenedRow.tap()
        reveal(open, in: app)
        open.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertEqual(editor.value as? String, originalSource,
                       "Measuring, reopening and browsing must preserve Markdown exactly")
        XCTAssertEqual(app.buttons["note-title"].label, title)
#endif
    }

    /// Local fixture verifies presentation and navigation, not CloudKit deletion.
    @MainActor
    func testStorageCleanupControlsAndPreserveNote() throws {
#if os(macOS)
        throw XCTSkip("Cleanup controls run on iPhone")
#else
        continueAfterFailure = false
        let app = makeApp(fixture: "storage-large")
        app.launchEnvironment["MEH_STORAGE_CLEANUP_FIXTURE"] = "1"
        defer { app.terminate() }
        app.launch()
        openSettings(app)
        openStorage(app)
        XCTAssertEqual(app.staticTexts["notebook-storage-note-count"].label, "320 notes")
        XCTAssertTrue(app.staticTexts["7 in Trash"].exists)
        let cleanup = app.buttons["notebook-storage-cleanup"]
        reveal(cleanup, in: app)
        XCTAssertTrue(cleanup.isEnabled)
        XCTAssertTrue(element("notebook-storage-last-cleanup", in: app).label.contains("Never"))
        capture(app, "After — fictional Storage cleanup controls")
        cleanup.tap()
        let finished = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: cleanup)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 15), .completed)
        XCTAssertFalse(element("notebook-storage-last-cleanup", in: app).label.contains("Never"))
        XCTAssertTrue(element("notebook-storage-last-cleanup", in: app).exists)
        capture(app, "After — fictional cleanup completed")
        let row = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "notebook-storage-note-"
        )).firstMatch
        reveal(row, in: app)
        row.tap()
        let open = app.buttons["notebook-storage-open-note"]
        reveal(open, in: app)
        open.tap()
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertTrue((editor.value as? String ?? "").contains("fictional Northwind station"))
#endif
    }

    @MainActor
    func testEmptyStorageCanCloseAndReopen() throws {
#if os(macOS)
        throw XCTSkip("Storage navigation evidence runs on iPhone")
#else
        continueAfterFailure = false
        let app = makeApp(fixture: nil, run: "storage-empty-\(UUID().uuidString)")
        defer { app.terminate() }
        app.launch()
        openSettings(app)
        let storage = app.buttons["notebook-storage-settings"]
        reveal(storage, in: app)
        storage.tap()
        // Native Back remains usable even before the measurement publishes.
        let back = app.navigationBars["Storage"].buttons["Settings"]
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.tap()
        openStorage(app)
        XCTAssertEqual(app.staticTexts["notebook-storage-note-count"].label, "0 notes")
        let empty = element("notebook-storage-empty", in: app)
        reveal(empty, in: app)
        XCTAssertTrue(empty.exists)
        XCTAssertFalse(app.buttons["notebook-storage-show-all"].exists)
        XCTAssertFalse(element("notebook-storage-error", in: app).exists)
        capture(app, "Empty local notebook storage")
#endif
    }

    /// Explicit evidence helper; excluded from CI plans and regular regressions.
    /// The caller installs the baseline app against an already seeded preview run.
    @MainActor
    func testCaptureSettingsBeforeStorage() throws {
#if os(macOS)
        throw XCTSkip("Baseline screenshot runs on iPhone")
#else
        guard let run = ProcessInfo.processInfo.environment["MEH_STORAGE_EVIDENCE_RUN"] else {
            throw XCTSkip("Baseline capture requires an explicit isolated evidence run")
        }
        continueAfterFailure = false
        let app = makeApp(fixture: nil, run: run)
        defer { app.terminate() }
        app.launch()
        if app.textViews["markdown-editor"].waitForExistence(timeout: 2) {
            let back = app.navigationBars.buttons["BackButton"]
            XCTAssertTrue(back.waitForExistence(timeout: 10))
            back.tap()
        }
        app.revealNotebookSidebar()
        openSettings(app)
        let reset = app.buttons["Reset All Local Data…"]
        reveal(reset, in: app)
        capture(app, "Before — Settings without Storage")
#endif
    }

#if os(iOS)
    @MainActor
    private func makeApp(fixture: String?, run: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = run
            ?? ProcessInfo.processInfo.environment["MEH_STORAGE_EVIDENCE_RUN"]
            ?? "storage-\(UUID().uuidString)"
        if let fixture { app.launchEnvironment["MEH_NOTEBOOK_TEST_FIXTURE"] = fixture }
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchEnvironment["MEH_SYNC_CLOUDKIT"] = "0"
        app.launchArguments += ["-editor.mode", "source"]
        return app
    }

    @MainActor
    private func openSettings(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["notebook-new-item"].firstMatch.waitForExistence(timeout: 600))
        let settings = app.buttons["notebook-settings"]
        if !settings.isHittable {
            let menu = app.buttons["notebook-app-menu"]
            if !menu.waitForExistence(timeout: 2) {
                // A reused evidence notebook can restore its selected editor.
                let back = app.navigationBars.buttons["BackButton"]
                XCTAssertTrue(back.waitForExistence(timeout: 10))
                back.tap()
            }
            XCTAssertTrue(menu.waitForExistence(timeout: 10))
            menu.tap()
        }
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func openStorage(_ app: XCUIApplication) {
        let storage = app.buttons["notebook-storage-settings"]
        reveal(storage, in: app)
        storage.tap()
        waitForStorage(app)
    }

    @MainActor
    private func waitForStorage(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["notebook-storage-note-count"]
            .waitForExistence(timeout: 180))
        XCTAssertFalse(app.buttons["notebook-storage-refresh"].exists)
        XCTAssertFalse(element("notebook-storage-error", in: app).exists)
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !element.isHittable {
            if element.exists, element.frame.maxY < app.frame.minY + 100 {
                app.swipeDown()
            } else {
                app.swipeUp()
            }
        }
        // SwiftUI can discard accessibility nodes above the viewport. Search
        // back toward the top after exhausting the forward direction.
        for _ in 0..<8 where !element.isHittable { app.swipeDown() }
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
#endif
}
