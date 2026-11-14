import XCTest

final class WelcomeNoteUITests: XCTestCase {
    func testFreshNotebookOpensTheWelcomeNoteOnce() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchEnvironment["MEH_WELCOME_NOTE"] = "1"
        app.launchArguments += ["-editor.mode", "source"]
        #if os(macOS)
        // As with "Close windows when quitting an app" turned off: AppKit
        // keeps the window, and its scene storage, when the app quits.
        app.launchArguments += ["-NSQuitAlwaysKeepsWindows", "YES"]
        #endif
        app.launch()

        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 30))
        XCTAssertTrue(waitForSource(editor) { $0.hasPrefix("I'm your first note.") },
                      "Welcome note did not open: \(editor.value ?? "nil")")

        // A relaunch opens the existing notebook and restores the note.
        // The window's identity is scene storage, which iOS saves when the
        // app leaves the foreground and the Mac when the app quits, so quit
        // the way a user would. Terminating the Mac app outright lost it
        // whenever AppKit had not saved the window yet.
        #if os(iOS)
        XCUIDevice.shared.press(.home)
        let deadline = Date().addingTimeInterval(10)
        while app.state == .runningForeground, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertNotEqual(app.state, .runningForeground)
        app.terminate()
        #else
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
        #endif
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 30))
        XCTAssertTrue(waitForSource(editor) { $0.hasPrefix("I'm your first note.") })
    }

    private func waitForSource(
        _ editor: XCUIElement, timeout: TimeInterval = 10,
        _ matches: (String) -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let value = editor.value as? String, matches(value) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return false
    }
}
