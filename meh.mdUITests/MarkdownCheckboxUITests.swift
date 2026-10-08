import XCTest

#if os(iOS)
final class MarkdownCheckboxUITests: XCTestCase {
    func testLivePreviewCheckboxTapEditsMarkdown() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "livePreview"]
        app.launch()

        let newNote = app.buttons["notebook-new-item"].firstMatch
        XCTAssertTrue(newNote.waitForExistence(timeout: 15))
        newNote.tap()
        let title = app.textFields["title-field"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        title.typeText("\n")

        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        let source = "- [ ] Pack a star chart\n- [ ] Mark the route"
        editor.typeText("- [ ] Pack a star chart\nMark the route")
        XCTAssertEqual(editor.value as? String, source)
        capture(app, name: "Task checkboxes in Live Preview")

        let noteTitle = app.buttons["note-title"]
        XCTAssertTrue(noteTitle.waitForExistence(timeout: 5))
        let firstCheckbox = app.coordinate(atScreenPoint: CGPoint(
            x: editor.frame.minX + 40, y: noteTitle.frame.maxY + 27
        ))
        firstCheckbox.tap()
        XCTAssertTrue(waitForSource(editor) {
            $0 == "- [x] Pack a star chart\n- [ ] Mark the route"
        }, "Checkbox tap left source as \(editor.value ?? "nil")")
        capture(app, name: "First task checked")

        let secondCheckbox = app.coordinate(atScreenPoint: CGPoint(
            x: editor.frame.minX + 40, y: noteTitle.frame.maxY + 49
        ))
        secondCheckbox.tap()
        XCTAssertTrue(waitForSource(editor) {
            $0 == "- [x] Pack a star chart\n- [x] Mark the route"
        }, "Second checkbox tap left source as \(editor.value ?? "nil")")

        editor.typeText("!")
        XCTAssertTrue(waitForSource(editor) {
            $0 == "- [x] Pack a star chart\n- [x] Mark the route!"
        }, "Checkbox tap interrupted editor focus")
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitForSource(
        _ editor: XCUIElement,
        where predicate: (String) -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if let source = editor.value as? String, predicate(source) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return false
    }
}
#endif
