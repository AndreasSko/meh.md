import XCTest

#if os(iOS)
final class SpeakerModeUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testSliderPicksStopwatchOrCountdownAndLocksWhileRunning() {
        let app = launch()
        let island = turnOnSpeakerMode(in: app)
        XCTAssertEqual(island.label, "Speaker timer, 15 minutes left")

        island.tap()
        let length = app.otherElements["speaker-length"]
        XCTAssertTrue(length.waitForExistence(timeout: 5))
        XCTAssertEqual(length.value as? String, "15 min")

        drag(length, to: 0)
        XCTAssertEqual(length.value as? String, "Stopwatch")
        XCTAssertEqual(island.label, "Speaker timer, 0 seconds")

        drag(length, to: 1)
        XCTAssertEqual(length.value as? String, "60 min")
        XCTAssertEqual(island.label, "Speaker timer, 1 hour left")

        // Dragged with the finger well below the pill, it steps by minutes.
        let middle = length.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        middle.press(forDuration: 0.05,
                     thenDragTo: middle.withOffset(CGVector(dx: -60, dy: 160)))
        let fine = length.value as? String ?? ""
        XCTAssertFalse(fine.hasSuffix("0 min") || fine.hasSuffix("5 min") || fine == "Stopwatch",
                       "A fine drag should land between the 5-minute steps, not on \(fine)")
        drag(length, to: 1)

        let reset = app.buttons["speaker-reset"]
        let startPause = app.buttons["speaker-start-pause"]
        XCTAssertFalse(reset.isEnabled)
        startPause.tap()
        XCTAssertTrue(length.waitForNonExistence(timeout: 5),
                      "Starting should close the controls")
        island.tap()
        XCTAssertTrue(length.waitForExistence(timeout: 5))
        XCTAssertEqual(startPause.label, "Pause")
        XCTAssertTrue(reset.isEnabled)

        drag(length, to: 0)
        XCTAssertEqual(length.value as? String, "60 min",
                       "The length should stay put while the timer runs")

        reset.tap()
        XCTAssertEqual(startPause.label, "Start")
        drag(length, to: 0)
        XCTAssertEqual(length.value as? String, "Stopwatch")
    }

    func testIslandFloatsOverTheNoteDocksAgainAndCloses() {
        let app = launch()
        let island = turnOnSpeakerMode(in: app)
        let window = app.windows.firstMatch
        let close = app.buttons["speaker-close"]
        XCTAssertFalse(close.exists, "In the toolbar the island has no ×")

        drag(island, to: window.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.6)))
        XCTAssertTrue(close.waitForExistence(timeout: 5), "Over the note the island shows a ×")
        let dropped = island.frame
        XCTAssertGreaterThan(dropped.midY, window.frame.height * 0.45)

        island.tap()
        XCTAssertTrue(app.otherElements["speaker-length"].waitForExistence(timeout: 5),
                      "The floating island still opens its controls")
        app.buttons["speaker-start-pause"].tap()

        // Dropped near the top centre, it clicks into place there.
        drag(island, to: window.coordinate(withNormalizedOffset: CGVector(dx: 0.53, dy: 0.14)))
        XCTAssertEqual(island.frame.midX, window.frame.midX, accuracy: 2)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Floating island"
        shot.lifetime = .keepAlways
        add(shot)

        drag(island, to: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)))
        XCTAssertTrue(close.waitForNonExistence(timeout: 5),
                      "Dragged back up, the island docks in the toolbar")
        XCTAssertLessThan(island.frame.maxY, window.frame.height * 0.15)

        drag(island, to: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(island.waitForNonExistence(timeout: 5), "× turns Speaker Mode off")
    }

    func testControlsOpenAwayFromTheScreenEdge() {
        let app = launch()
        let island = turnOnSpeakerMode(in: app)
        let window = app.windows.firstMatch
        let length = app.otherElements["speaker-length"]

        drag(island, to: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.14)))
        XCTAssertTrue(app.buttons["speaker-close"].waitForExistence(timeout: 5))
        island.tap()
        XCTAssertTrue(length.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(length.frame.minY, island.frame.maxY,
                             "High up, the controls open below the island")
        let fullWidth = length.frame.width
        island.tap()
        XCTAssertTrue(length.waitForNonExistence(timeout: 5))

        drag(island, to: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(app.buttons["speaker-close"].waitForExistence(timeout: 5))
        XCTAssertGreaterThan(island.frame.maxY, window.frame.height * 0.85,
                             "The island should land near the bottom edge")
        island.tap()
        XCTAssertTrue(length.waitForExistence(timeout: 5))
        XCTAssertLessThan(length.frame.maxY, island.frame.minY,
                          "Low down, the controls open above the island")
        XCTAssertEqual(length.frame.width, fullWidth, accuracy: 1,
                       "The controls keep their size near the bottom edge")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Controls above the island"
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func drag(_ island: XCUIElement, to target: XCUICoordinate) {
        island.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: target, withVelocity: .slow,
                   thenHoldForDuration: 0.1)
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_NOTEBOOK_TEST_FIXTURE"] = "long-note"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchEnvironment["MEH_SYNC_CLOUDKIT"] = "0"
        app.launchArguments += [
            "-editor.mode", "livePreview",
            "-labs.speakerMode", "YES",
            "-speaker.lengthMinutes", "15",
        ]
        app.launch()
        return app
    }

    private func turnOnSpeakerMode(in app: XCUIApplication) -> XCUIElement {
        let note = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "notebook-", "Island journal"
        )).firstMatch
        if !app.textViews["markdown-editor"].waitForExistence(timeout: 5) || note.isHittable {
            if !note.exists { app.revealNotebookSidebar(timeout: 30) }
            XCTAssertTrue(note.waitForExistence(timeout: 15))
            note.tap()
        }
        let actions = app.buttons["notebook-note-actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 15))
        actions.tap()
        let item = app.noteMenuAction("notebook-speaker-mode", label: "Speaker Mode")
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        let island = app.buttons["speaker-island"]
        XCTAssertTrue(island.waitForExistence(timeout: 5))
        return island
    }

    /// Drags the pill from its middle to one end: 0 is the stopwatch end.
    private func drag(_ slider: XCUIElement, to end: CGFloat) {
        let from = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = slider.coordinate(withNormalizedOffset: CGVector(dx: end == 0 ? -0.2 : 1.2,
                                                                  dy: 0.5))
        from.press(forDuration: 0.05, thenDragTo: to)
    }
}
#endif
