import XCTest

#if os(macOS)
final class MacSidebarClickUITests: XCTestCase {
    /// The List selects a Files row from anywhere in it, so a click near the
    /// row's edge must open the note too, not only a click on its title.
    func testClickNearFilesRowEdgeOpensTheNote() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] =
            "sidebar-click-\(UUID().uuidString)"
        app.launchEnvironment["MEH_NOTEBOOK_TEST_FIXTURE"] = "rendering"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "source"]
        app.launch()

        let editor = app.textViews["markdown-editor"]
        let journal = row(titled: "Field journal", in: app)
        let harbor = row(titled: "Harbor log", in: app)

        journal.click()
        XCTAssertTrue(waitForEditor(editor, prefix: "# Field journal"))
        editor.click()

        harbor.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.08)).click()
        XCTAssertTrue(waitForEditor(editor, prefix: "# Harbor log"),
                      "A click near the top of the row only selected it")

        journal.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.92)).click()
        XCTAssertTrue(waitForEditor(editor, prefix: "# Field journal"),
                      "A click near the bottom of the row only selected it")
    }

    private func row(titled title: String, in app: XCUIApplication) -> XCUIElement {
        let titles = app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND value == %@",
                        "notebook-sidebar-title-", title)
        )
        XCTAssertTrue(titles.firstMatch.waitForExistence(timeout: 20),
                      "Expected \(title) in Files")
        let id = titles.firstMatch.identifier
            .replacingOccurrences(of: "notebook-sidebar-title-", with: "")
        let row = app.descendants(matching: .any)["notebook-sidebar-note-" + id]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        return row
    }

    private func waitForEditor(_ editor: XCUIElement, prefix: String) -> Bool {
        let opened = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value BEGINSWITH %@", prefix),
            object: editor
        )
        return XCTWaiter.wait(for: [opened], timeout: 5) == .completed
    }
}
#endif
