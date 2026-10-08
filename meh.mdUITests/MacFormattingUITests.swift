import XCTest

#if os(macOS)
@MainActor
final class MacFormattingUITests: XCTestCase {
    func testCompactFormattingKeepsHeadingAndWritingInOnePopover() throws {
        continueAfterFailure = false
        let app = makeFixture()
        let editor = app.textViews["markdown-editor"]
        let formatting = app.buttons["editor-formatting"]
        let initial = source(editor)

        openFormatting(app)
        let commands = element(app, "editor-formatting-popover")
        XCTAssertTrue(commands.waitForExistence(timeout: 5))
        // Native regular controls grew in macOS 27. Keep the panel at native
        // desktop density, allowing two points for accessibility rounding.
        XCTAssertLessThanOrEqual(commands.frame.height, formatting.frame.height + 2)
        // Native toolbar hit rectangles extend beyond the visible Aa control.
        // The panel begins below Aa and its center stays below the toolbar.
        XCTAssertGreaterThanOrEqual(commands.frame.minY, formatting.frame.midY)
        XCTAssertGreaterThan(commands.frame.midY, formatting.frame.maxY)
        XCTAssertTrue(element(app, "editor-command-bold").isHittable)
        print("Mac control geometry: Aa", formatting.frame, "formatting", commands.frame)
        capture(app, name: "Mac compact formatting controls")
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
        let picker = element(app, "editor-heading-style-picker")
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(picker.frame.height, commands.frame.height + 2)
        let back = element(app, "editor-formatting-back")
        XCTAssertTrue(back.isHittable)
        back.click()
        XCTAssertTrue(commands.waitForExistence(timeout: 5))
        XCTAssertEqual(source(editor), "Observatory plans")
        element(app, "editor-command-heading").click()
        choose(app, id: "editor-command-heading-3", forward: true)
        waitForSource(editor, "### Observatory plans")
        openHeadings(app)
        let h3 = element(app, "editor-command-heading-3")
        XCTAssertTrue(h3.isHittable)
        XCTAssertTrue(isChecked(h3))
        let h1Height = element(app, "editor-command-heading-1").frame.height
        let h6Height = element(app, "editor-command-heading-6").frame.height
        XCTAssertEqual(h1Height, h3.frame.height, accuracy: 2)
        XCTAssertEqual(h6Height, h3.frame.height, accuracy: 2)
        XCTAssertGreaterThanOrEqual(h3.frame.height, 22)
        XCTAssertLessThanOrEqual(h3.frame.height, picker.frame.height)
        print("Mac heading geometry: H3", h3.frame, "picker", picker.frame)
        capture(app, name: "Mac H3 selected in the same formatting popover")
        h3.click()
        waitForSource(editor, "### Observatory plans")

        openHeadings(app)
        choose(app, id: "editor-command-heading-6", forward: true)
        waitForSource(editor, "###### Observatory plans")
        openHeadings(app)
        let h6 = element(app, "editor-command-heading-6")
        XCTAssertTrue(h6.isHittable)
        XCTAssertTrue(isChecked(h6))
        capture(app, name: "Mac H6 selected after horizontal scrolling")
        choose(app, id: "editor-command-body", forward: false)
        waitForSource(editor, "Observatory plans")
        app.typeText(" for tonight")
        waitForSource(editor, "Observatory plans for tonight")
        capture(app, name: "Mac Body restores continued writing")
        XCTAssertTrue(formatting.isHittable)
    }

    private func makeFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "source", "-editor.fontSize", "17"]
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
        let picker = element(app, "editor-heading-style-picker")
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(picker.frame.minY,
            app.buttons["editor-formatting"].frame.maxY)
    }

    private func choose(_ app: XCUIApplication, id: String, forward: Bool) {
        let picker = element(app, "editor-heading-style-picker")
        let choice = element(app, id)
        if !choice.exists || !choice.isHittable || !picker.frame.contains(choice.frame) {
            picker.hover()
            let before = choice.exists ? choice.frame : .null
            if forward { picker.swipeLeft() } else { picker.swipeRight() }
            print("Native swipe choice frame:", before, "->", choice.exists ? choice.frame : .null,
                  "viewport:", picker.frame)
        }
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        XCTAssertTrue(choice.isHittable)
        XCTAssertTrue(picker.frame.contains(choice.frame))
        choice.click()
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
