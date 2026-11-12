import XCTest

/// Menu-bar shortcuts for Markdown styles and new notes, with a hardware
/// keyboard on iPad and on the Mac.
@MainActor
final class KeyboardCommandUITests: XCTestCase {
    private var app: XCUIApplication!

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    func testNewNoteShortcut() throws {
        continueAfterFailure = false
        let editor = try openWritingNote()
        // ⌘N used to work only on the Mac.
        withoutIdleWait { editor.typeKey("n", modifierFlags: .command) }
        let emptyNote = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                (editor.value as? String)?.isEmpty == true
            }, object: editor
        )
        XCTAssertEqual(XCTWaiter.wait(for: [emptyNote], timeout: 10), .completed,
                       "Expected ⌘N to open a new, empty note")
    }

    private func openWritingNote() throws -> XCUIElement {
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
        activate(titleRow)
        let editor = app.textViews["markdown-editor"]
        assertSource(editor, "# Fictional voyage\n\nLiteral **Markdown** stays intact.")
        activate(editor)
        return editor
    }

    func testFormatShortcuts() throws {
        continueAfterFailure = false
        let editor = try openWritingNote()
        let initial = "# Fictional voyage\n\nLiteral **Markdown** stays intact."
        let line = initial + "\n\nTram 28"
        withoutIdleWait {
            editor.typeKey(.downArrow, modifierFlags: .command)
            editor.typeText("\n\nTram 28")
            assertSource(editor, line)
            editor.typeKey(.leftArrow, modifierFlags: [.command, .shift])
            // Highlight and Strikethrough had no shortcut before.
            editor.typeKey("e", modifierFlags: [.command, .shift])
            assertSource(editor, initial + "\n\n==Tram 28==")
            editor.typeKey("z", modifierFlags: .command)
            assertSource(editor, line)
            editor.typeKey("x", modifierFlags: [.command, .shift])
            assertSource(editor, initial + "\n\n~~Tram 28~~")
            editor.typeKey("z", modifierFlags: .command)
            assertSource(editor, line)
        }
    }

    private func assertSource(
        _ editor: XCUIElement, _ source: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let exact = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                (editor.value as? String)?.utf8.elementsEqual(source.utf8) == true
            }, object: editor
        )
        XCTAssertEqual(XCTWaiter.wait(for: [exact], timeout: 10), .completed,
                       "Expected the source: \(source)", file: file, line: line)
    }

    private func withoutIdleWait(_ body: () -> Void) {
#if os(iOS)
        app.withoutIdleWait(body)
#else
        body()
#endif
    }

    private func activate(_ element: XCUIElement) {
#if os(macOS)
        element.click()
#else
        element.tap()
#endif
    }
}
