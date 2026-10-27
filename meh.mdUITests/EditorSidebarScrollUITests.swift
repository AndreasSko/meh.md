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
            sleep(1)
        }
        toggleSidebar()
        toggleSidebar()

        let top = editor.screenshot().pngRepresentation
        for _ in 0..<3 { editor.swipeUp() }
        sleep(2)
        let scrolled = editor.screenshot().pngRepresentation
        XCTAssertNotEqual(top, scrolled, "The note did not scroll")
        sleep(2)
        let settled = editor.screenshot().pngRepresentation
        XCTAssertEqual(scrolled, settled, "The note jumped after scrolling")
    }
}
#endif
