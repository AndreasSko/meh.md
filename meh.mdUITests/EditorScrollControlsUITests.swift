import XCTest

#if os(iOS)
final class EditorScrollControlsUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testScrollingDownHidesNoteControlsUntilScrollingUp() {
        let app = launch()
        let editor = openLongNote(in: app)
        let actions = app.buttons["notebook-note-actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        XCTAssertTrue(wait(for: actions, hittable: true))

        editor.swipeUp()
        XCTAssertTrue(wait(for: actions, hittable: false),
                      "Scrolling down should hide the note's controls")

        editor.swipeDown()
        XCTAssertTrue(wait(for: actions, hittable: true),
                      "Scrolling up should bring the note's controls back")
    }

    func testControlsStayWhenTheSettingIsOff() {
        let app = launch()
        app.openNotebookSettings()
        let toggle = app.switches["notebook-appearance-hide-controls"]
        for _ in 0..<5 where !toggle.isHittable { app.swipeUp() }
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "0")
        app.navigationBars["Settings"].buttons["Done"].tap()

        let editor = openLongNote(in: app)
        let actions = app.buttons["notebook-note-actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        XCTAssertTrue(wait(for: actions, hittable: true))
        let title = app.buttons["note-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let top = title.frame.minY
        editor.swipeUp()
        XCTAssertLessThan(title.frame.minY, top - 100, "The note did not scroll")
        XCTAssertFalse(wait(for: actions, hittable: false, timeout: 3),
                       "The note's controls should stay while scrolling")
    }

    func testHistoryKeepsItsControlsWhileScrolling() {
        let app = launch()
        _ = openLongNote(in: app)
        app.buttons["notebook-note-actions"].tap()
        let history = app.noteMenuAction("notebook-version-history", label: "History")
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        history.tap()
        let preview = app.textViews["note-history-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        let done = app.buttons["note-history-done"]
        XCTAssertTrue(wait(for: done, hittable: true))
        preview.swipeUp()
        XCTAssertFalse(wait(for: done, hittable: false, timeout: 3),
                       "History's Done button should stay while scrolling")
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_NOTEBOOK_TEST_FIXTURE"] = "long-note"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchEnvironment["MEH_SYNC_CLOUDKIT"] = "0"
        app.launchArguments += ["-editor.mode", "livePreview"]
        app.launch()
        return app
    }

    private func openLongNote(in app: XCUIApplication) -> XCUIElement {
        let note = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "notebook-", "Island journal"
        )).firstMatch
        let editor = app.textViews["markdown-editor"]
        if !editor.waitForExistence(timeout: 5) || note.isHittable {
            if !note.exists { app.revealNotebookSidebar(timeout: 30) }
            XCTAssertTrue(note.waitForExistence(timeout: 15))
            note.tap()
        }
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        return editor
    }

    private func wait(
        for element: XCUIElement, hittable: Bool, timeout: TimeInterval = 5
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == %@", NSNumber(value: hittable)),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
#endif
