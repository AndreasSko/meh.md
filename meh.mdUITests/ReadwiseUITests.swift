import XCTest

#if os(iOS)
/// Readwise in Labs with fictional books (`MEH_READWISE_FIXTURE=1`): set
/// up, import, add your own text, and keep it through the next sync.
@MainActor
final class ReadwiseUITests: XCTestCase {
    func testImportUpdateAndOwnText() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchEnvironment["MEH_READWISE_FIXTURE"] = "1"
        app.launchArguments += ["-labs.readwise", "YES"]
        app.launch()

        openReadwiseSettings(app)
        let token = app.secureTextFields["readwise-token"]
        XCTAssertTrue(token.waitForExistence(timeout: 10))
        token.tap()
        token.typeText("fictional-token")
        app.buttons["readwise-check"].tap()
        let connect = app.buttons["readwise-connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        XCTAssertEqual(connect.label, "Import 2 Books and 1 Article")
        connect.tap()
        waitForSync(app)
        closeReadwiseSettings(app)

        let editor = try openNote("The Quiet Garden", app)
        XCTAssertTrue((editor.value as? String)?.contains("A garden grows in the pauses between the work.") == true)
        editor.tap()
        app.typeText("\n\n## My thoughts\n\nPlant something this weekend.")
        showFiles(app)

        openReadwiseSettings(app)
        app.buttons["readwise-sync-now"].tap()
        waitForSync(app)
        closeReadwiseSettings(app)

        let updated = try openNote("The Quiet Garden", app)
        let text = try XCTUnwrap(updated.value as? String)
        XCTAssertTrue(text.contains("between the work, and in the work itself."), text)
        XCTAssertTrue(text.contains("Weeds are only plants out of place."), text)
        XCTAssertTrue(text.contains("## My thoughts\n\nPlant something this weekend."), text)
        XCTAssertEqual(text.components(separatedBy: "A garden grows").count, 2, text)

        app.buttons["notebook-note-actions"].tap()
        XCTAssertTrue(app.buttons["From Readwise"].waitForExistence(timeout: 5))
    }

    /// Sync Now is enabled again once a sync has finished.
    private func waitForSync(_ app: XCUIApplication) {
        let syncNow = app.buttons["readwise-sync-now"]
        XCTAssertTrue(syncNow.waitForExistence(timeout: 15))
        let done = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: syncNow)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 30), .completed)
    }

    private func openReadwiseSettings(_ app: XCUIApplication) {
        // An empty notebook has no Files list, so open Settings from the
        // app menu rather than through the sidebar helper.
        let menu = app.buttons["notebook-app-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.tap()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        let row = app.descendants(matching: .any)["notebook-readwise-settings"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.navigationBars["Readwise"].waitForExistence(timeout: 5))
    }

    private func closeReadwiseSettings(_ app: XCUIApplication) {
        app.navigationBars["Readwise"].buttons.firstMatch.tap()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
    }

    private func showFiles(_ app: XCUIApplication) {
        if !app.buttons["notebook-app-menu"].isHittable {
            app.navigationBars.buttons.firstMatch.tap()
        }
        XCTAssertTrue(app.buttons["notebook-app-menu"].waitForExistence(timeout: 5))
    }

    private func openNote(_ name: String, _ app: XCUIApplication) throws -> XCUIElement {
        // Each folder opens only when what it holds is not shown yet.
        for (folder, inside) in [("Readwise", "Books"), ("Books", name)] {
            XCTAssertTrue(title(folder, app).waitForExistence(timeout: 10), folder)
            if !title(inside, app).exists {
                app.buttons.matching(NSPredicate(format: "label == %@", folder)).firstMatch.tap()
            }
        }
        let note = title(name, app)
        XCTAssertTrue(note.waitForExistence(timeout: 10), name)
        note.tap()
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        return editor
    }

    private func title(_ name: String, _ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "notebook-sidebar-title-", name
        )).firstMatch
    }
}
#endif
