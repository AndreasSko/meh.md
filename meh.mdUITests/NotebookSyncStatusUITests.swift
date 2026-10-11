import XCTest

final class NotebookSyncStatusUITests: XCTestCase {
    func testToolbarOpensStatusAndShowsActiveFilesDuringSync() throws {
        let app = makeFixture()
        app.launch()
        XCTAssertTrue(
            app.buttons["notebook-sync-details"].waitForExistence(timeout: 30),
            "Expected the isolated notebook workspace to finish loading"
        )

        app.openSyncDetails()
        let activity = app.activityIndicators["notebook-sync-activity"]
        XCTAssertTrue(activity.waitForExistence(timeout: 5))
        let status = app.staticTexts["note-sync-status"]
        XCTAssertEqual(activity.frame.midY, status.frame.midY, accuracy: 4)
        XCTAssertGreaterThanOrEqual(activity.frame.minX, status.frame.maxX)
        capture(app, name: "After - compact sync status")
        let sending = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "Sending 3 notes"),
            object: status
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [sending], timeout: 20), .completed,
            "The first toolbar tap should start the isolated upload"
        )
        let activeFiles = app.buttons["notebook-sync-active-files"]
        XCTAssertTrue(activeFiles.waitForExistence(timeout: 10))
        XCTAssertTrue(activity.exists)
        XCTAssertTrue(app.progressIndicators["notebook-sync-progress"].exists)
        capture(app, name: "After - current upload")
        activeFiles.tap()

        let activeNames = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "notebook-sync-active-file-"
            )
        )
        XCTAssertGreaterThanOrEqual(
            activeNames.count, 3,
            "Expected the three fictional active note names during upload"
        )
        for filename in ["Field notes.md", "Tide chart.md", "Island sketch.md"] {
            XCTAssertTrue(
                app.staticTexts[filename].exists,
                "Expected the expanded list to include \(filename)"
            )
        }
        capture(app, name: "After - all active filenames")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        assertStatusClosed(status)
        capture(app, name: "After - progress without opening status")
        app.buttons["notebook-sync-details"].tap()
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        let synced = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Synced with iCloud"),
            object: status
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [synced], timeout: 30), .completed,
            "The status should return to its normal synced state"
        )
        XCTAssertTrue(app.staticTexts["notebook-sync-last-success"].exists)
        XCTAssertFalse(activity.exists)
        XCTAssertFalse(app.progressIndicators["notebook-sync-progress"].exists)
        capture(app, name: "After - completed sync")
        XCTAssertEqual(
            activeNames.count, 0,
            "Completed uploads should clear the temporary active file list"
        )
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        assertStatusClosed(status)
        app.terminate()
    }

    func testSettingsContainsTheSyncEventLog() throws {
        let app = makeFixture()
        app.launch()
        XCTAssertTrue(
            app.buttons["notebook-sync-details"].waitForExistence(timeout: 30),
            "Expected the isolated notebook workspace to finish loading"
        )

        app.openNotebookSettings()

        let eventLog = app.buttons["notebook-sync-event-log"]
        for _ in 0..<6 where !eventLog.isHittable { app.swipeUp() }
        XCTAssertTrue(eventLog.waitForExistence(timeout: 5))
        capture(app, name: "After - diagnostics in Settings")
        eventLog.tap()
        let logText = app.descendants(matching: .any)
            .matching(identifier: "notebook-sync-event-log-text").firstMatch
        XCTAssertTrue(
            logText.waitForExistence(timeout: 10)
        )
        XCTAssertTrue(app.buttons["notebook-sync-event-log-copy"].exists)
        app.terminate()
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertStatusClosed(_ status: XCUIElement) {
        let closed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: status
        )
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
    }

    private func makeFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        let runID = "sync-status-\(UUID().uuidString)"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = runID
        app.launchEnvironment["MEH_NOTEBOOK_TEST_FIXTURE"] = "sync-status"
        return app
    }
}
