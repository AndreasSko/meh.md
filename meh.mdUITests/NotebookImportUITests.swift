import XCTest

/// Opt-in native picker checks. Tools/Import/run_simulator_checks.py supplies
/// fictional documents and an isolated loopback workspace on a disposable phone.
@MainActor
final class NotebookImportUITests: XCTestCase {
    private var app: XCUIApplication!
    private var fixtureName = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let fixture = environment["MEH_IMPORT_TEST_FIXTURE"] ?? ""
        let workspace = environment["MEH_IMPORT_TEST_WORKSPACE"] ?? ""
        let port = Int(environment["MEH_IMPORT_TEST_PORT"] ?? "") ?? 0
        try XCTSkipUnless(
            !fixture.isEmpty && !workspace.isEmpty
                && (1...65_535).contains(port),
            "Use the opt-in Tools/Import simulator runner."
        )
        fixtureName = fixture
        app = XCUIApplication()
        app.launchEnvironment["MEH_SYNC_TEST_TRANSPORT"] = "loopback"
        // xctestrun normalizes URL slashes in test-host environment values.
        // Pass only the port and construct the fixed loopback URL here.
        app.launchEnvironment["MEH_SYNC_URL"] = "http://127.0.0.1:\(port)"
        app.launchEnvironment["MEH_SYNC_WORKSPACE"] =
            workspace + "-" + UUID().uuidString.prefix(8)
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    func testFilesCompleteAfterDismissalAndCancelDoesNotReimport() {
        openSettings()
        openPicker(folder: false)
        navigateToFixture()
        let first = sourceCell("First")
        let second = sourceCell("Second")
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.tap()
        second.tap()
        XCTAssertTrue(first.isSelected)
        XCTAssertTrue(second.isSelected)
        capture("import-files-selected")
        pickerOpenButton.tap()
        assertCompletionAfterDismissal()
        app.buttons["OK"].tap()
        app.buttons["Done"].tap()
        XCTAssertEqual(noteTitles, ["First", "Second"])
        capture("import-files-at-root")

        openSettings()
        openPicker(folder: false)
        // Cancel after an earlier successful import. The previous URLs must
        // not be delivered again when a fresh picker closes without choosing.
        let cancel = button(["Cancel", "Abbrechen"])
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(app.buttons["notebook-import"].waitForExistence(timeout: 5))
        XCTAssertFalse(completionAlert.waitForExistence(timeout: 3))
        app.buttons["Done"].tap()
        XCTAssertEqual(noteTitles, ["First", "Second"])
        capture("import-cancel-preserves-notes")
    }

    func testInvalidUTF8ErrorAppearsAfterDismissal() {
        openSettings()
        openPicker(folder: false)
        navigateToFixture()
        let invalid = sourceCell("Invalid")
        XCTAssertTrue(invalid.waitForExistence(timeout: 5))
        invalid.tap()
        pickerOpenButton.tap()
        let error = app.alerts.containing(
            .staticText, identifier: "Couldn’t Import Files"
        ).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 15))
        XCTAssertFalse(pickerOpenButton.exists)
        XCTAssertTrue(error.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "not valid UTF-8"
        )).firstMatch.exists)
        capture("import-invalid-utf8-error")
        app.buttons["OK"].tap()
        app.buttons["Done"].tap()
        XCTAssertEqual(noteTitles, [])
    }

    func testFolderCompletesAfterDismissalAtRoot() {
        openSettings()
        openPicker(folder: true)
        navigateToFixture()
        let folder = sourceCell("Folder")
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        folder.tap()
        pickerOpenButton.tap()
        assertCompletionAfterDismissal()
        app.buttons["OK"].tap()
        app.buttons["Done"].tap()
        XCTAssertEqual(noteTitles, ["Child", "Folder"])
        capture("import-folder-at-root")
    }

    private func openSettings() {
        let menu = app.buttons["notebook-app-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.tap()
        app.buttons["notebook-settings"].tap()
        XCTAssertTrue(app.buttons["notebook-import"].waitForExistence(timeout: 5))
        capture("import-settings")
    }

    private func openPicker(folder: Bool) {
        app.buttons["notebook-import"].tap()
        let choice = app.buttons[folder ? "Import Folder…" : "Import Files…"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        capture("import-source-choice")
        choice.tap()
        XCTAssertTrue(button(["Browse", "Durchsuchen"]).waitForExistence(timeout: 15))
    }

    private func navigateToFixture() {
        button(["Browse", "Durchsuchen"]).tap()
        let local = app.cells.matching(NSPredicate(
            format: "identifier IN %@",
            ["DOC.sidebar.item.On My iPhone", "DOC.sidebar.item.Auf meinem iPhone"]
        )).firstMatch
        XCTAssertTrue(local.waitForExistence(timeout: 5))
        local.tap()
        let container = app.cells.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "meh.md,"
        )).firstMatch
        XCTAssertTrue(container.waitForExistence(timeout: 5))
        container.tap()
        let fixture = sourceCell(fixtureName)
        XCTAssertTrue(fixture.waitForExistence(timeout: 5))
        fixture.tap()
    }

    private func sourceCell(_ name: String) -> XCUIElement {
        app.cells.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", name + ","
        )).firstMatch
    }

    private func button(_ labels: [String]) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
    }

    private var pickerOpenButton: XCUIElement { button(["Open", "Öffnen"]) }

    private var completionAlert: XCUIElement {
        app.alerts.containing(.staticText, identifier: "Import Complete").firstMatch
    }

    private func assertCompletionAfterDismissal() {
        // Regresses native auto-dismissal firing SwiftUI onDismiss before the
        // picker delivers its URLs, which silently lost successful selections.
        XCTAssertTrue(completionAlert.waitForExistence(timeout: 15))
        XCTAssertFalse(pickerOpenButton.exists)
        capture("import-completion-after-dismissal")
    }

    private var noteTitles: [String] {
        app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "notebook-sidebar-title-"
        )).allElementsBoundByIndex.map(\.label).sorted()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
