import XCTest

/// Files marks the open note, and its empty space works like Finder's: a
/// click first drops a selection of other rows, then closes the note.
final class NotebookOpenNoteUITests: XCTestCase {
    func testEmptySpaceClosesTheOpenNote() throws {
        let app = launch()
        let journal = row(titled: "Field journal", in: app)
        activate(journal)
        XCTAssertTrue(waitForEditor(in: app, prefix: "# Field journal"))
        XCTAssertTrue(waitForValue(of: journal, containing: "Current note"))
        capture(app, name: "Open note marked in Files")

        clickEmptySpace(in: app)
        XCTAssertTrue(app.staticTexts["Select a note"].waitForExistence(timeout: 5),
                      "A click on empty space kept the note open")
        capture(app, name: "Note closed from empty space")
        XCTAssertFalse(app.textViews["markdown-editor"].exists)
        XCTAssertTrue(waitForValue(of: journal, notContaining: "Current note"))
    }

    // On iPad, Command-tap replaces the selection until #312 lands.
    #if os(macOS)
    func testEmptySpaceFirstClearsOtherSelectedRows() throws {
        let app = launch()
        let journal = row(titled: "Field journal", in: app)
        let harbor = row(titled: "Harbor log", in: app)
        activate(journal)
        XCTAssertTrue(waitForEditor(in: app, prefix: "# Field journal"))
        let harborTitle = title(of: harbor, in: app)
        XCUIElement.perform(withKeyModifiers: .command) { harborTitle.click() }
        XCTAssertTrue(app.buttons["2 selected"].waitForExistence(timeout: 5))
        capture(app, name: "Two rows selected")

        clickEmptySpace(in: app)
        XCTAssertTrue(app.buttons["2 selected"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(title(of: harbor, in: app).isSelected)
        XCTAssertTrue(waitForEditor(in: app, prefix: "# Field journal"),
                      "The first click closed the note instead of the selection")
        XCTAssertTrue(waitForValue(of: journal, containing: "Current note"))
        capture(app, name: "Selection cleared, note still open")

        clickEmptySpace(in: app)
        XCTAssertTrue(app.staticTexts["Select a note"].waitForExistence(timeout: 5))
    }
    #endif

    func testNewNoteBecomesTheCurrentFilesRow() throws {
        let app = launch()
        let journal = row(titled: "Field journal", in: app)
        activate(journal)
        XCTAssertTrue(waitForEditor(in: app, prefix: "# Field journal"))

        activate(app.newNoteButton)
        let field = app.textFields["title-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        #if os(macOS)
        field.typeKey("a", modifierFlags: .command)
        #endif
        field.typeText("Tide table\n")
        let tide = row(titled: "Tide table", in: app)
        XCTAssertTrue(waitForValue(of: tide, containing: "Current note"))
        XCTAssertTrue(waitForValue(of: journal, notContaining: "Current note"))
        XCTAssertFalse(title(of: journal, in: app).isSelected,
                       "The previous note's row stayed selected")
        capture(app, name: "New note marked in Files")
    }

    func testEmptySpaceMenuCreatesANote() throws {
        let app = launch()
        let point = emptySpace(in: app)
        #if os(macOS)
        point.rightClick()
        XCTAssertNotNil(openMenuItem("New Folder", in: app), "Empty space showed no menu")
        try XCTUnwrap(openMenuItem("New Note", in: app)).click()
        #else
        app.withoutIdleWait {
            point.press(forDuration: 1)
            // Only the context menu offers New Folder without opening the
            // New Note button's menu first.
            XCTAssertTrue(app.buttons["New Folder"].waitForExistence(timeout: 5),
                          "Empty space showed no menu")
            let newNote = app.buttons.matching(NSPredicate(
                format: "label == %@ AND identifier != %@", "New Note", "notebook-new-item"
            )).firstMatch
            newNote.tap()
        }
        #endif
        XCTAssertTrue(app.textFields["title-field"].waitForExistence(timeout: 10))
    }

    #if os(macOS)
    /// The menu bar has the same items, but only an open menu's are hittable.
    private func openMenuItem(_ title: String, in app: XCUIApplication) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            let items = app.menuItems.matching(NSPredicate(format: "title == %@", title))
            if let item = items.allElementsBoundByIndex.first(where: { $0.isHittable }) {
                return item
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return nil
    }
    #endif

    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        #if os(iOS)
        // The note and Files stay side by side only in landscape. Other
        // tests on this simulator expect portrait.
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        #endif
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] =
            "open-note-\(UUID().uuidString)"
        app.launchEnvironment["MEH_NOTEBOOK_TEST_FIXTURE"] = "rendering"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "source"]
        app.launch()
        return app
    }

    /// A point below the footer face, inside Files.
    private func emptySpace(in app: XCUIApplication) -> XCUICoordinate {
        let footer = app.descendants(matching: .any)["notebook-library-footer"]
        XCTAssertTrue(footer.waitForExistence(timeout: 20))
        return footer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
            .withOffset(CGVector(dx: 0, dy: 60))
    }

    private func clickEmptySpace(in app: XCUIApplication) {
        #if os(macOS)
        emptySpace(in: app).click()
        #else
        emptySpace(in: app).tap()
        #endif
    }

    private func capture(_ app: XCUIApplication, name: String) {
        #if os(macOS)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        #else
        let attachment = XCTAttachment(screenshot: app.screenshot())
        #endif
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func activate(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    private func row(titled title: String, in app: XCUIApplication) -> XCUIElement {
        let titles = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (label == %@ OR value == %@)",
            "notebook-sidebar-title-", title, title
        ))
        XCTAssertTrue(titles.firstMatch.waitForExistence(timeout: 20),
                      "Expected \(title) in Files")
        let id = titles.firstMatch.identifier
            .replacingOccurrences(of: "notebook-sidebar-title-", with: "")
        let row = app.descendants(matching: .any)["notebook-sidebar-note-" + id]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        return row
    }

    private func title(of row: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        let id = row.identifier.replacingOccurrences(of: "notebook-sidebar-note-", with: "")
        return app.staticTexts["notebook-sidebar-title-" + id]
    }

    private func waitForEditor(in app: XCUIApplication, prefix: String) -> Bool {
        let opened = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value BEGINSWITH %@", prefix),
            object: app.textViews["markdown-editor"]
        )
        return XCTWaiter.wait(for: [opened], timeout: 5) == .completed
    }

    // The Mac List doesn't expose a row's value, only its title's, which
    // the title text itself fills there. Only iPad can check the marker.
    private func waitForValue(of row: XCUIElement, containing text: String) -> Bool {
        #if os(macOS)
        return true
        #else
        let matches = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", text), object: row
        )
        return XCTWaiter.wait(for: [matches], timeout: 5) == .completed
        #endif
    }

    private func waitForValue(of row: XCUIElement, notContaining text: String) -> Bool {
        #if os(macOS)
        return true
        #else
        let matches = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "NOT (value CONTAINS %@)", text), object: row
        )
        return XCTWaiter.wait(for: [matches], timeout: 5) == .completed
        #endif
    }
}
