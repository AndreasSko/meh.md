import XCTest

/// Drives History through its main moments for the PR recordings. It
/// asserts little; the regular History tests cover behavior. Run it with
/// `TEST_RUNNER_MEH_HISTORY_TOUR=1` while recording the screen.
final class NoteHistoryTourUITests: XCTestCase {
    private var app: XCUIApplication!

    func testHistoryTour() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MEH_HISTORY_TOUR"] == "1",
            "Set MEH_HISTORY_TOUR=1 to drive the History tour"
        )
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = "history-tour-\(UUID().uuidString)"
        app.launchEnvironment["MEH_NOTEBOOK_TEST_FIXTURE"] = "history-tour"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchEnvironment["MEH_SYNC_CLOUDKIT"] = "0"
        app.launchEnvironment["MEH_SHOW_TIPS"] = "1"
        app.launchArguments += [
            "-editor.mode", "livePreview",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
#if os(macOS)
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
#endif
        app.launch()
#if os(macOS)
        app.activate()
        placeWindow()
#endif
        let lisbon = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (label == %@ OR value == %@)",
            "notebook-sidebar-title-", "Lisbon in May", "Lisbon in May"
        )).firstMatch
        XCTAssertTrue(lisbon.waitForExistence(timeout: 30))
        // The recorder starts once the window is in place.
        print("HISTORY_TOUR_READY")
        pause(Double(ProcessInfo.processInfo.environment["MEH_HISTORY_TOUR_DELAY"] ?? "0") ?? 0)
        activate(lisbon)
        XCTAssertTrue(app.textViews["markdown-editor"].waitForExistence(timeout: 15))
        pause(1.5)
        activate(app.descendants(matching: .any)["notebook-note-actions"].firstMatch)
        let history = app.descendants(matching: .any)
            .matching(identifier: "notebook-version-history").firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        pause(0.6)
        activate(history)
        let timeline = app.descendants(matching: .any)
            .matching(identifier: "note-history-timeline").firstMatch
        XCTAssertTrue(timeline.waitForExistence(timeout: 10))
        app.waitForHistoryIndex(timeout: 30)
        pause(2.5)
#if os(macOS)
        macTour(timeline)
#else
        phoneTour(timeline)
#endif
        activate(app.buttons["note-history-done"])
        pause(2)
        // Recorders stop here, before the app quits and shows other windows.
        print("HISTORY_TOUR_END")
        pause(1)
    }

#if os(iOS)
    private func phoneTour(_ timeline: XCUIElement) {
        // Dragging right brings older versions to the handle.
        drag(timeline, by: 40, duration: 2.5)
        pause(2)
        drag(timeline, by: 30, duration: 2)
        pause(2)
        step(timeline, until: "8:50")
        pause(2)
        // The removal ring sits in the left margin above "Reserve dinner".
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 9, dy: 438)).tap()
        pause(3)
        app.staticTexts["note-history-title"].tap()
        pause(1)
        // Sliding the finger up while dragging shows every step.
        let start = center(of: timeline)
        start.press(
            forDuration: 0.3,
            thenDragTo: start.withOffset(CGVector(dx: -70, dy: -120)),
            withVelocity: 28,
            thenHoldForDuration: 2
        )
        pause(2.5)
        app.tapHistoryTimeline(older: false)
        pause(1.5)
        // The typed quote ends below the timeline, so the jumper appears.
        step(timeline, until: "6:42")
        pause(2)
        let next = app.buttons["Next change"]
        if next.waitForExistence(timeout: 3) {
            next.tap()
            pause(2.5)
        }
    }

    private func drag(_ timeline: XCUIElement, by dx: CGFloat, duration: TimeInterval) {
        let start = center(of: timeline)
        start.press(
            forDuration: 0.15,
            thenDragTo: start.withOffset(CGVector(dx: dx, dy: 0)),
            withVelocity: XCUIGestureVelocity(abs(dx) / duration),
            thenHoldForDuration: 0.3
        )
    }

    /// Steps back one tick at a time, slowly, until the selection reads `time`.
    /// Times use a narrow space before AM or PM, so match only the digits.
    private func step(_ timeline: XCUIElement, until time: String) {
        var previous = ""
        for _ in 0 ..< 30 {
            let value = timeline.value as? String ?? ""
            if value.contains(time) { return }
            // Days sit further apart than the ticks inside one day.
            drag(timeline, by: value == previous ? 40 : 10, duration: 0.5)
            previous = value
            pause(0.5)
        }
    }

    private func center(of timeline: XCUIElement) -> XCUICoordinate {
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
    }
#else
    private func macTour(_ timeline: XCUIElement) {
        // Hovering explains a tick before choosing it.
        for dx in [0.4, 0.36, 0.3] {
            timeline.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.3)).hover()
            pause(1.2)
        }
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).click()
        pause(2.5)
        app.tapHistoryTimeline(older: false)
        pause(1.5)
        // Nine sessions before the current text is Thursday's first.
        for _ in 0 ..< 9 {
            timeline.typeKey(.leftArrow, modifierFlags: [])
            pause(0.7)
        }
        pause(1.5)
        let preview = app.textViews["note-history-preview"]
        if let ring = ProcessInfo.processInfo.environment["MEH_HISTORY_TOUR_RING"]?
            .split(separator: ",").compactMap({ Double($0) }), ring.count == 2 {
            preview.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: ring[0], dy: ring[1])).click()
            pause(3)
            app.typeKey(.escape, modifierFlags: [])
            pause(1)
        }
        // Clicking the selected tick keeps the version and takes the keys back.
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).click()
        pause(0.5)
        // ⌘+ zooms into every step; the arrows then step one by one.
        app.typeKey("=", modifierFlags: .command)
        pause(1.5)
        for _ in 0 ..< 12 {
            timeline.typeKey(.rightArrow, modifierFlags: [])
            pause(0.35)
        }
        pause(1.5)
        app.typeKey("-", modifierFlags: .command)
        pause(2)
        for _ in 0 ..< 4 {
            timeline.typeKey(.rightArrow, modifierFlags: [])
            pause(0.8)
        }
        pause(2)
    }

    /// A fixed window lets the recorder capture only this app.
    private func placeWindow() {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 30))
        let frame = window.frame
        let title = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.width / 2, dy: 12))
        title.click(forDuration: 0.2, thenDragTo: title.withOffset(
            CGVector(dx: 40 - frame.minX, dy: 60 - frame.minY)
        ))
        let moved = window.frame
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: moved.width - 3, dy: moved.height - 3))
            .click(forDuration: 0.2, thenDragTo: window
                .coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: 1200, dy: 800)))
        print("HISTORY_TOUR_WINDOW \(window.frame)")
    }
#endif

    private func activate(_ element: XCUIElement) {
#if os(macOS)
        element.click()
#else
        element.tap()
#endif
    }

    private func pause(_ seconds: TimeInterval) {
        guard seconds > 0 else { return }
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
