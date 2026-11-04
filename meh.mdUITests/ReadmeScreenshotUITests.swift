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

#if os(iOS)
    /// The widgets on the Home Screen: Recents, and notes picked on their own.
    func testWidgetScreens() throws {
        let app = try launch()
        let device = app.frame.width >= 600 ? "ipad" : "iphone"
        // The app writes the widgets' copy of the notebook shortly after launch.
        pause(4)
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 10))

        // Gallery sizes count from 1, the small widget. The widgets fill the
        // top of the page and push the apps further down. In reading order,
        // each shows one note, or Recents for nil.
        let (sizes, notes): ([Int], [String?]) = device == "ipad"
            ? ([3, 3, 4], [nil, "Weekly review 2026-10-24", "Training log"])
            : ([3, 2], ["Packing list", nil])
        for size in sizes { addWidget(size: size, on: springboard) }

        let widgets = springboard.icons.matching(NSPredicate(
            format: "identifier == %@ AND value BEGINSWITH %@", "meh.md", "Widget"
        )).allElementsBoundByIndex.map { $0.frame }
            .sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
        XCTAssertEqual(widgets.count, sizes.count)
        for (frame, note) in zip(widgets, notes) {
            if let note { pick(note, forWidgetAt: frame, on: springboard) }
        }

        let done = springboard.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))
        // The app adds a picked note's text the next time it runs.
        pause(2)
        app.activate()
        pause(4)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 10))
        shot("\(device)-widgets") { XCUIScreen.main.screenshot() }
    }

    /// Switches the widget at `frame` to show one note, while editing the
    /// Home Screen.
    private func pick(_ note: String, forWidgetAt frame: CGRect, on springboard: XCUIApplication) {
        springboard.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
        let show = springboard.buttons["Recents"]
        XCTAssertTrue(show.waitForExistence(timeout: 10))
        show.tap()
        let oneNote = springboard.buttons["One Note"].firstMatch
        XCTAssertTrue(oneNote.waitForExistence(timeout: 5))
        oneNote.tap()
        let choose = springboard.buttons["Choose"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        choose.tap()
        // The picker comes before the Home Screen, whose widgets show titles too.
        let row = springboard.staticTexts[note].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let picked = springboard.buttons[note]
        XCTAssertTrue(picked.waitForExistence(timeout: 5))
        // A tap below the settings closes them.
        point(0.5, 0.9, on: springboard).tap()
        XCTAssertTrue(picked.waitForNonExistence(timeout: 5))
        pause(1)
    }

    /// Adds the Notes widget in the gallery's `size`-th size, 1 being small.
    private func addWidget(size: Int, on springboard: XCUIApplication) {
        let edit = springboard.buttons["Edit"]
        let menuItem = springboard.buttons["Add Widget"]
        let meh = springboard.cells["meh.md"]
        // Right after an install the gallery can miss the app for a while.
        for _ in 0 ..< 12 {
            for _ in 0 ..< 3 where !menuItem.exists {
                if !edit.waitForExistence(timeout: 2) {
                    // The dock's empty end starts editing, even on a full page.
                    point(0.88, 0.92, on: springboard).press(forDuration: 1.5)
                    _ = edit.waitForExistence(timeout: 3)
                }
                if edit.exists { edit.tap() }
                _ = menuItem.waitForExistence(timeout: 3)
            }
            menuItem.tap()
            let search = springboard.searchFields["Search Widgets"]
            XCTAssertTrue(search.waitForExistence(timeout: 10))
            search.tap()
            search.typeText("meh")
            if meh.waitForExistence(timeout: 3) { break }
            springboard.buttons["Close"].tap()
            pause(5)
        }
        XCTAssertTrue(meh.exists, "Expected meh.md in the widget gallery")
        pause(1)
        meh.tap()
        // The gallery's button has an icon in front of its label.
        let add = springboard.buttons
            .matching(NSPredicate(format: "label ENDSWITH %@", "Add Widget")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        let preview = springboard.buttons["meh.md, Notes"].firstMatch
        for _ in 1 ..< size {
            preview.swipeLeft()
            pause(1)
        }
        add.tap()
        pause(2)
    }

    private func point(_ x: CGFloat, _ y: CGFloat, on app: XCUIApplication) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }
#endif

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
