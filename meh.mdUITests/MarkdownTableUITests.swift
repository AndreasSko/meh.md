import XCTest

#if os(iOS)
final class MarkdownTableUITests: XCTestCase {
    func testTablePreviewAndSourceEditingKeepMarkdown() throws {
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
        let source = """
        | Activity | Time | Status |
        | :--- | :---: | ---: |
        | **Coastal walk** | 09:30 | Ready |
        | Museum and a relaxed lunch by the harbour | 12:00 | Planned |
        | Cafe | 15:00 | Open |

        A quiet afternoon by the sea.
        """
        editor.typeText(source)
        XCTAssertEqual(editor.value as? String, source)
        editor.swipeDown()
        capture(app, name: "Rendered table in the app")

        // A native hit inside the first few table rows must enter ordinary
        // source editing. The complete source remains the accessibility value.
        let noteTitle = app.buttons["note-title"]
        XCTAssertTrue(noteTitle.waitForExistence(timeout: 5))
        editor.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: editor.frame.width * 0.5,
                     dy: noteTitle.frame.maxY - editor.frame.minY + 70)
        ).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, source)
        capture(app, name: "Table revealed for editing")
        editor.typeText("!")
        let edited = try XCTUnwrap(editor.value as? String)
        XCTAssertEqual(edited.replacingOccurrences(of: "!", with: ""), source)
        XCTAssertEqual(edited.utf16.count, source.utf16.count + 1)
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
