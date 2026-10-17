import XCTest

final class FlairUITests: XCTestCase {
    func testSearchWithoutResultsNamesTheQuery() throws {
        continueAfterFailure = false
        let app = makeApp(mode: "source")
        app.launch()

        search(for: "zebra", in: app)
        XCTAssertTrue(
            app.staticTexts["No notes mention “zebra”"]
                .waitForExistence(timeout: 10)
        )
    }

    func testSettingsEndWithTheVersion() throws {
        continueAfterFailure = false
        let app = makeApp(mode: "source")
        app.launch()

        app.openNotebookSettings()
        let version = app.staticTexts["notebook-settings-version"]
        for _ in 0..<6 where !version.exists { scrollDown(in: app) }
        XCTAssertTrue(version.waitForExistence(timeout: 5))
        XCTAssertTrue(version.label.hasPrefix("meh.md "), version.label)
    }

    /// Slow tour for recording a demo video. Run with
    /// `TEST_RUNNER_MEH_SHOWCASE=1`.
    func testShowcaseWalkthrough() throws {
#if os(iOS)
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MEH_SHOWCASE"] == "1",
            "Set MEH_SHOWCASE=1 to record the walkthrough"
        )
        continueAfterFailure = false
        let app = makeApp(mode: "livePreview")
        app.launch()
        try XCTSkipIf(app.frame.width >= 600, "The tour is made for iPhone")

        app.revealNotebookSidebar(timeout: 30)
        pause(2.5)

        app.openTrash()
        pause(2)
        let trashEmpty = app.staticTexts["Trash is empty"]
        XCTAssertTrue(trashEmpty.waitForExistence(timeout: 5))
        for _ in 0..<4 {
            tapFace(near: trashEmpty, dy: -38)
            pause(1.2)
        }
        pause(3)
        app.closeTrash()
        pause(1.5)

        app.openSyncDetails()
        pause(2.5)
        dismissSyncDetails(in: app)
        app.revealNotebookSidebar()
        pause(1.5)

        openWeekend(in: app)
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        pause(3.5)

        // The open task is the third checkbox, laid out on an iPhone 18 Pro
        // (402 x 874 pt) at about x 36, y 341; scale for other heights.
        let scale = app.frame.height / 874
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 36, dy: 341 * scale)).tap()
        pause(2.5)

        let actions = app.buttons["notebook-note-actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        actions.tap()
        let trash = app.buttons["Move to Trash"]
        XCTAssertTrue(trash.waitForExistence(timeout: 5))
        trash.tap()
        pause(3)

        app.revealNotebookSidebar()
        pause(1.5)
        search(for: "zebra", in: app)
        XCTAssertTrue(
            app.staticTexts["No notes mention “zebra”"]
                .waitForExistence(timeout: 10)
        )
        pause(3)
        cancelSearch(in: app)
        pause(2)

        app.openNotebookSettings()
        let version = app.staticTexts["notebook-settings-version"]
        for _ in 0..<6 where !version.exists { scrollDown(in: app) }
        XCTAssertTrue(version.waitForExistence(timeout: 5))
        pause(1.5)
        for _ in 0..<5 {
            tapFace(near: version, dy: 11)
            pause(1.2)
        }
        pause(3)
#else
        throw XCTSkip("The tour is made for iPhone")
#endif
    }

    /// Saves PNGs of the main flair screens into `MEH_SHOTS_DIR`. Run with
    /// `TEST_RUNNER_MEH_SHOWCASE_SCREENS=1`, `TEST_RUNNER_MEH_SHOTS_DIR`
    /// and `TEST_RUNNER_MEH_SHOTS_SUFFIX`.
    func testShowcaseScreens() throws {
#if os(iOS)
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            env["MEH_SHOWCASE_SCREENS"] == "1",
            "Set MEH_SHOWCASE_SCREENS=1 to capture screenshots"
        )
        let dir = try XCTUnwrap(env["MEH_SHOTS_DIR"])
        let suffix = env["MEH_SHOTS_SUFFIX"] ?? "light"
        func shot(_ name: String) {
            pause(1.5)
            let png = XCUIScreen.main.screenshot().pngRepresentation
            try? png.write(to: URL(fileURLWithPath: dir)
                .appendingPathComponent("\(name)-\(suffix).png"))
        }
        continueAfterFailure = false
        let app = makeApp(mode: "livePreview")
        app.launch()
        try XCTSkipIf(app.frame.width >= 600, "Made for iPhone")

        app.revealNotebookSidebar(timeout: 30)
        shot("library")
        app.openTrash()
        shot("trash")
        app.closeTrash()
        app.openSyncDetails()
        shot("sync")
        dismissSyncDetails(in: app)
        app.revealNotebookSidebar()
        search(for: "zebra", in: app)
        XCTAssertTrue(
            app.staticTexts["No notes mention “zebra”"]
                .waitForExistence(timeout: 10)
        )
        shot("search")
        cancelSearch(in: app)
        openWeekend(in: app)
        XCTAssertTrue(app.textViews["markdown-editor"].waitForExistence(timeout: 15))
        shot("weekend")
#else
        throw XCTSkip("Made for iPhone")
#endif
    }

    private func makeApp(mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] =
            "flair-ui-\(UUID().uuidString)"
        app.launchEnvironment["MEH_NOTEBOOK_TEST_FIXTURE"] = "flair"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", mode]
        return app
    }

    /// Faces are hidden from accessibility, so tap relative to the top of
    /// the element next to them.
    private func tapFace(near element: XCUIElement, dy: CGFloat) {
        let face = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: dy))
#if os(macOS)
        face.click()
#else
        face.tap()
#endif
    }

    private func scrollDown(in app: XCUIApplication) {
#if os(macOS)
        app.windows.firstMatch.scroll(byDeltaX: 0, deltaY: -400)
#else
        app.swipeUp()
#endif
    }

    /// Like `closeSyncDetails`, but stays on the library when no note is open.
    private func dismissSyncDetails(in app: XCUIApplication) {
        let status = app.descendants(matching: .any)
            .matching(identifier: "note-sync-status").firstMatch
        guard status.exists else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).tap()
        XCTAssertTrue(status.waitForNonExistence(timeout: 5))
    }

    private func cancelSearch(in app: XCUIApplication) {
        let cancel = app.buttons.matching(NSPredicate(
            format: "label IN %@", ["Cancel", "Abbrechen"]
        )).firstMatch
        if cancel.waitForExistence(timeout: 2) {
            cancel.tap()
        } else {
            // The search bar's round close button sits right of the field.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.585))
                .tap()
        }
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    }

    private func search(for query: String, in app: XCUIApplication) {
#if os(iOS)
        app.revealNotebookSidebar()
#endif
        let field = app.searchFields.firstMatch
        if !field.waitForExistence(timeout: 5) {
            let button = app.buttons["Search"]
            if button.waitForExistence(timeout: 5) { activate(button) }
        }
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        activate(field)
        field.typeText(query)
    }

    private func openWeekend(in app: XCUIApplication) {
        let folder = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@",
            "notebook-sidebar-title-", "Home"
        )).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 15))
        let weekend = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@",
            "notebook-sidebar-title-", "Weekend"
        )).firstMatch
        if !weekend.exists {
            let disclosure = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@", "notebook-disclosure-"
            )).firstMatch
            if disclosure.exists { disclosure.tap() } else { folder.tap() }
            pause(1.5)
        }
        XCTAssertTrue(weekend.waitForExistence(timeout: 10))
        weekend.tap()
    }

    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func activate(_ element: XCUIElement) {
#if os(macOS)
        element.click()
#else
        element.tap()
#endif
    }
}
