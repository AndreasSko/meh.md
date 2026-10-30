import XCTest

#if os(iOS)
final class EditorSidebarScrollUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        XCUIDevice.shared.orientation = .portrait
    }

    func testNoteScrollsAfterShowingAndHidingTheSidebar() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_NOTEBOOK_TEST_FIXTURE"] = "long-note"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchEnvironment["MEH_SYNC_CLOUDKIT"] = "0"
        app.launchArguments += ["-editor.mode", "livePreview"]
        app.launch()

        let editor = app.textViews["markdown-editor"]
        if !editor.waitForExistence(timeout: 5) {
            app.revealNotebookSidebar(timeout: 30)
            let note = app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "notebook-", "Island journal"
            )).firstMatch
            XCTAssertTrue(note.waitForExistence(timeout: 15))
            note.tap()
        }
        XCTAssertTrue(editor.waitForExistence(timeout: 15))

        func toggleSidebar() {
            let toggle = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Sidebar")
            ).firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            toggle.tap()
            _ = settledFrame(of: editor)
        }
        toggleSidebar()
        toggleSidebar()

        let title = app.buttons["note-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let top = title.frame.minY
        for _ in 0..<3 { editor.swipeUp() }
        let scrolled = settledFrame(of: title).minY
        XCTAssertLessThan(scrolled, top - 100, "The note did not scroll")
        let jumped = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in abs(title.frame.minY - scrolled) > 2 },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [jumped], timeout: 2), .timedOut,
                       "The note jumped after scrolling")
    }

    private func settledFrame(of element: XCUIElement) -> CGRect {
        var previous = element.frame
        let deadline = Date().addingTimeInterval(10)
        repeat {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            let current = element.frame
            if current == previous { return current }
            previous = current
        } while Date() < deadline
        XCTFail("\(element) kept moving")
        return previous
    }
}
#endif
