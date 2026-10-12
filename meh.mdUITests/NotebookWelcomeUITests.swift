import XCTest

#if os(iOS)
@MainActor
final class NotebookWelcomeUITests: XCTestCase {
    func testStartWritingFocusesBodyAndKeepsFirstNote() throws {
        let app = try makeApp()
        app.launch()
        activate(app.buttons["notebook-welcome-write"])

        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String ?? "", "")
        XCTAssertTrue(app.buttons["note-title"].waitForExistence(timeout: 10))
        let generatedTitle = app.buttons["note-title"].label
        XCTAssertFalse(generatedTitle.isEmpty)
        let firstSentence = "This is my first fictional note."
        assertKeyboardFocus(on: editor)
        editor.typeText(firstSentence)
        XCTAssertEqual(editor.value as? String, firstSentence)
        activate(app.navigationBars.buttons.firstMatch)
        XCTAssertTrue(app.buttons["notebook-app-menu"].waitForExistence(timeout: 10))
        XCTAssertEqual(sidebarNotes(in: app).count, 1)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["notebook-app-menu"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.scrollViews["notebook-welcome"].exists)
        XCTAssertEqual(sidebarNotes(in: app).count, 1)
        activate(sidebarNotes(in: app).firstMatch)
        XCTAssertTrue(app.buttons["note-title"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons["note-title"].label, generatedTitle)
        XCTAssertEqual(editor.value as? String, firstSentence)
        activate(app.navigationBars.buttons.firstMatch)
        XCTAssertTrue(app.buttons["notebook-app-menu"].waitForExistence(timeout: 10))
        XCTAssertEqual(sidebarNotes(in: app).count, 1)
    }

    func testSkippingKeepsTheNotebookEmptyAfterRelaunch() throws {
        let app = try makeApp()
        app.launch()
        activate(app.buttons["notebook-welcome-skip"])
        XCTAssertTrue(app.buttons["notebook-new-item"].waitForExistence(timeout: 15))
        XCTAssertEqual(sidebarNotes(in: app).count, 0)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["notebook-app-menu"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.scrollViews["notebook-welcome"].exists)
        XCTAssertEqual(sidebarNotes(in: app).count, 0)
    }

    func testExamplesKeepEditsAndTemplateOnRepeatedGuideVisits() throws {
        let app = try makeApp()
        app.launch()
        activate(app.buttons["notebook-welcome-examples"])
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons["note-title"].label, "Start Here")
        let marker = "My fictional onboarding edit."
        editor.tap()
        editor.typeText(marker)
        activate(app.navigationBars.buttons.firstMatch)
        XCTAssertTrue(app.buttons["notebook-app-menu"].waitForExistence(timeout: 10))
        XCTAssertEqual(sidebarNotes(in: app).count, 3)

        for _ in 0..<2 {
            activate(app.buttons["notebook-app-menu"])
            activate(app.buttons["notebook-settings"])
            let guide = app.buttons["notebook-getting-started"]
            for _ in 0..<6 where !guide.isHittable { app.swipeUp() }
            activate(guide)
            activate(app.buttons["notebook-welcome-examples"])
            XCTAssertTrue(editor.waitForExistence(timeout: 15))
            XCTAssertTrue((editor.value as? String ?? "").contains(marker))
            activate(app.navigationBars.buttons.firstMatch)
            XCTAssertTrue(app.buttons["notebook-app-menu"].waitForExistence(timeout: 10))
            XCTAssertEqual(sidebarNotes(in: app).count, 3)
        }

        activate(app.buttons["notebook-app-menu"])
        activate(app.buttons["notebook-new-from-template"])
        let meeting = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "notebook-template-choice-"
        )).firstMatch
        XCTAssertTrue(meeting.waitForExistence(timeout: 10))
        XCTAssertTrue(meeting.label.contains("Meeting"))
        activate(meeting)
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["note-title"].label.hasSuffix(" - Meeting"))
        XCTAssertTrue((editor.value as? String ?? "").contains("## Next steps"))
        activate(app.navigationBars.buttons.firstMatch)
        XCTAssertTrue(app.buttons["notebook-app-menu"].waitForExistence(timeout: 10))
        XCTAssertEqual(sidebarNotes(in: app).count, 4)
    }

    private func makeApp() throws -> XCUIApplication {
        continueAfterFailure = false
        guard let rawPort = ProcessInfo.processInfo.environment[
            "MEH_WELCOME_UI_SYNC_PORT"
        ], let port = UInt16(rawPort), port > 0 else {
            throw XCTSkip("Requires an explicit disposable loopback sync port")
        }
        let app = XCUIApplication()
        app.launchEnvironment["MEH_WELCOME_TEST"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "0"
        app.launchEnvironment["MEH_SYNC_CLOUDKIT"] = "0"
        app.launchEnvironment["MEH_SYNC_TEST_TRANSPORT"] = "loopback"
        app.launchEnvironment["MEH_SYNC_URL"] = "http://127.0.0.1:\(port)"
        app.launchEnvironment["MEH_SYNC_WORKSPACE"] = "welcome-ui-" + UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        return app
    }

    private func activate(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 15))
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true AND hittable == true"),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        element.tap()
    }

    private func assertKeyboardFocus(on element: XCUIElement) {
        let focused = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 5), .completed)
    }

    private func sidebarNotes(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "notebook-sidebar-note-"
        ))
    }
}
#endif
