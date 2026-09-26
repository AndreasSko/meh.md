import XCTest

#if os(iOS)
final class MarkdownWideTableUITests: XCTestCase {
    func testWideTableScrollsWithoutChangingMarkdown() throws {
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
        | Stop | Day | Arrival | Transport | Stay | Cost | Contact | Status |
        | :--- | :---: | ---: | :--- | :--- | ---: | :--- | :--- |
        | Seaside | Mon | 09:30 | Train | Blue Inn | 48 | Mira | Booked |
        | Gardens | Tue | 11:00 | Tram | East House | 62 | Jonas | Planned |

        This fictional trip continues after the table.

        A second paragraph makes vertical scrolling easy to check.
        """
        editor.typeText(source)
        XCTAssertEqual(editor.value as? String, source)
        editor.swipeDown()

        let noteTitle = app.buttons["note-title"]
        XCTAssertTrue(noteTitle.waitForExistence(timeout: 5))
        let titleY = noteTitle.frame.minY
        capture(app, name: "Wide table at its left edge")

        // Drag across the rendered header. This should move only the table's
        // viewport; the note's Markdown and vertical position remain intact.
        let y = noteTitle.frame.maxY - editor.frame.minY + 42
        let start = editor.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: editor.frame.width * 0.82, dy: y)
        )
        let end = editor.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: editor.frame.width * 0.18, dy: y)
        )
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertEqual(editor.value as? String, source)
        XCTAssertEqual(noteTitle.frame.minY, titleY, accuracy: 2)
        capture(app, name: "Wide table scrolled to the right")

        // The ordinary note scroll must still move vertically over a table.
        editor.swipeUp()
        XCTAssertEqual(editor.value as? String, source)
        XCTAssertLessThan(noteTitle.frame.minY, titleY - 40)
        capture(app, name: "Vertical note scroll after table pan")
        editor.swipeDown()

        // A tap enters the normal source editor and an edit changes one byte.
        editor.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: editor.frame.width * 0.5,
                     dy: noteTitle.frame.maxY - editor.frame.minY + 70)
        ).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, source)
        capture(app, name: "Wide table revealed as Markdown")
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
