import XCTest

final class ReadmeScreenshotUITests: XCTestCase {
    /// Attaches the README and App Store screenshots to the test result.
    /// `Tools/AppStore/capture.sh` runs it on an iPhone and an
    /// iPad simulator and on the Mac; see docs/screenshots.md.
    func testReadmeScreens() throws {
        let app = try launch()
        func recent(_ title: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "notebook-recent-", title
            )).firstMatch
        }
        let lisbon = recent("Lisbon in May")
        let review = recent("Weekly review 2026-10-24")

#if os(iOS)
        let device = app.frame.width >= 600 ? "ipad" : "iphone"
        XCTAssertTrue(lisbon.waitForExistence(timeout: 15))
        let editor = app.textViews["markdown-editor"]
        if device == "iphone" {
            shot("iphone-library") { XCUIScreen.main.screenshot() }
        }
        // The same note on every device, for the sync screenshots. The iPad
        // shows the library next to it.
        review.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        shot(device == "ipad" ? "ipad-library" : "iphone-review") {
            XCUIScreen.main.screenshot()
        }
        app.revealNotebookSidebar()
        lisbon.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        if device == "iphone" {
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
        XCTAssertTrue(lisbon.waitForExistence(timeout: 30))
        let window = app.windows.firstMatch
        review.click()
        XCTAssertTrue(app.textViews["markdown-editor"].waitForExistence(timeout: 15))
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

    /// The snippet menu over a workout log, one snippet per workout.
    func testSnippetScreens() throws {
        let app = try launch()
        openNote("Training log", inFolder: "Areas", in: app)
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
#if os(iOS)
        let device = app.frame.width >= 600 ? "ipad" : "iphone"
        // Below the text puts the cursor on the empty last line.
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)).tap()
        let menu = app.buttons["editor-snippet-menu"]
        let toolbar = app.collectionViews["editor-keyboard-toolbar"]
        XCTAssertTrue(toolbar.waitForExistence(timeout: 5))
        for _ in 0 ..< 5 where !menu.isHittable { toolbar.swipeLeft() }
        menu.tap()
        XCTAssertTrue(app.buttons["Pull"].firstMatch.waitForExistence(timeout: 5))
        shot("\(device)-snippets") { XCUIScreen.main.screenshot() }
#else
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)).click()
        app.buttons["editor-formatting"].click()
        let menu = app.descendants(matching: .any)["editor-snippet-menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.click()
        XCTAssertTrue(app.menuItems["Pull"].firstMatch.waitForExistence(timeout: 5))
        // Menus are separate windows, so crop the whole screen to the window.
        pause(1.5)
        let frame = app.windows.firstMatch.frame
        let screen = XCUIScreen.main.screenshot().image
        var bounds = CGRect(origin: .zero, size: screen.size)
        let image = try XCTUnwrap(screen.cgImage(
            forProposedRect: &bounds, context: nil, hints: nil))
        // XCUIScreen.main is the primary display, the one with the menu bar.
        let primary = try XCTUnwrap(NSScreen.screens.first)
        let scale = CGFloat(image.width) / primary.frame.width
        let crop = try XCTUnwrap(image.cropping(to: CGRect(
            x: frame.minX * scale, y: frame.minY * scale,
            width: frame.width * scale, height: frame.height * scale)))
        let attachment = XCTAttachment(image: NSImage(cgImage: crop, size: frame.size))
        attachment.name = "mac-snippets"
        attachment.lifetime = .keepAlways
        add(attachment)
#endif
    }

    /// Launches the sample notebook. On the Mac, the window gets the App
    /// Store size: 1440 × 900 points is 2880 × 1800 pixels on Retina.
    private func launch() throws -> XCUIApplication {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MEH_README_SCREENS"] == "1",
            "Set MEH_README_SCREENS=1 to capture screenshots"
        )
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] =
            "readme-ui-\(UUID().uuidString)"
        app.launchEnvironment["MEH_NOTEBOOK_TEST_FIXTURE"] = "readme"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        // Sync with an in-memory stand-in, so the toolbar shows a synced notebook.
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_SYNC"] = "1"
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
#if os(macOS)
        app.activate()
        // The sidebar remembers being hidden in an earlier run.
        let showSidebar = app.buttons["Show Sidebar"]
        if showSidebar.waitForExistence(timeout: 5) { showSidebar.click() }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 30))
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
        // A synced notebook settles shortly after launch.
        pause(2)
#else
        app.revealNotebookSidebar(timeout: 30)
#endif
        return app
    }

    private func shot(_ name: String, of screenshot: () -> XCUIScreenshot) {
        pause(1.5)
        let attachment = XCTAttachment(screenshot: screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Opens a note from a top-level folder in Files.
    private func openNote(_ title: String, inFolder folder: String, in app: XCUIApplication) {
        // The Mac exposes the title as the value, iOS as the label.
        func row(_ title: String) -> XCUIElement {
            app.staticTexts.matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND (label == %@ OR value == %@)",
                "notebook-sidebar-title-", title, title
            )).firstMatch
        }
        let parent = row(folder)
        XCTAssertTrue(parent.waitForExistence(timeout: 10))
        let id = parent.identifier
            .replacingOccurrences(of: "notebook-sidebar-title-", with: "")
        activate(app.descendants(matching: .any)["notebook-disclosure-" + id])
        let note = row(title)
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        activate(note)
    }

    private func activate(_ element: XCUIElement) {
#if os(macOS)
        element.click()
#else
        element.tap()
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
