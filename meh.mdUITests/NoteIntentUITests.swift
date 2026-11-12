import AppIntentsTesting
import XCTest

#if os(iOS)
/// Runs the app's intents the way Control Center and Shortcuts do: out of
/// process, against the running app. iOS only: on the Mac, the system
/// reports a test build of the app as "not present".
final class NoteIntentUITests: XCTestCase {
    // The test bundle's identifier is the app's plus ".UITests", in every
    // build configuration.
    private let definitions = IntentDefinitions(bundleIdentifier: String(
        Bundle(for: NoteIntentUITests.self).bundleIdentifier!
            .dropLast(".UITests".count)
    ))

    @MainActor
    func testNewNoteControlStartsANewNote() async throws {
        continueAfterFailure = false
        let app = launchPreview()

        try await definitions.intents["NewNoteIntent"].makeIntent().run()

        let titleField = app.textFields["title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 10),
                      "The control must start naming a new note")
        let name = titleField.value as? String ?? ""
        XCTAssertTrue(name.hasPrefix(Self.todayStem), "Got \(name)")
    }

    @MainActor
    func testCreateNoteShortcutAddsANoteAndItsLinkOpensIt() async throws {
        continueAfterFailure = false
        let app = launchPreview()
        let createNote = definitions.intents["CreateNoteIntent"]

        let named = try await createNote.makeIntent(
            text: "Milk\nEggs", name: "Groceries"
        ).run()
        try await createNote.makeIntent(text: "Call Sam").run()

        app.revealNotebookSidebar()
        XCTAssertTrue(sidebarTitle("Groceries", in: app).waitForExistence(timeout: 10),
                      "The note must show up while the app is open")
        XCTAssertTrue(sidebarTitle(Self.todayStem, in: app).exists,
                      "Without a name, the note must get today's date")

        let link: URL = try named.value
        XCTAssertEqual(link.host(), "note")
        app.open(link)
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, "Milk\nEggs")
        XCTAssertEqual(app.openNoteTitle, "Groceries")

        do {
            try await createNote.makeIntent(text: "Lost", name: "Work/Ideas").run()
            XCTFail("A name with a / must fail")
        } catch {
            XCTAssertTrue(
                "\(error)".contains("Names cannot contain"),
                "Shortcuts must show why the name failed, got \(error)"
            )
        }
    }

    @MainActor
    private func sidebarTitle(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@",
            "notebook-sidebar-title-", title
        )).firstMatch
    }

    private static var todayStem: String {
        Date.now.formatted(
            Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
    }

    @MainActor
    private func launchPreview() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "source"]
        app.launch()
        XCTAssertTrue(app.newNoteButton.waitForExistence(timeout: 15))
        return app
    }
}
#endif
