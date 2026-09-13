import XCTest

extension XCUIApplication {
    func openOrCreateNotebookEditor(timeout: TimeInterval = 30) throws -> XCUIElement {
        let editor = textViews["markdown-editor"]
        if editor.waitForExistence(timeout: 1) { return editor }

        let sidebar = buttons["notebook-new-item"]
        XCTAssertTrue(
            sidebar.waitForExistence(timeout: timeout),
            "Expected the notebook sidebar to finish loading"
        )

        let canonicalNote = staticTexts["note.md"]
        if canonicalNote.exists {
            activate(canonicalNote)
        } else {
            let markdownName = staticTexts.matching(
                NSPredicate(
                    format: "label MATCHES[c] %@",
                    ".*\\.(md|markdown)$"
                )
            ).firstMatch
            if markdownName.exists {
                activate(markdownName)
            } else {
                activate(sidebar)
                let newNote = menuItems["New Note"].exists
                    ? menuItems["New Note"] : buttons["New Note"]
                XCTAssertTrue(
                    newNote.waitForExistence(timeout: 5),
                    "Expected the New Note menu action"
                )
                activate(newNote)
                let name = textFields["Name"]
                XCTAssertTrue(
                    name.waitForExistence(timeout: 5),
                    "Expected the new note's inline name field"
                )
                name.typeText("\n")
            }
        }

        XCTAssertTrue(
            editor.waitForExistence(timeout: timeout),
            "Expected a selected notebook note to open its editor"
        )
        return editor
    }

    private func activate(_ element: XCUIElement) {
#if os(macOS)
        element.click()
#else
        element.tap()
#endif
    }
}
