import XCTest

final class ReadmeScreenshotUITests: XCTestCase {
    /// Attaches the README and App Store screenshots to the test result.
    /// Run with `TEST_RUNNER_MEH_README_SCREENS=1` on an iPhone and an iPad
    /// simulator and on the Mac, then export the attachments from the
    /// result bundle.
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
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            // Light, like the iPhone and iPad screenshots.
            "-NSRequiresAquaSystemAppearance", "YES",
        ]
#endif
        app.launch()
        let lisbon = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "notebook-recent-", "Lisbon in May"
        )).firstMatch

#if os(iOS)
        let device = app.frame.width >= 600 ? "ipad" : "iphone"
        app.revealNotebookSidebar(timeout: 30)
        XCTAssertTrue(lisbon.waitForExistence(timeout: 15))
        let editor = app.textViews["markdown-editor"]
        if device == "iphone" {
            shot("iphone-library") { XCUIScreen.main.screenshot() }
        }
        lisbon.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        // The iPad shows the library next to the open note.
        if device == "ipad" {
            shot("ipad-library") { XCUIScreen.main.screenshot() }
        } else {
            shot("iphone-note") { XCUIScreen.main.screenshot() }
        }

        app.buttons["notebook-note-actions"].tap()
        let history = app.descendants(matching: .any)
            .matching(identifier: "notebook-version-history").firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        history.tap()
        showHistory(at: "8:50", in: app)
        shot("\(device)-history") { XCUIScreen.main.screenshot() }

        // Then the note on its own, without the library.
        if device == "ipad" {
            app.buttons["note-history-done"].tap()
            XCTAssertTrue(editor.waitForExistence(timeout: 15))
            app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Sidebar"))
                .firstMatch.tap()
            shot("ipad-note") { XCUIScreen.main.screenshot() }
        }
#else
        app.activate()
        // The sidebar remembers being hidden in an earlier run.
        let showSidebar = app.buttons["Show Sidebar"]
        if showSidebar.waitForExistence(timeout: 5) { showSidebar.click() }
        XCTAssertTrue(lisbon.waitForExistence(timeout: 30))
        // 1440 × 900 points is the App Store's 2880 × 1800 on Retina.
        let window = app.windows.firstMatch
        // Move the window to the top left first, so it has room to grow.
        let frame = window.frame
        let titleBar = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.width / 2, dy: 4))
        titleBar.click(forDuration: 0.2, thenDragTo: titleBar
            .withOffset(CGVector(dx: 8 - frame.minX, dy: 40 - frame.minY)))
        window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -3, dy: -3))
            .click(forDuration: 0.2, thenDragTo: window
                .coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: 1440 - 3, dy: 900 - 3)))
        shot("mac-library") { window.screenshot() }

        lisbon.click()
        XCTAssertTrue(app.textViews["markdown-editor"].waitForExistence(timeout: 15))
        shot("mac-note") { window.screenshot() }

        app.descendants(matching: .any)["notebook-note-actions"].firstMatch.click()
        let history = app.descendants(matching: .any)
            .matching(identifier: "notebook-version-history").firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        history.click()
        showHistory(at: "8:50", in: app)
        shot("mac-history") { window.screenshot() }
#endif
    }

    /// Steps back from the current text until History shows the version
    /// saved at `time`. Times use a narrow space before AM or PM, so match
    /// only the digits.
    private func showHistory(at time: String, in app: XCUIApplication) {
        app.waitForHistoryIndex(timeout: 30)
        let timeline = app.descendants(matching: .any)
            .matching(identifier: "note-history-timeline").firstMatch
        let status = app.staticTexts["note-history-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        // The Mac exposes the text as the value, iOS as the label.
        var shown: String { status.label + (status.value as? String ?? "") }
        for _ in 0 ..< 30 where !shown.contains(time) {
#if os(macOS)
            timeline.typeKey(.leftArrow, modifierFlags: [])
            pause(0.5)
#else
            // A tap picks the nearest tick. Moving out from the handle in
            // small steps reaches the previous tick before any other.
            let before = shown
            for offset in stride(from: 6, through: 70, by: 8) where shown == before {
                timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                    .withOffset(CGVector(dx: -offset, dy: 0)).tap()
                pause(0.5)
            }
#endif
        }
        XCTAssertTrue(shown.contains(time), "Expected History at \(time)")
    }

    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
