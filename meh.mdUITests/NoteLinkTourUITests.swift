import XCTest

/// Follows links through a trip note and back for the PR recordings. Run it
/// with `TEST_RUNNER_MEH_LINK_TOUR=1` while recording the screen. With
/// `TEST_RUNNER_MEH_LINK_TOUR_FOLD=1` it waits twice for iPhone Duo to be
/// folded or unfolded, so the note must survive both changes.
final class NoteLinkTourUITests: XCTestCase {
    private var app: XCUIApplication!

    func testLinkTour() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["MEH_LINK_TOUR"] == "1",
            "Set MEH_LINK_TOUR=1 to drive the link tour"
        )
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = "link-tour-\(UUID().uuidString)"
        app.launchEnvironment["MEH_NOTEBOOK_TEST_FIXTURE"] = "link-tour"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchEnvironment["MEH_SYNC_CLOUDKIT"] = "0"
        app.launchArguments += [
            "-editor.mode", "livePreview",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
        app.revealNotebookSidebar(timeout: 30)
        let lisbon = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (label == %@ OR value == %@)",
            "notebook-sidebar-title-", "Lisbon in May", "Lisbon in May"
        )).firstMatch
        XCTAssertTrue(lisbon.waitForExistence(timeout: 30))
        print("LINK_TOUR_READY")
        pause(Double(environment["MEH_LINK_TOUR_DELAY"] ?? "0") ?? 0)

        lisbon.tap()
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        assertTitle("Lisbon in May")
        pause(1.5)
        tapLink()
        assertTitle("Packing list")
        pause(1.5)
        tapLink()
        assertTitle("Camera gear")
        pause(1.5)

        if environment["MEH_LINK_TOUR_FOLD"] == "1" {
            waitForWidthChange("LINK_TOUR_FOLD")
            assertTitle("Camera gear")
            pause(1.5)
        }
        goBack()
        assertTitle("Packing list")
        pause(1.5)
        if environment["MEH_LINK_TOUR_FOLD"] == "1" {
            waitForWidthChange("LINK_TOUR_UNFOLD")
            assertTitle("Packing list")
            pause(1.5)
        }
        // iPadOS offers the edge swipe only where the note reaches the edge.
        if app.textViews["markdown-editor"].frame.minX > 1 {
            goBack()
        } else {
            swipeBack()
        }
        assertTitle("Lisbon in May")
        pause(2)
        // Leaving the first note goes back to Files on a single column.
        if !app.buttons["notebook-tree-toggle"].isHittable {
            goBack()
            XCTAssertTrue(app.buttons["notebook-tree-toggle"].waitForExistence(timeout: 10))
        }
        pause(2)
        print("LINK_TOUR_END")
        pause(1)
    }

    /// The fixture starts each note with its link, right below the title.
    private func tapLink() {
        app.buttons["note-title"].coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 1))
            .withOffset(CGVector(dx: 0, dy: 26)).tap()
    }

    private func goBack() {
        // iPhone Duo lays the bar buttons out vertically, outside a navigation bar.
        let back = app.buttons.matching(identifier: "BackButton").firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        print("LINK_TOUR_BACK \(back.label)")
        back.tap()
    }

    private func swipeBack() {
        let editor = app.textViews["markdown-editor"]
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 2, dy: 0))
            .press(forDuration: 0.05,
                   thenDragTo: editor.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    /// Prints a marker for the recorder, then waits for the app to resize.
    private func waitForWidthChange(_ marker: String) {
        let width = app.frame.width
        print(marker)
        let resized = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in abs(self.app.frame.width - width) > 1 },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [resized], timeout: 300), .completed)
        pause(1)
    }

    private func assertTitle(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let expected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", title),
            object: app.buttons["note-title"]
        )
        if XCTWaiter.wait(for: [expected], timeout: 10) != .completed {
            print(app.debugDescription)
            XCTFail("Expected the note titled \(title)", file: file, line: line)
        }
    }

    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
