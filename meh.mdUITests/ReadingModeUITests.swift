import XCTest

#if os(iOS)
/// Reading Mode locks the open note: taps bring up no keyboard and check no
/// task, while links still open. Set `TEST_RUNNER_MEH_READING_TOUR=1` to
/// pause between steps for PR recordings.
final class ReadingModeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testReadingModeLocksTheNoteUntilEdit() {
        launch()
        openNote("Lightning talk")
        let editor = app.textViews["markdown-editor"]
        let source = editor.value as? String
        tap(at: Self.prose)
        let writingBar = app.descendants(matching: .any)["editor-command-heading"]
        XCTAssertTrue(writingBar.waitForExistence(timeout: 5))
        pause(1.5)

        // Turned on while writing, it puts the keyboard and its bar away.
        toggleFromMenu("notebook-reading-mode", label: "Reading")
        let edit = app.buttons["notebook-reading-edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "Reading Mode shows its Edit button")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(writingBar.waitForNonExistence(timeout: 5),
                      "The writing bar goes away with the keyboard")
        // Beside Files on iPad, the sidebar keeps its own New Note button.
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertFalse(app.buttons["notebook-new-item"].exists,
                           "Edit takes the New Note button's place")
        }
        pause(1.5)

        tap(at: Self.prose)
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 2),
                       "A tap in the note brings up no keyboard")
        tap(at: Self.openTask)
        pause(1)
        XCTAssertEqual(editor.value as? String, source, "A tap checks no task")
        XCTAssertFalse(app.buttons["note-title"].exists, "The title can't be renamed")
        pause(1)

        tap(at: Self.link)
        assertTitle("Speaker checklist")
        XCTAssertTrue(edit.waitForExistence(timeout: 5),
                      "Reading Mode stays on in the linked note")
        pause(1.5)
        app.navigationBars.buttons.firstMatch.tap()
        assertTitle("Lightning talk")
        pause(1)

        edit.tap()
        XCTAssertTrue(edit.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["notebook-new-item"].waitForExistence(timeout: 5))
        tap(at: Self.openTask)
        XCTAssertTrue(waitForValue(of: editor) { $0 != source },
                      "After Edit, the same tap checks the task")
        tap(at: Self.prose)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "After Edit, a tap brings up the keyboard")
        pause(2)
    }

    func testSpeakerModeTurnsOnReadingMode() {
        launch()
        openNote("Lightning talk")
        app.textViews["markdown-editor"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let writingBar = app.descendants(matching: .any)["editor-command-heading"]
        XCTAssertTrue(writingBar.waitForExistence(timeout: 5))

        toggleFromMenu("notebook-speaker-mode", label: "Speaker Mode")
        XCTAssertTrue(app.buttons["speaker-island"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["notebook-reading-edit"].waitForExistence(timeout: 5),
                      "Speaker Mode starts in Reading Mode")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5),
                      "Reading Mode puts the keyboard away")
        XCTAssertTrue(writingBar.waitForNonExistence(timeout: 5),
                      "The writing bar goes away with the keyboard")

        // Turning Speaker Mode off leaves Reading Mode as it is.
        toggleFromMenu("notebook-speaker-mode", label: "Speaker Mode")
        XCTAssertTrue(app.buttons["speaker-island"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["notebook-reading-edit"].exists)
    }

    // Spots in the fixture's note, in points from the editor's left edge
    // and below the title, in Live Preview at the default text size.
    private static let link = CGVector(dx: 60, dy: 26)
    private static let openTask = CGVector(dx: 40, dy: 198)
    private static let prose = CGVector(dx: 120, dy: 372)

    private func tap(at spot: CGVector) {
        let title = app.staticTexts["note-title"].exists
            ? app.staticTexts["note-title"] : app.buttons["note-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let editor = app.textViews["markdown-editor"]
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: editor.frame.minX + spot.dx, dy: title.frame.maxY + spot.dy))
            .tap()
    }

    private func launch() {
        app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_NOTEBOOK_TEST_FIXTURE"] = "reading-mode"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchEnvironment["MEH_SYNC_CLOUDKIT"] = "0"
        app.launchArguments += [
            "-editor.mode", "livePreview",
            "-labs.speakerMode", "YES",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
    }

    private func openNote(_ title: String) {
        let note = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (label == %@ OR value == %@)",
            "notebook-sidebar-title-", title, title
        )).firstMatch
        if !note.waitForExistence(timeout: 10) { app.revealNotebookSidebar(timeout: 30) }
        XCTAssertTrue(note.waitForExistence(timeout: 30))
        pause(1)
        note.tap()
        XCTAssertTrue(app.textViews["markdown-editor"].waitForExistence(timeout: 15))
        assertTitle(title)
    }

    private func toggleFromMenu(_ identifier: String, label: String) {
        let actions = app.buttons["notebook-note-actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 15))
        actions.tap()
        let item = app.noteMenuAction(identifier, label: label)
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        pause(0.8)
        item.tap()
    }

    private func assertTitle(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(10)
        repeat {
            if app.staticTexts["note-title"].exists && app.staticTexts["note-title"].label == title
                || app.buttons["note-title"].exists && app.buttons["note-title"].label == title {
                return
            }
            pause(0.1)
        } while Date() < deadline
        XCTFail("Expected the note titled \(title)", file: file, line: line)
    }

    private func waitForValue(of element: XCUIElement, where predicate: (String) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if let value = element.value as? String, predicate(value) { return true }
            pause(0.1)
        } while Date() < deadline
        return false
    }

    /// Recording runs pause between steps; plain runs don't.
    private func pause(_ seconds: TimeInterval) {
        guard ProcessInfo.processInfo.environment["MEH_READING_TOUR"] == "1" else {
            return RunLoop.current.run(until: Date().addingTimeInterval(min(seconds, 0.3)))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
#endif
