import CryptoKit
import XCTest

/// Opt-in live checks. Run the phases individually, in order, on the
/// iCloud Dev scheme: Mac publish, physical iPhone reply, Mac verify.
final class ICloudDevelopmentUITests: XCTestCase {
    private let app = XCUIApplication()
    private var token: String {
        ProcessInfo.processInfo.environment["MEH_ICLOUD_UI_RUN"] ?? ""
    }
    private var macMarker: String { "Mac scheme check \(token)" }
    private var phoneMarker: String { "Phone scheme check \(token)" }
    private var offlineMacMarker: String { "Mac offline check \(token)" }
    private var offlinePhoneMarker: String { "Phone offline check \(token)" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(token.isEmpty, "Set a unique MEH_ICLOUD_UI_RUN to opt into live iCloud tests.")
        // No app environment flags: the installed build must choose iCloud.
    }

    func test01MacPublishesFromNormalEditor() throws {
        app.launch()
        let editor = try openEditor()
        append(macMarker, to: editor)
        exchange()
        app.terminate()
        app.launch()
        _ = try openEditor()
        waitForText(macMarker)
        exchange()
    }

    func test02PhoneJoinsAndRepliesAfterRelaunch() throws {
        app.launch()
        let editor = try openEditor()
        exchange()
        waitForText(macMarker)
        app.terminate()
        app.launch()
        _ = try openEditor()
        waitForText(macMarker)
        append(phoneMarker, to: editor)
        exchange()
    }

    func test03MacReceivesPhoneReply() throws {
        app.launch()
        _ = try openEditor()
        exchange()
        waitForText(macMarker)
        waitForText(phoneMarker)
    }

    func test04MacEditsDuringOutageAndRelaunches() throws {
        try editDuringOutage(offlineMacMarker, absent: offlinePhoneMarker)
    }

    func test05PhoneEditsDuringOutageAndRelaunches() throws {
        try editDuringOutage(offlinePhoneMarker, absent: offlineMacMarker)
    }

    func test06MacReconnects() throws {
        app.launch()
        _ = try openEditor()
        waitForText(offlineMacMarker)
        exchange()
    }

    func test07PhoneReconnectsAndMerges() throws {
        try verifyConvergence()
    }

    func test08MacReceivesMergedOfflineEdits() throws {
        try verifyConvergence()
    }

    private func editDuringOutage(_ marker: String, absent otherMarker: String) throws {
        app.launchEnvironment["MEH_SYNC_SIMULATE_OFFLINE"] = "1"
        app.launch()
        let editor = try openEditor()
        waitForText(macMarker)
        waitForText(phoneMarker)
        XCTAssertFalse((editor.value as? String ?? "").contains(otherMarker))
        append(marker, to: editor)
        waitForOutage()
        app.terminate()
        app.launch()
        let relaunchedEditor = try openEditor()
        waitForText(marker)
        waitForOutage()
        XCTAssertFalse((relaunchedEditor.value as? String ?? "").contains(otherMarker))
        app.terminate()
    }

    private func verifyConvergence() throws {
        app.launch()
        _ = try openEditor()
        exchange()
        waitForText(offlineMacMarker)
        waitForText(offlinePhoneMarker)
        app.terminate()
        app.launch()
        _ = try openEditor()
        waitForText(offlineMacMarker)
        waitForText(offlinePhoneMarker)
        let text = app.textViews["markdown-editor"].value as? String ?? ""
        let digest = SHA256.hash(data: Data(text.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        let attachment = XCTAttachment(string: "converged-note-sha256:" + digest)
        attachment.name = "converged-note-sha256"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitForOutage() {
        app.openSyncDetails()
        let status = app.staticTexts["note-sync-status"]
        expectation(for: NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@",
            "Simulated network outage", "Simulated network outage"
        ), evaluatedWith: status)
        waitForExpectations(timeout: 20)
        app.closeSyncDetails()
    }

    private func openEditor() throws -> XCUIElement {
        let editor = try app.openOrCreateNotebookEditor(timeout: 60)
        XCTAssertTrue(
            app.buttons["notebook-sync-details"].waitForExistence(timeout: 15)
        )
        return editor
    }

    private func append(_ text: String, to editor: XCUIElement) {
#if os(macOS)
        editor.click()
#else
        editor.tap()
#endif
        editor.typeKey(.downArrow, modifierFlags: .command)
        editor.typeText("\n\n" + text)
        waitForText(text)
        let saved = app.staticTexts["note-save-status"]
        expectation(for: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Saved on this device", "Saved on this device"), evaluatedWith: saved)
        waitForExpectations(timeout: 20)
    }

    private func exchange() {
        app.openSyncDetails()
        let button = app.buttons["sync-now"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: button)
        waitForExpectations(timeout: 30)
#if os(macOS)
        button.click()
#else
        button.tap()
#endif
        let status = app.staticTexts["note-sync-status"]
        let completed = NSPredicate { _, _ in
            let text = status.label + " " + (status.value as? String ?? "")
            return text.contains("Last sync") || text.contains("Sync paused")
        }
        expectation(for: completed, evaluatedWith: status)
        waitForExpectations(timeout: 60)
        let text = status.label + " " + (status.value as? String ?? "")
        XCTAssertTrue(text.contains("Last sync"), text)
        app.closeSyncDetails()
    }

    private func waitForText(_ text: String) {
        let editor = app.textViews["markdown-editor"]
        expectation(for: NSPredicate(format: "value CONTAINS %@", text), evaluatedWith: editor)
        waitForExpectations(timeout: 60)
    }
}
