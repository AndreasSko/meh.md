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
