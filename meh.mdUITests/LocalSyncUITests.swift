import XCTest

/// Run these phases in order: publish on iPhone, receive/reply on iPad,
/// then verify on the original iPhone. Use a fresh server data directory and
/// disposable simulators, or override the workspace through the test runner.
final class LocalSyncUITests: XCTestCase {
    private var app: XCUIApplication!
    private let first = "From iPhone: café 👋🏽 日本語\n"
    private let second = "From iPad: naïve 世界\n"

    override func setUpWithError() throws {
        app = XCUIApplication()
        continueAfterFailure = false
        app.launchEnvironment["MEH_SYNC_TEST_TRANSPORT"] = "loopback"
        app.launchEnvironment["MEH_SYNC_URL"] =
            ProcessInfo.processInfo.ciLoopbackURL
            ?? ProcessInfo.processInfo.environment["MEH_SYNC_TEST_URL"]
            ?? "http://127.0.0.1:8765"
        app.launchEnvironment["MEH_SYNC_WORKSPACE"] =
            ProcessInfo.processInfo.environment["MEH_SYNC_TEST_WORKSPACE"]
            ?? "milestone2-ui"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
    }

    func test01PublishFromPhone() throws {
        app.launch()
        let editor = try app.openOrCreateNotebookEditor(timeout: 20)
        XCTAssertEqual(editor.value as? String, "")
        editor.tap()
        editor.typeText(first)
        XCTAssertEqual(
            app.flushCurrentEditorBySwitchingNotes().value as? String,
            first
        )
        app.terminate()
        app.launch()
        XCTAssertEqual(
            try app.openOrCreateNotebookEditor(timeout: 20).value as? String,
            first
        )
        synchronize()
        app.terminate()
        app.launch()
        let relaunchedEditor = try app.openOrCreateNotebookEditor(timeout: 20)
        XCTAssertEqual(relaunchedEditor.value as? String, first)
    }

    func test02ReceiveAndReplyFromPad() throws {
        app.launch()
        _ = try app.openOrCreateNotebookEditor(timeout: 20)
        synchronize()
        let editor = try XCTUnwrap(app.openNotebookNote(withText: first))
        editor.tap()
        editor.typeKey(.downArrow, modifierFlags: .command)
        editor.typeText(second)
        XCTAssertEqual(
            app.flushCurrentEditorBySwitchingNotes().value as? String,
            first + second
        )
        app.terminate()
        app.launch()
        XCTAssertEqual(
            app.openNotebookNote(withText: first + second)?.value as? String,
            first + second
        )
        synchronize()
        XCTAssertNotNil(app.openNotebookNote(withText: first + second))
    }

    func test03ReceiveReplyOnPhoneAndRestart() throws {
        app.launch()
        _ = try app.openOrCreateNotebookEditor(timeout: 20)
        synchronize()
        XCTAssertNotNil(app.openNotebookNote(withText: first + second))
        app.terminate()
        app.launch()
        let relaunchedEditor = try XCTUnwrap(
            app.openNotebookNote(withText: first + second)
        )
        XCTAssertEqual(relaunchedEditor.value as? String, first + second)
        XCTAssertFalse(
            app.descendants(matching: .any)
                .matching(identifier: "note-save-status").firstMatch.exists
        )
    }

    private func synchronize() {
        app.openSyncDetails()
        app.buttons["sync-now"].tap()
        let predicate = NSPredicate(format: "label BEGINSWITH %@", "Last sync:")
        let status = app.descendants(matching: .any)
            .matching(identifier: "note-sync-status")
            .matching(predicate).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 20))
        app.closeSyncDetails()
    }

}
