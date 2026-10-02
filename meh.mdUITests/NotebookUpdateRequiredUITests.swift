import XCTest

#if os(iOS)
@MainActor
final class NotebookUpdateRequiredUITests: XCTestCase {
    func testUpdateRequiredShowsPausedStatusWithoutRetry() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_NOTEBOOK_UPDATE_REQUIRED_TEST"] = "1"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launch()

        let syncDetails = app.buttons["notebook-sync-details"]
        XCTAssertTrue(syncDetails.waitForExistence(timeout: 15))
        XCTAssertEqual(syncDetails.value as? String, "Update required")
        syncDetails.tap()

        let title = app.staticTexts["Update required"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[
            "Update meh.md to resume iCloud sync. You can keep editing your notes on this device."
        ].exists)
        XCTAssertFalse(app.buttons["sync-now"].exists)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Update required · iPhone"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
