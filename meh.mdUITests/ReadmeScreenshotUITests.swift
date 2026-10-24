import XCTest

final class ReadmeScreenshotUITests: XCTestCase {
    /// Attaches the README screenshots to the test result. Run with
    /// `TEST_RUNNER_MEH_README_SCREENS=1`, once on an iPhone simulator and
    /// once on the Mac, then export the attachments from the result bundle.
    func testReadmeScreens() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MEH_README_SCREENS"] == "1",
            "Set MEH_README_SCREENS=1 to capture screenshots"
        )
        func shot(_ name: String, of screenshot: () -> XCUIScreenshot) {
            pause(1.5)
            let attachment = XCTAttachment(screenshot: screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] =
            "readme-ui-\(UUID().uuidString)"
        app.launchEnvironment["MEH_NOTEBOOK_TEST_FIXTURE"] = "readme"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += [
            "-editor.mode", "livePreview",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
#if os(macOS)
        // A restored session can come back without any notebook window.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
#endif
        app.launch()
        let lisbon = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "notebook-recent-", "Lisbon in May"
        )).firstMatch

#if os(iOS)
        try XCTSkipIf(app.frame.width >= 600, "Made for iPhone")
        app.revealNotebookSidebar(timeout: 30)
        XCTAssertTrue(lisbon.waitForExistence(timeout: 15))
        shot("library") { XCUIScreen.main.screenshot() }

        lisbon.tap()
        XCTAssertTrue(app.textViews["markdown-editor"].waitForExistence(timeout: 15))
        shot("note") { XCUIScreen.main.screenshot() }
#else
        app.activate()
        XCTAssertTrue(lisbon.waitForExistence(timeout: 30))
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -3, dy: -3))
            .click(forDuration: 0.2, thenDragTo: window
                .coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: 1180, dy: 840)))
        lisbon.click()
        XCTAssertTrue(app.textViews["markdown-editor"].waitForExistence(timeout: 15))

        app.descendants(matching: .any)["notebook-note-actions"].firstMatch.click()
        let history = app.descendants(matching: .any)
            .matching(identifier: "notebook-version-history").firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        history.click()
        let previous = app.buttons["note-history-previous"]
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true"),
            object: previous
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        previous.click()
        shot("mac-history") { app.windows.firstMatch.screenshot() }
#endif
    }

    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
