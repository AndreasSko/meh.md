import XCTest

final class NotePersistenceUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTypedTextSurvivesRelaunchAndUpdatesMarkdownCopy() throws {
        app.launch()

        let editor = try app.openOrCreateNotebookEditor(timeout: 15)

        let original = try XCTUnwrap(editor.value as? String)
        let marker = UUID().uuidString
        let addition = """


        ## CLI persistence \(marker)
        ASCII: save-relaunch-copy
        Unicode: café naïve 👋🏽 日本語
        """
        let expected = original + addition

        editor.tap()
        editor.typeKey(.downArrow, modifierFlags: .command)
        editor.typeText(addition)

        XCTAssertEqual(editor.value as? String, expected)
        try waitForStatus(
            identifier: "note-save-status",
            containing: "Saved on this device"
        )
        try waitForStatus(
            identifier: "markdown-copy-status",
            containing: "Markdown copies:"
        )

        app.terminate()
        app.launch()

        let relaunchedEditor = try app.openOrCreateNotebookEditor(timeout: 15)
        XCTAssertEqual(relaunchedEditor.value as? String, expected)
        try waitForStatus(
            identifier: "note-save-status",
            containing: "Saved on this device"
        )
        try waitForStatus(
            identifier: "markdown-copy-status",
            containing: "Markdown copies:"
        )

        let details = """
        Preserved \(original.utf8.count) original UTF-8 bytes.
        Appended marker: \(marker)
        Verified \(expected.utf8.count) UTF-8 bytes after relaunch.
        """
        let attachment = XCTAttachment(string: details)
        attachment.name = "Persistence verification"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitForStatus(
        identifier: String,
        containing expectedText: String
    ) throws {
        let predicate = NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@",
            expectedText,
            expectedText
        )
        let status = app.descendants(matching: .any)
            .matching(identifier: identifier)
            .matching(predicate)
            .firstMatch
        XCTAssertTrue(
            status.waitForExistence(timeout: 15),
            "Expected \(identifier) to contain '\(expectedText)'"
        )
    }
}
