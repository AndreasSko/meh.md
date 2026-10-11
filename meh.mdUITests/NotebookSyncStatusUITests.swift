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
        let overallStatus = app.staticTexts["notebook-sync-overall-status"]
        XCTAssertTrue(overallStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(overallStatus.label.contains("Syncing with iCloud"))
        let status = app.staticTexts["note-sync-status"]
        let progress = app.progressIndicators["notebook-sync-progress"]
        XCTAssertEqual(activity.frame.midY, overallStatus.frame.midY, accuracy: 4)
        XCTAssertGreaterThanOrEqual(activity.frame.minX, overallStatus.frame.maxX)
        let waiting = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "Waiting for iCloud"),
            object: status
        )
        let waitingPercent = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "20 percent complete"),
            object: progress
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [waiting, waitingPercent], timeout: 30), .completed,
            "The active fetch should wait at the 20 percent phase boundary"
        )
        XCTAssertEqual(progress.label, "Overall sync progress")
        XCTAssertLessThan(overallStatus.frame.maxY, progress.frame.minY)
        XCTAssertLessThan(progress.frame.maxY, status.frame.minY)
        let waitingElapsed = app.staticTexts["notebook-sync-work-count"]
        XCTAssertTrue(waitingElapsed.exists)
        let initialWaitingLabel = waitingElapsed.label
        let timerAdvanced = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", initialWaitingLabel),
            object: waitingElapsed
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [timerAdvanced], timeout: 4), .completed,
            "The waiting timer should advance while sync remains at 20 percent"
        )
        XCTAssertEqual(progress.value as? String, "20 percent complete")
        capture(app, name: "After - waiting at 20 percent")
        let sending = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "Sending 3 notes"),
            object: status
        )
        let weightedUploadStart = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "55 percent complete"),
            object: progress
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [sending, weightedUploadStart], timeout: 30), .completed,
            "The first toolbar tap should start the isolated upload"
        )
        XCTAssertEqual(progress.value as? String, "55 percent complete")
        XCTAssertLessThan(overallStatus.frame.maxY, progress.frame.minY)
        XCTAssertLessThan(progress.frame.maxY, status.frame.minY)
        XCTAssertEqual(waitingElapsed.label, "0 of 3 notes sent")
        let activeFiles = app.buttons["notebook-sync-active-files"]
        XCTAssertTrue(activeFiles.waitForExistence(timeout: 10))
        XCTAssertTrue(activity.exists)
        XCTAssertTrue(progress.exists)
        capture(app, name: "After - weighted upload at 55 percent")
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
