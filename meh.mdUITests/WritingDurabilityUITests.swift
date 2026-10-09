import XCTest

/// Literal source and UUID survive native editing and a real save boundary.
@MainActor
final class WritingDurabilityUITests: XCTestCase {
    private var app: XCUIApplication!

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    func testFormattedWritingUndoAndRelaunchPreserveExactNote() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_NOTEBOOK_TEST_FIXTURE"] = "writing"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchEnvironment["MEH_SYNC_CLOUDKIT"] = "0"
        app.launchArguments += ["-editor.mode", "source"]
        app.launch()

        let title = "Fictional field notes"
        let titleRow = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (label == %@ OR value == %@)",
            "notebook-sidebar-title-", title, title
        )).firstMatch
        XCTAssertTrue(titleRow.waitForExistence(timeout: 15))
        let noteID = titleRow.identifier.replacingOccurrences(
            of: "notebook-sidebar-title-", with: ""
        )
        XCTAssertNotNil(UUID(uuidString: noteID))
        activate(titleRow)
        let editor = app.textViews["markdown-editor"]
        let initial = "# Fictional voyage\n\nLiteral **Markdown** stays intact."
        assertEditor(editor, title: title, source: initial, in: app)

        activate(editor)
        editor.typeKey(.downArrow, modifierFlags: .command)
        editor.typeText("\n\nAurora watch")
        let appended = initial + "\n\nAurora watch"
        assertEditor(editor, title: title, source: appended, in: app)
        editor.typeKey(.leftArrow, modifierFlags: [.command, .shift])
        editor.typeKey("b", modifierFlags: .command)
        assertEditor(editor, title: title, source: initial + "\n\n**Aurora watch**", in: app)
        editor.typeKey("z", modifierFlags: .command)
        assertEditor(editor, title: title, source: appended, in: app)
        editor.typeKey(.downArrow, modifierFlags: .command)
        let addition = "\n\nUnicode: café naïve 👋🏽 日本語"
        editor.typeText(addition)
        let expected = appended + addition
        assertEditor(editor, title: title, source: expected, in: app)

        let identifier = "notebook-sidebar-note-" + noteID
        app.revealNotebookSidebar()
        let alternateTitle = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (label == %@ OR value == %@)",
            "notebook-sidebar-title-", "Save boundary", "Save boundary"
        )).firstMatch
        XCTAssertTrue(alternateTitle.waitForExistence(timeout: 10))
        let alternateID = alternateTitle.identifier.replacingOccurrences(
            of: "notebook-sidebar-title-", with: ""
        )
        XCTAssertNotNil(UUID(uuidString: alternateID))
        XCTAssertNotEqual(alternateID, noteID)
        activate(alternateTitle)
        assertEditor(editor, title: "Save boundary",
                     source: "# Save boundary\n\nFictional notes.", in: app)
        app.revealNotebookSidebar()
        openNote(noteID, title: title)
        assertEditor(editor, title: title, source: expected, in: app)
        assertNoSaveStatus()
        app.terminate()
        app.launch()
        // Open the stored UUID, even if launch restores a different note.
        app.revealNotebookSidebar()
        let files = app.buttons["notebook-tree-toggle"]
        if files.value as? String == "Collapsed" { activate(files) }
        let persistedRow = app.descendants(matching: .any)
            .matching(identifier: identifier).firstMatch
        XCTAssertTrue(persistedRow.waitForExistence(timeout: 15))
        openNote(noteID, title: title)
        assertEditor(editor, title: title, source: expected, in: app)
        assertNoSaveStatus()
    }

    private func openNote(_ id: String, title: String) {
        let rowTitle = app.staticTexts["notebook-sidebar-title-" + id]
        let exactTitle = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                rowTitle.exists && (rowTitle.label == title
                    || rowTitle.value as? String == title)
            }, object: rowTitle
        )
        XCTAssertEqual(XCTWaiter.wait(for: [exactTitle], timeout: 10), .completed,
                       "Expected the retained UUID to still name the original note")
        activate(rowTitle)
    }

    private func assertNoSaveStatus() {
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(identifier: "note-save-status").firstMatch.exists)
    }

    private func assertEditor(
        _ editor: XCUIElement, title: String, source: String,
        in app: XCUIApplication
    ) {
        let exact = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard editor.exists,
                      let observed = editor.value as? String else { return false }
#if os(iOS)
                guard app.buttons["note-title"].label == title else { return false }
#endif
                return observed.utf8.elementsEqual(source.utf8)
            }, object: app
        )
        XCTAssertEqual(XCTWaiter.wait(for: [exact], timeout: 10), .completed,
                       "Expected the opened note’s exact literal UTF-8 source: \(source)")
    }

    private func activate(_ element: XCUIElement) {
#if os(macOS)
        element.click()
#else
        element.tap()
#endif
    }
}
