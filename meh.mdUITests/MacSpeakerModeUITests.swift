import XCTest

#if os(macOS)
final class MacSpeakerModeUITests: XCTestCase {
    /// The island starts in the toolbar, which narrows the search field.
    /// Dragged over the note it gives that space back, docks again when
    /// dragged up, and its × turns Speaker Mode off.
    @MainActor
    func testIslandMovesBetweenToolbarAndNote() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_NOTEBOOK_TEST_FIXTURE"] = "long-note"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchEnvironment["MEH_SYNC_CLOUDKIT"] = "0"
        app.launchArguments += [
            "-labs.speakerMode", "YES", "-speaker.lengthMinutes", "15",
            "-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(en)",
        ]
        app.launch()
        defer { app.terminate() }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        let note = window.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (label == %@ OR value == %@)",
            "notebook-sidebar-title-", "Island journal", "Island journal"
        )).firstMatch
        let showSidebar = window.buttons["Show Sidebar"]
        if showSidebar.exists { showSidebar.click() }
        XCTAssertTrue(note.waitForExistence(timeout: 15))
        note.click()

        resize(window, to: 1100)
        let search = window.searchFields.firstMatch
        let actions = window.menuButtons["notebook-note-actions"]
        let island = window.buttons["speaker-island"]
        let close = window.buttons["speaker-close"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        let searchWidth = search.frame.width

        toggleSpeakerMode(in: app, actions: actions)
        XCTAssertTrue(island.waitForExistence(timeout: 5))
        XCTAssertLessThan(island.frame.midY, window.frame.minY + 60, "Starts in the toolbar")
        XCTAssertFalse(close.exists)
        attachScreenshot(of: window, named: "speaker-docked")

        drag(island, to: window.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5)))
        XCTAssertTrue(close.waitForExistence(timeout: 5), "Over the note the island shows a ×")
        XCTAssertGreaterThan(island.frame.midY, window.frame.minY + 200)
        XCTAssertEqual(search.frame.width, searchWidth, accuracy: 1,
                       "Out of the toolbar, the search field gets its space back")
        attachScreenshot(of: window, named: "speaker-floating")

        let startPause = window.buttons["speaker-island-start-pause"]
        startPause.click()
        XCTAssertEqual(startPause.label, "Pause Timer", "The island starts the timer itself")
        island.click()
        XCTAssertTrue(window.buttons["speaker-start-pause"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])

        drag(island, to: window.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 20)))
        XCTAssertTrue(close.waitForNonExistence(timeout: 5),
                      "Dragged back up, the island docks in the toolbar")
        XCTAssertLessThan(island.frame.midY, window.frame.minY + 60)

        drag(island, to: window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6)))
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.click()
        XCTAssertTrue(island.waitForNonExistence(timeout: 5), "× turns Speaker Mode off")
    }

    @MainActor
    private func drag(_ island: XCUIElement, to target: XCUICoordinate) {
        island.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click(forDuration: 0.1, thenDragTo: target, withVelocity: .slow,
                   thenHoldForDuration: 0.1)
    }

    @MainActor
    private func toggleSpeakerMode(in app: XCUIApplication, actions: XCUIElement) {
        actions.click()
        let speakerMode = app.menuItems.matching(NSPredicate(
            format: "identifier == %@ OR label == %@",
            "notebook-speaker-mode", "Speaker Mode"
        )).firstMatch
        XCTAssertTrue(speakerMode.waitForExistence(timeout: 5))
        speakerMode.click()
    }

    @MainActor
    private func resize(_ window: XCUIElement, to width: CGFloat, accuracy: CGFloat = 5) {
        let frame = window.frame
        if width - frame.width > accuracy && abs(frame.minX - 8) > 2 {
            let titleBar = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
                .withOffset(CGVector(dx: 0, dy: 4))
            titleBar.click(forDuration: 0.2, thenDragTo: titleBar
                .withOffset(CGVector(dx: 8 - frame.minX, dy: 0)))
        }
        for _ in 0..<3 {
            let delta = width - window.frame.width
            if abs(delta) <= accuracy { return }
            let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
                .withOffset(CGVector(dx: -3, dy: -3))
            corner.click(
                forDuration: 0.2,
                thenDragTo: corner.withOffset(CGVector(dx: delta, dy: 0)),
                withVelocity: .slow,
                thenHoldForDuration: 0.2
            )
        }
        XCTAssertEqual(window.frame.width, width, accuracy: accuracy)
    }

    @MainActor
    private func attachScreenshot(of window: XCUIElement, named name: String) {
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
