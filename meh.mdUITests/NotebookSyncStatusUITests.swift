import XCTest

final class NotebookSyncStatusUITests: XCTestCase {
    func testPendingSaveWaitsWithoutManualSaveInstructions() throws {
        let app = makeSaveFixture(state: "waiting")
        app.launch()
        XCTAssertTrue(app.buttons["notebook-sync-details"].waitForExistence(timeout: 30))
        app.openSyncDetails()
        let status = app.staticTexts["note-sync-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(status.label, "Waiting to sync")
        XCTAssertFalse(app.buttons["sync-now"].exists)
        XCTAssertFalse(app.staticTexts["sync-retry-countdown"].exists)
        XCTAssertFalse(app.staticTexts["sync-failure-explanation"].exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(
            format: "label CONTAINS[c] %@", "Save before syncing"
        )).firstMatch.exists)
        app.terminate()
    }

    func testSaveFailureKeepsStorageWarningAndRetry() throws {
        let app = makeSaveFixture(state: "failed")
        app.launch()
        app.openSyncDetails()
        let status = app.staticTexts["note-sync-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(status.label, "Device storage is full")
        XCTAssertTrue(app.staticTexts["sync-failure-explanation"].exists)
        // The fixture's retry cooldown shows a countdown until Try Again.
        XCTAssertTrue(app.staticTexts["sync-retry-countdown"].exists)
        XCTAssertFalse(app.buttons["sync-now"].exists)
        app.terminate()
    }

    func testProlongedSaveWaitExplainsAutomaticRetry() throws {
        let app = makeSaveFixture(state: "prolonged")
        app.launch()
        app.openSyncDetails()
        let status = app.staticTexts["note-sync-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(status.label, "Sync is still waiting")
        XCTAssertEqual(
            app.staticTexts["sync-failure-explanation"].label,
            "Sync will continue when changes are saved on this device."
        )
        // The fixture's retry cooldown shows a countdown until Try Again.
        XCTAssertTrue(app.staticTexts["sync-retry-countdown"].exists)
        XCTAssertFalse(app.buttons["sync-now"].exists)
        app.terminate()
    }

    func testNotebookNavigationAllowsToolbarPopoversToReopen() throws {
        let app = makeFixture()
        app.launch()
        let syncButton = app.buttons["notebook-sync-details"]
        XCTAssertTrue(syncButton.waitForExistence(timeout: 30))
        app.openSyncDetails()
        let syncStatus = app.staticTexts["note-sync-status"]
        XCTAssertTrue(syncStatus.waitForExistence(timeout: 5))
        capture(app, name: "Popover bug - sync details open")

        let notes = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "notebook-sidebar-note-"
        ))
        XCTAssertTrue(notes.firstMatch.waitForExistence(timeout: 15))

        let note = notes.firstMatch
        let editor = app.textViews["markdown-editor"]
        let noteTap = app.coordinate(withNormalizedOffset: CGVector(
            dx: note.frame.midX / app.frame.width,
            dy: note.frame.midY / app.frame.height
        ))
        noteTap.tap()
        let navigatedOnFirstTap = editor.waitForExistence(timeout: 3)
        if !navigatedOnFirstTap {
            XCTAssertFalse(syncStatus.exists, "The first note tap should dismiss the popover")
            noteTap.tap()
        }
        let navigated = navigatedOnFirstTap || editor.waitForExistence(timeout: 10)
        XCTAssertTrue(
            navigated,
            "A note tap should navigate after the popover is dismissed"
        )
        capture(app, name: "Popover bug - note opened directly from browser")

        let tree = app.buttons["notebook-tree-toggle"]
        if !tree.isHittable {
            let back = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            back.tap()
        }
        XCTAssertTrue(tree.waitForExistence(timeout: 10))
        XCTAssertTrue(syncButton.isHittable)

        syncButton.tap()
        let reopenedSync = syncStatus.waitForExistence(timeout: 5)
        if reopenedSync {
            capture(app, name: "Popover bug - sync details reopened")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
            let dismissed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: syncStatus
            )
            _ = XCTWaiter.wait(for: [dismissed], timeout: 5)
        }

        let menu = app.buttons["notebook-app-menu"]
        XCTAssertTrue(menu.isHittable)
        menu.tap()
        let newNoteAction = app.buttons.matching(
            NSPredicate(format: "label == %@", "New Note")
        ).firstMatch
        let menuReopened = newNoteAction.waitForExistence(timeout: 5)
        if menuReopened {
            capture(app, name: "Popover bug - browser menu reopened")
        }
        XCTAssertTrue(reopenedSync, "The sync details popover should reopen after note navigation")
        XCTAssertTrue(menuReopened, "The ellipsis menu should open after note navigation")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        XCTAssertTrue(syncButton.isHittable)
        syncButton.tap()
        XCTAssertTrue(syncStatus.waitForExistence(timeout: 5))
        let plus = app.buttons["notebook-new-item"].firstMatch
        XCTAssertTrue(plus.exists)
        let plusTap = app.coordinate(withNormalizedOffset: CGVector(
            dx: plus.frame.midX / app.frame.width,
            dy: plus.frame.midY / app.frame.height
        ))
        plusTap.tap()
        XCTAssertFalse(syncStatus.exists, "The first plus tap should dismiss sync details")
        XCTAssertFalse(editor.exists, "The first plus tap should not create a note")
        plusTap.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "The second plus tap should create a note")
        capture(app, name: "After - new note created from toolbar plus")

        let treeAfterCreate = app.buttons["notebook-tree-toggle"]
        if !treeAfterCreate.isHittable {
            let back = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            back.tap()
        }
        XCTAssertTrue(treeAfterCreate.waitForExistence(timeout: 10))
        XCTAssertTrue(syncButton.isHittable)
        syncButton.tap()
        XCTAssertTrue(syncStatus.waitForExistence(timeout: 5))
        capture(app, name: "After - sync details reopened after new note")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        let menuAfterCreate = app.buttons["notebook-app-menu"]
        XCTAssertTrue(menuAfterCreate.isHittable)
        menuAfterCreate.tap()
        XCTAssertTrue(newNoteAction.waitForExistence(timeout: 5))
        capture(app, name: "After - ellipsis reopened after new note")
        app.terminate()
    }

    func testToolbarOpensStatusAndShowsActiveFilesDuringSync() throws {
        let app = makeFixture()
        // Each phase must outlast the checks and screenshots taken in it,
        // which can take several seconds on a slow simulator.
        app.launchEnvironment["MEH_NOTEBOOK_SYNC_PHASE_SECONDS"] = "12"
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
            XCTWaiter.wait(for: [waiting, waitingPercent], timeout: 45), .completed,
            "The active fetch should wait at the 20 percent phase boundary"
        )
        XCTAssertEqual(progress.label, "Overall sync progress")
        XCTAssertLessThan(overallStatus.frame.maxY, progress.frame.minY)
        XCTAssertLessThan(progress.frame.maxY, status.frame.minY)
        let waitingElapsed = app.staticTexts["notebook-sync-work-count"]
        XCTAssertTrue(waitingElapsed.exists)
        let initialWaitingLabel = waitingElapsed.label
        capture(app, name: "After - waiting at 20 percent")
        let timerAdvanced = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard status.label.contains("Waiting for iCloud"),
                      waitingElapsed.exists else { return false }
                return waitingElapsed.label != initialWaitingLabel
            },
            object: waitingElapsed
        )
        let checkingHistory = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "Checking iCloud history"),
            object: status
        )
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [timerAdvanced, checkingHistory], timeout: 30,
                enforceOrder: true
            ), .completed,
            "The waiting timer should advance before remote-history checking"
        )
        XCTAssertEqual(progress.value as? String, "20 percent complete")
        capture(app, name: "After - checking iCloud history")
        let sending = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "Sending 3 notes"),
            object: status
        )
        let weightedUploadStart = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "55 percent complete"),
            object: progress
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [sending, weightedUploadStart], timeout: 45), .completed,
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
        for filename in ["Field notes.md", "Tide chart.md", "Island sketch.md"] {
            XCTAssertTrue(
                app.staticTexts[filename].waitForExistence(timeout: 5),
                "Expected the expanded list to include \(filename)"
            )
        }
        XCTAssertGreaterThanOrEqual(
            activeNames.count, 3,
            "Expected the three fictional active note names during upload"
        )
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
            XCTWaiter.wait(for: [synced], timeout: 90), .completed,
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

#if os(iOS)
    func testNoteNavigationAfterClosingSyncRecoversToolbarPresentation() throws {
        continueAfterFailure = false
        let app = makeFixture()
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "1"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["notebook-sync-details"].waitForExistence(timeout: 30))
        let notes = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "notebook-sidebar-note-"
        ))
        XCTAssertTrue(notes.firstMatch.waitForExistence(timeout: 10))
        let noteFrame = notes.firstMatch.frame
        let noteTap = app.coordinate(withNormalizedOffset: CGVector(
            dx: noteFrame.midX / app.frame.width,
            dy: noteFrame.midY / app.frame.height
        ))
        let anchorMaxY = app.buttons["notebook-sync-details"].frame.maxY
        app.openSyncDetails()
        capture(app, name: "Note navigation - compact sync before atomic note taps")
        noteTap.doubleTap()
        let editor = app.textViews["markdown-editor"]
        // UIKit may consume the double tap as one popover dismissal.
        // Retry navigation immediately, without waiting for the editor first.
        if !editor.exists { noteTap.tap() }
        capture(app, name: "Note navigation - immediately after note navigation")
        XCTAssertTrue(editor.waitForExistence(timeout: 10),
                      "Note navigation should recover immediately after status dismissal")
        capture(app, name: "Note navigation - note editor after atomic taps")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let status = app.staticTexts["note-sync-status"]
        capture(app, name: "Note navigation - foreground native presentation")
        assertStatusClosed(status)
        app.revealNotebookSidebar()
        app.openSyncDetails()
        capture(app, name: "Note navigation - compact sync reopens")
        XCTAssertLessThan(status.frame.minY, anchorMaxY + 200)
        closeBrowserSyncDetails(app)
        app.openNotebookSettings(timeout: 5)
        capture(app, name: "Note navigation - Settings opens after return")
        app.navigationBars["Settings"].buttons["Done"].tap()
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.navigationBars["Settings"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
    }

    func testAutomaticSyncRecoversAfterExtendedBackground() throws {
        continueAfterFailure = false
        let app = makeFixture()
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "1"
        app.launch()
        defer { app.terminate() }
        app.openSyncDetails()
        capture(app, name: "Automatic lifecycle - compact sync before background")
        closeBrowserSyncDetails(app)
        let controlCenterStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.01))
        let controlCenterEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.6))
        controlCenterStart.press(forDuration: 0.1, thenDragTo: controlCenterEnd)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        capture(springboard, name: "Automatic lifecycle - Control Center")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        assertStatusClosed(app.staticTexts["note-sync-status"])
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        Thread.sleep(forTimeInterval: 25)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let status = app.staticTexts["note-sync-status"]
        assertStatusClosed(status)
        XCTAssertTrue(app.buttons["notebook-sync-details"].isHittable)
        capture(app, name: "Automatic lifecycle - returned browser")
        let anchorMaxY = app.buttons["notebook-sync-details"].frame.maxY
        app.openSyncDetails()
        XCTAssertLessThan(status.frame.minY, anchorMaxY + 200,
                          "Automatic foreground sync should preserve compact presentation")
        capture(app, name: "Automatic lifecycle - reopened compact sync")
        closeBrowserSyncDetails(app)
        for reopen in 1...2 {
            app.openNotebookSettings(timeout: 5)
            capture(app, name: "Automatic lifecycle - reopened Settings \(reopen)")
            app.navigationBars["Settings"].buttons["Done"].tap()
            let dismissed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"),
                object: app.navigationBars["Settings"]
            )
            XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        }
    }

#endif

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

    private func closeBrowserSyncDetails(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        assertStatusClosed(app.staticTexts["note-sync-status"])
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name) - hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
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

    private func makeSaveFixture(state: String) -> XCUIApplication {
        let app = makeFixture()
        app.launchEnvironment["MEH_NOTEBOOK_SYNC_SAVE_STATE"] = state
        return app
    }
}
