import XCTest

#if os(iOS)
/// Opt-in native-editor checks for the permanently isolated Development lab.
/// The installer must verify the app binary and bundled UUID before XCTest.
final class NotebookAutomaticCloudUITests: XCTestCase {
    func testOutageEditsSurviveAutomaticRecoveryAndRestarts() throws {
#if NOTEBOOK_CLOUD_UI_LAB && DEBUG && ICLOUD_DEV && ICLOUD_ENABLED
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let run = environment["MEH_AUTOMATIC_CLOUD_UI_RUN"] else {
            throw XCTSkip("Set a unique MEH_AUTOMATIC_CLOUD_UI_RUN to opt in.")
        }
        let uuid = try XCTUnwrap(UUID(uuidString: run))
        try XCTSkipUnless(
            environment["MEH_AUTOMATIC_CLOUD_UI_PREFLIGHT"] == uuid.uuidString,
            "Run the isolated-app installer and attest its exact bundled UUID."
        )
        let app = XCUIApplication()
        app.launchArguments = ["-editor.mode", "source"]
        app.launchEnvironment["MEH_SYNC_SIMULATE_OFFLINE"] = "1"
        app.launch()

        app.revealNotebookSidebar(timeout: 60)
        let newNote = app.buttons["notebook-new-item"].firstMatch
        XCTAssertTrue(newNote.waitForExistence(timeout: 15))
        newNote.tap()
        let title = app.textFields["title-field"]
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        title.typeText("Fictional recovery \(uuid.uuidString.prefix(8))")
        title.typeText("\n")
        let body = "Fictional automatic recovery \(uuid.uuidString)\n"
            + "Written during a simulated outage. Café and stars.\n"
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        editor.tap()
        editor.typeText(body)
        XCTAssertEqual(editor.value as? String, body)
        _ = app.flushCurrentEditorBySwitchingNotes(timeout: 20)
        XCTAssertEqual(editor.value as? String, body)
        capture(app, name: "Outage edit retained locally")
        openSyncDetails(app)
        let status = app.staticTexts["note-sync-status"]
        let outage = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@",
            "Sync paused", "Sync paused"
        ), object: status)
        // CloudKit account setup runs before the simulated-outage wrapper.
        // Give a freshly restored simulator account a bounded startup window.
        XCTAssertEqual(XCTWaiter.wait(for: [outage], timeout: 120), .completed)
        XCTAssertTrue(app.staticTexts["sync-local-saving-explanation"]
            .waitForExistence(timeout: 10))
        closeSyncDetails(app, body: body)

        app.terminate()
        app.launch()
        XCTAssertNotNil(app.openNotebookNote(withText: body))
        XCTAssertEqual(editor.value as? String, body)
        capture(app, name: "Outage cold restart retains exact body")

        app.terminate()
        app.launchEnvironment.removeValue(forKey: "MEH_SYNC_SIMULATE_OFFLINE")
        app.launch()
        XCTAssertNotNil(app.openNotebookNote(withText: body))
        openSyncDetails(app)
        let lastSync = app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Last sync:"
        )).firstMatch
        let successful = XCTNSPredicateExpectation(predicate: NSPredicate {
            _, _ in
            lastSync.exists && lastSync.label.hasPrefix("Last sync:")
                && !lastSync.label.contains("Never")
        }, object: lastSync)
        XCTAssertEqual(
            XCTWaiter.wait(for: [successful], timeout: 120), .completed,
            "Expected automatic CloudKit exchange after removing the outage"
        )
        let syncEvidence = XCTAttachment(string: lastSync.label)
        syncEvidence.name = "Automatic sync status"
        syncEvidence.lifetime = .keepAlways
        add(syncEvidence)
        capture(app, name: "Automatic recovery without Sync Now")
        closeSyncDetails(app, body: body)
        XCTAssertEqual(editor.value as? String, body)

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertNotNil(app.openNotebookNote(withText: body))
        XCTAssertEqual(editor.value as? String, body)
        app.terminate()
        app.launch()
        XCTAssertNotNil(app.openNotebookNote(withText: body))
        XCTAssertEqual(editor.value as? String, body)
        capture(app, name: "Recovered cold restart retains exact body")
        let fixture = XCTAttachment(string: body)
        fixture.name = "Exact fictional body for Mac peer verification"
        fixture.lifetime = .keepAlways
        add(fixture)
        app.terminate()
#else
        throw XCTSkip(
            "Requires NOTEBOOK_CLOUD_UI_LAB, DEBUG, ICLOUD_DEV, ICLOUD_ENABLED."
        )
#endif
    }

    private func openSyncDetails(_ app: XCUIApplication) {
        app.revealNotebookSidebar(timeout: 20)
        let button = app.buttons["notebook-sync-details"]
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        button.tap()
        XCTAssertTrue(app.staticTexts["note-sync-status"]
            .waitForExistence(timeout: 15))
    }

    private func closeSyncDetails(_ app: XCUIApplication, body: String) {
        let close = app.buttons["notebook-sync-details-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.tap()
        let closed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 10), .completed)
        XCTAssertNotNil(app.openNotebookNote(withText: body))
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
