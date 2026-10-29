import XCTest

#if os(macOS)
import AppKit
@MainActor
final class MacFormattingUITests: XCTestCase {
    func testMacCompactFormattingRowAndHeadingControls() throws {
        continueAfterFailure = false
        let app = makeFixture()
        let editor = app.textViews["markdown-editor"]
        let formatting = app.buttons["editor-formatting"]
        let initial = source(editor)

        openFormatting(app)
        capture(app, name: "Mac formatting row immediately after opening")
        let commands = element(app, "editor-formatting-popover")
        XCTAssertTrue(commands.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(commands.frame.height, 32)
        XCTAssertLessThanOrEqual(commands.frame.height, 40)
        XCTAssertLessThanOrEqual(commands.frame.width, 380)
        XCTAssertGreaterThanOrEqual(commands.frame.minY, formatting.frame.maxY)
        XCTAssertTrue(element(app, "editor-command-bold").isHittable)
        assertNoVisibleScrollbars(commands)
        let scrollView = element(app, "editor-formatting-commands")
        let controls = formattingControls(app)
        XCTAssertTrue(scrollView.exists)
        for control in controls {
            XCTAssertTrue(control.exists)
        }
        let first = controls[0]
        XCTAssertTrue(first.isHittable)
        XCTAssertGreaterThanOrEqual(first.frame.minX, commands.frame.minX)
        XCTAssertLessThan(first.frame.maxX, commands.frame.maxX)
        let initiallyVisible = controls.filter(\.isHittable)
        for control in initiallyVisible.dropFirst() {
            XCTAssertEqual(control.frame.midY, first.frame.midY, accuracy: 1)
        }
        let visibleInRow = initiallyVisible.sorted { $0.frame.minX < $1.frame.minX }
        for pair in zip(visibleInRow, visibleInRow.dropFirst()) {
            XCTAssertEqual(pair.1.frame.midX - pair.0.frame.midX, 34, accuracy: 1)
        }
        XCTAssertEqual(source(editor), initial)
        XCTAssertTrue(element(app, "editor-command-bold").isHittable)
        capture(app, name: "Mac single-row formatting controls")
        editor.click()
        XCTAssertFalse(element(app, "editor-formatting-popover").exists)
        XCTAssertEqual(source(editor), initial)
        openFormatting(app)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(element(app, "editor-formatting-popover").exists)
        XCTAssertEqual(source(editor), initial)

        editor.typeKey("a", modifierFlags: .command)
        openFormatting(app)
        element(app, "editor-command-bold").click()
        waitForSource(editor, "**Observatory plans**")
        XCTAssertFalse(element(app, "editor-formatting-popover").exists)
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeText(" tonight")
        XCTAssertTrue(source(editor).contains("tonight"))

        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("Observatory plans")
        waitForSource(editor, "Observatory plans")
        openHeadings(app)
        let picker = element(app, "editor-formatting-popover")
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(picker.frame.height, 64)
        assertAllHeadingsVisible(app)
        capture(app, name: "Mac all heading levels fit with Body selected")
        choose(app, id: "editor-command-heading-1")
        waitForSource(editor, "# Observatory plans")
        openHeadings(app)
        assertAllHeadingsVisible(app)
        choose(app, id: "editor-command-body")
        waitForSource(editor, "Observatory plans")
        openHeadings(app)
        let back = element(app, "editor-formatting-back")
        XCTAssertTrue(back.isHittable)
        back.click()
        XCTAssertTrue(commands.waitForExistence(timeout: 5))
        XCTAssertEqual(source(editor), "Observatory plans")
        element(app, "editor-command-heading").click()
        choose(app, id: "editor-command-heading-3")
        waitForSource(editor, "### Observatory plans")
        openHeadings(app)
        let h3 = headingChoice(app, "editor-command-heading-3")
        XCTAssertTrue(h3.isHittable)
        XCTAssertTrue(isChecked(h3))
        let selectedPicker = element(app, "editor-formatting-popover")
        assertCenteredWithoutScrollbars(selectedPicker, choice: h3)
        assertAllHeadingsVisible(app)
        let h1Height = headingChoice(app, "editor-command-heading-1").frame.height
        let h6Height = headingChoice(app, "editor-command-heading-6").frame.height
        XCTAssertEqual(h1Height, h3.frame.height, accuracy: 2)
        XCTAssertEqual(h6Height, h3.frame.height, accuracy: 2)
        XCTAssertGreaterThanOrEqual(h3.frame.height, 22)
        XCTAssertLessThanOrEqual(h3.frame.height, 40)
        print("Mac heading geometry: H3", h3.frame, "picker", selectedPicker.frame)
        capture(app, name: "Mac H3 selected in the same formatting popover")
        h3.click()
        waitForSource(editor, "### Observatory plans")

        openHeadings(app)
        choose(app, id: "editor-command-heading-6")
        waitForSource(editor, "###### Observatory plans")
        openHeadings(app)
        let h6 = headingChoice(app, "editor-command-heading-6")
        XCTAssertTrue(h6.isHittable)
        XCTAssertTrue(isChecked(h6))
        assertAllHeadingsVisible(app)
        capture(app, name: "Mac H6 selected with every heading visible")
        choose(app, id: "editor-command-body")
        waitForSource(editor, "Observatory plans")
        app.typeText(" for tonight")
        waitForSource(editor, "Observatory plans for tonight")
        capture(app, name: "Mac Body restores continued writing")
        XCTAssertTrue(formatting.isHittable)
    }

    func testTitleFocusDisablesFormattingAndEditorRestoresIt() {
        continueAfterFailure = false
        let app = makeFixture()
        let formatting = app.buttons["editor-formatting"]
        element(app, "note-title").click()
        XCTAssertTrue(element(app, "title-field").waitForExistence(timeout: 5))
        XCTAssertFalse(formatting.isEnabled)
        capture(app, name: "Mac title editing disables formatting")
        let editor = app.textViews["markdown-editor"]
        editor.click()
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: formatting
        )
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        app.typeText(" tonight")
        XCTAssertTrue(source(editor).contains("tonight"))
    }

    func testSyncDetailsOpenBelowToolbar() {
        continueAfterFailure = false
        let app = makeFixture(windowTop: 220)
        let sync = element(app, "notebook-sync-details")
        XCTAssertTrue(sync.isHittable)
        XCTAssertGreaterThanOrEqual(sync.frame.minY, 200,
                                    "The details need room to open above the toolbar")
        sync.click()
        let status = element(app, "note-sync-status")
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(status.frame.minY, sync.frame.maxY)
        capture(app, name: "Mac sync details open below the toolbar")
    }

    private func formattingControls(_ app: XCUIApplication) -> [XCUIElement] {
        [
            element(app, "editor-command-bold"),
            element(app, "editor-command-italic"),
            element(app, "editor-command-task-list"),
            element(app, "editor-table-menu"),
            element(app, "editor-command-heading"),
            element(app, "editor-snippet-menu"),
            element(app, "editor-command-indent"),
            element(app, "editor-command-outdent"),
            element(app, "editor-command-link"),
            element(app, "editor-command-strikethrough"),
            element(app, "editor-command-highlight"),
            element(app, "editor-command-inline-code"),
            element(app, "editor-command-code-block"),
            element(app, "editor-command-toggle-task"),
        ]
    }

    private func makeFixture(windowTop: CGFloat? = nil) -> XCUIApplication {
        let fixturePath = ProcessInfo.processInfo.environment["MEH_MAC_UI_FIXTURE_APP_PATH"]
        let app = fixturePath.map { XCUIApplication(url: URL(fileURLWithPath: $0)) }
            ?? XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "source", "-editor.fontSize", "17",
                                "-AppleShowScrollBars",
                                ProcessInfo.processInfo.environment["MEH_MAC_UI_SCROLLBARS"]
                                    ?? "Always"]
        if let windowTop, let screen = NSScreen.main?.frame {
            // Dragging the title bar barely moves the window on the CI
            // runner, so open it in place. The frame counts from the bottom.
            let bottom = Int(screen.height - windowTop) - 450
            app.launchArguments += [
                "-ApplePersistenceIgnoreState", "YES",
                "-NSWindow Frame notebook-AppWindow-1",
                "62 \(bottom) 900 450 0 0 \(Int(screen.width)) \(Int(screen.height))",
            ]
        }
        app.launch()
        app.activate()
        let newNote = element(app, "notebook-new-item")
        XCTAssertTrue(newNote.waitForExistence(timeout: 15))
        let primaryAction = newNote.buttons.firstMatch
        XCTAssertTrue(primaryAction.waitForExistence(timeout: 5))
        primaryAction.click()
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeText("Observatory plans")
        waitForSource(editor, "Observatory plans")
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func openFormatting(_ app: XCUIApplication) {
        let button = app.buttons["editor-formatting"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.click()
        XCTAssertTrue(element(app, "editor-formatting-popover")
            .waitForExistence(timeout: 5))
    }

    private func openHeadings(_ app: XCUIApplication) {
        openFormatting(app)
        let heading = element(app, "editor-command-heading")
        XCTAssertTrue(heading.isHittable)
        heading.click()
        let firstChoice = headingChoice(app, "editor-command-body")
        XCTAssertTrue(firstChoice.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(firstChoice.frame.minY,
            app.buttons["editor-formatting"].frame.maxY)
    }

    private func choose(_ app: XCUIApplication, id: String) {
        let picker = element(app, "editor-formatting-popover")
        let choice = headingChoice(app, id)
        assertNoVisibleScrollbars(picker)
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        XCTAssertTrue(choice.isHittable)
        XCTAssertTrue(picker.frame.contains(choice.frame))
        choice.click()
    }

    private func assertCenteredWithoutScrollbars(
        _ viewport: XCUIElement, choice: XCUIElement
    ) {
        assertNoVisibleScrollbars(viewport)
        XCTAssertEqual(choice.frame.midY, viewport.frame.midY, accuracy: 3)
    }

    private func assertNoVisibleScrollbars(_ viewport: XCUIElement) {
        XCTAssertEqual(viewport.descendants(matching: .scrollBar)
            .allElementsBoundByIndex.filter { $0.isHittable }.count, 0)
    }

    private func assertAllHeadingsVisible(_ app: XCUIApplication) {
        let picker = element(app, "editor-formatting-popover")
        for id in ["editor-command-body"] + (1...6).map({ "editor-command-heading-\($0)" }) {
            let choice = headingChoice(app, id)
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            XCTAssertTrue(choice.isHittable)
            XCTAssertTrue(picker.frame.contains(choice.frame))
            XCTAssertLessThan(choice.frame.width, 64)
            print("Fully visible heading:", id, choice.frame)
        }
        assertNoVisibleScrollbars(picker)
    }

    private func headingChoice(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let label: String
        if id == "editor-command-body" {
            label = "Body"
        } else if let level = Int(id.replacingOccurrences(
            of: "editor-command-heading-", with: ""
        )) {
            label = "Heading \(level)"
        } else {
            XCTFail("Unexpected heading choice identifier: \(id)")
            return app.checkBoxes.firstMatch
        }
        return app.checkBoxes.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func isChecked(_ choice: XCUIElement) -> Bool {
        if let value = choice.value as? NSNumber { return value.boolValue }
        if let value = choice.value as? String { return value == "1" }
        return choice.isSelected
    }

    private func source(_ editor: XCUIElement) -> String {
        editor.value as? String ?? ""
    }

    private func waitForSource(_ editor: XCUIElement, _ expected: String) {
        let match = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expected), object: editor
        )
        XCTAssertEqual(XCTWaiter.wait(for: [match], timeout: 5), .completed)
    }

    private func capture(_ app: XCUIApplication, name: String) {
        // Let the native popover complete its presentation before media capture.
        Thread.sleep(forTimeInterval: 0.6)
        let image = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + " hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

}
#endif
