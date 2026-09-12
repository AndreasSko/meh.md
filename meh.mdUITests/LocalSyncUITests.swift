import XCTest

/// Run these phases in order: publish on iPhone, receive/reply on iPad,
/// then verify on the original iPhone. Use a fresh server data directory and
/// disposable simulators, or override the workspace through the test runner.
final class LocalSyncUITests: XCTestCase {
    private let app = XCUIApplication()
    private let first = "From iPhone: café 👋🏽 日本語\n"
    private let second = "From iPad: naïve 世界\n"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchEnvironment["MEH_SYNC_URL"] = "http://127.0.0.1:8765"
        app.launchEnvironment["MEH_SYNC_WORKSPACE"] =
            ProcessInfo.processInfo.environment["MEH_SYNC_TEST_WORKSPACE"]
            ?? "milestone2-ui"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
    }

    func test01PublishFromPhone() throws {
        app.launch()
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 20))
        XCTAssertEqual(editor.value as? String, "")
        editor.tap()
        editor.typeText(first)
        waitForSaved()
        synchronize()
        app.terminate()
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 20))
        XCTAssertEqual(editor.value as? String, first)
        waitForCopy()
    }

    func test02ReceiveAndReplyFromPad() throws {
        app.launch()
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 20))
        synchronize()
        waitForEditor(first)
        editor.tap()
        editor.typeKey(.downArrow, modifierFlags: .command)
        editor.typeText(second)
        waitForSaved()
        synchronize()
        waitForEditor(first + second)
        waitForCopy()
    }

    func test03ReceiveReplyOnPhoneAndRestart() throws {
        app.launch()
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 20))
        synchronize()
        XCTAssertEqual(editor.value as? String, first + second)
        waitForCopy()
        app.terminate()
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 20))
        XCTAssertEqual(editor.value as? String, first + second)
        waitForSaved()
        waitForCopy()
    }

    private func synchronize() {
        app.buttons["sync-now"].tap()
        let predicate = NSPredicate(format: "label BEGINSWITH %@", "Last sync:")
        let status = app.descendants(matching: .any)
            .matching(identifier: "note-sync-status")
            .matching(predicate).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 20))
    }

    private func waitForSaved() {
        waitForStatus("note-save-status", containing: "Saved on this device")
    }

    private func waitForEditor(_ expected: String) {
        let editor = app.textViews["markdown-editor"]
        let predicate = NSPredicate(format: "value == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 20), .completed)
    }

    private func waitForCopy() {
        waitForStatus("markdown-copy-status", containing: "Markdown copy up to date")
    }

    private func waitForStatus(_ identifier: String, containing text: String) {
        let predicate = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
        let status = app.descendants(matching: .any)
            .matching(identifier: identifier).matching(predicate).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 20))
    }
}
