import XCTest

#if os(iOS)
import UIKit

final class EditorKeyboardUITests: XCTestCase {
    func testHeadingPickerOffersEveryLevelAndKeepsWritingFocus() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.keyboardToolbar.commands", "()"]
        app.launchArguments += ["-editor.mode", "livePreview"]
        app.launch()
        let editor = openToolbarTestNote(app)
        editor.typeText("Observatory plans")
        let heading = toolbarCommand("editor-command-heading", in: app)
        XCTAssertEqual(heading.label, "Heading")
        let toolbar = toolbarContainer(in: app)
        XCTAssertGreaterThanOrEqual(heading.frame.minX, toolbar.frame.minX)
        XCTAssertLessThanOrEqual(heading.frame.maxX, toolbar.frame.maxX)

        heading.tap()
        let picker = app.scrollViews["editor-heading-style-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(picker.frame.width, min(320, app.frame.width - 32) - 4)
        XCTAssertLessThanOrEqual(picker.frame.height, 80)
        XCTAssertTrue(app.frame.contains(picker.frame))
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        let outside = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: editor.frame.minX + 5,
                                 dy: picker.frame.minY - 25))
        outside.tap()
        assertHeadingPickerDismissed(picker, source: "Observatory plans",
                                     editor: editor, app: app)

        for level in [1, 3, 6] {
            heading.tap()
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            XCTAssertTrue(app.keyboards.firstMatch.exists)
            for identifier in ["editor-command-body"] + (1...6).map({
                "editor-command-heading-\($0)"
            }) {
                XCTAssertTrue(app.buttons[identifier].exists)
            }
            let choice = horizontalHeadingPickerChoice(level, in: app)
            XCTAssertEqual(choice.label, "Heading \(level)")
            choice.tap()
            let expected = String(repeating: "#", count: level)
                + " Observatory plans"
            XCTAssertEqual(editor.value as? String, expected)
            XCTAssertTrue(app.keyboards.firstMatch.exists)

            heading.tap()
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            XCTAssertTrue(choice.isHittable, "Reopening reveals the active style without scrolling")
            XCTAssertTrue(picker.frame.contains(choice.frame))
            XCTAssertTrue(choice.isSelected, "The active level must have native selected styling")
            if level == 3 {
                XCTAssertEqual(choice.frame.midX, heading.frame.midX, accuracy: 20,
                               "The middle active heading opens near its toolbar button")
            }
            choice.tap()
            XCTAssertEqual(editor.value as? String, expected,
                           "Selecting the active heading must be idempotent")
        }
        heading.tap()
        XCTAssertFalse(app.buttons["editor-command-body"].isSelected)
        horizontalHeadingPickerChoice(nil, in: app).tap()
        XCTAssertEqual(editor.value as? String, "Observatory plans")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        editor.typeText(" for tonight")
        XCTAssertEqual(editor.value as? String, "Observatory plans for tonight")

        heading.tap()
        let body = app.buttons["editor-command-body"]
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertTrue(body.isSelected)
    }

    func testHeadingPickerScrollsAtLargestEditorTextSize() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.keyboardToolbar.commands", "()"]
        app.launchArguments += [
            "-editor.mode", "source", "-editor.fontSize", "28",
        ]
        app.launch()
        let editor = openToolbarTestNote(app)
        editor.typeText("Lunar watch")
        toolbarCommand("editor-command-heading", in: app).tap()
        let picker = app.scrollViews["editor-heading-style-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        capture(app, name: "Heading picker at largest editor text size")
        XCTAssertLessThanOrEqual(picker.frame.height, 60,
                                "Large note text must keep the formatting picker compact")
        let h6 = horizontalHeadingPickerChoice(6, in: app)
        XCTAssertTrue(h6.isHittable)
        capture(app, name: "Scrolled picker reaches H6 at large text size")
        h6.tap()
        XCTAssertEqual(editor.value as? String, "###### Lunar watch")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        editor.typeText(" tonight")
        XCTAssertEqual(editor.value as? String, "###### Lunar watch tonight")
        toolbarCommand("editor-command-heading", in: app).tap()
        let body = horizontalHeadingPickerChoice(nil, in: app)
        XCTAssertTrue(body.isHittable)
        body.tap()
        XCTAssertEqual(editor.value as? String, "Lunar watch tonight")
    }

    private func horizontalHeadingPickerChoice(
        _ level: Int?, in app: XCUIApplication
    ) -> XCUIElement {
        let identifier = level.map { "editor-command-heading-\($0)" }
            ?? "editor-command-body"
        let picker = app.scrollViews["editor-heading-style-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let choice = app.buttons[identifier]
        for _ in 0..<8 where !choice.isHittable || !picker.frame.contains(choice.frame) {
            let visible = (["editor-command-body"] + (1...6).map {
                "editor-command-heading-\($0)"
            }).map { app.buttons[$0] }.filter {
                $0.exists && $0.isHittable && picker.frame.contains($0.frame)
            }
                .sorted { $0.frame.midX < $1.frame.midX }
            XCTAssertGreaterThanOrEqual(visible.count, 2)
            guard let first = visible.first, let last = visible.last else { break }
            let origin = app.coordinate(withNormalizedOffset: .zero)
            // UIKit exposes partly clipped rows as hittable. Start the native
            // pan on an interior row so the popover treats it as scrolling.
            let leftRow = level == nil && visible.count > 2 ? visible[1] : first
            let rightRow = level != nil && visible.count > 2
                ? visible[visible.count - 2] : last
            let left = origin.withOffset(CGVector(dx: leftRow.frame.midX,
                                                  dy: leftRow.frame.midY))
            let right = origin.withOffset(CGVector(dx: rightRow.frame.midX,
                                                   dy: rightRow.frame.midY))
            (level == nil ? left : right).press(
                forDuration: 0.05, thenDragTo: level == nil ? right : left
            )
        }
        XCTAssertTrue(choice.isHittable)
        XCTAssertTrue(picker.frame.contains(choice.frame))
        return choice
    }

    private func assertHeadingPickerDismissed(
        _ picker: XCUIElement, source: String, editor: XCUIElement, app: XCUIApplication
    ) {
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: picker
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        XCTAssertEqual(editor.value as? String, source)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    }

    func testOrdinaryScrollRetainsKeyboardAndDragDismissesIt() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .phone,
            "iPad keeps the editor focused while scrolling"
        )
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launch()
        let newItem = app.buttons["notebook-new-item"]
        XCTAssertTrue(newItem.waitForExistence(timeout: 15))
        newItem.tap()
        commitDefaultTitle(in: app)
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        editor.typeText((1...24).map { "Line \($0)" }.joined(separator: "\n"))
        let editedText = try XCTUnwrap(editor.value as? String)
        editor.swipeUp()
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        let keyboard = app.keyboards.firstMatch
        let dragStart = editor.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)
        )
        let dragEnd = keyboard.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)
        )
        dragStart.press(forDuration: 0.05, thenDragTo: dragEnd)
        let hidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.keyboards.firstMatch
        )
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        XCTAssertEqual(editor.value as? String, editedText)
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        editor.typeText("Still editable")
        XCTAssertTrue((editor.value as? String)?.contains("Still editable") == true)
    }

    func testIPadScrollKeepsCaretAndTypingRevealsIt() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "iPad-specific editor focus behavior"
        )
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launch()
        let newItem = app.buttons["notebook-new-item"]
        XCTAssertTrue(newItem.waitForExistence(timeout: 15))
        newItem.tap()
        commitDefaultTitle(in: app)
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))

        let lines = (1...40).map { "Line \($0)" }.joined(separator: "\n")
        editor.typeText(lines)
        capture(app, name: "iPad caret before scrolling")
        dragEditor(editor)

        XCTAssertTrue(app.keyboards.firstMatch.exists)
        capture(app, name: "iPad caret scrolled offscreen")
        app.typeText(" resumed")
        let typingAtCaret = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value ENDSWITH %@", "Line 40 resumed"),
            object: editor
        )
        XCTAssertEqual(XCTWaiter.wait(for: [typingAtCaret], timeout: 5), .completed)
        XCTAssertEqual(editor.value as? String, lines + " resumed")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 2))
        capture(app, name: "iPad typing reveals caret after scrolling")
    }

    func testTypingStrikethroughAfterBoldRemainsResponsive() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "livePreview"]
        app.launch()
        let editor = openToolbarTestNote(app)
        editor.typeText("**B** ")
        editor.typeText("~")
        editor.typeText("~")
        editor.typeText("orbit~~ continues")
        XCTAssertEqual(editor.value as? String, "**B** ~~orbit~~ continues")
        capture(app, name: "Typing after bold and strikethrough")
    }

    func testFontPickerPreservesNoteAndShowsChoices() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launch()
        let editor = openToolbarTestNote(app)
        editor.typeText("A fictional font sample")
        let source = try XCTUnwrap(editor.value as? String)
        dragEditor(editor)
        app.buttons["notebook-note-actions"].tap()
        app.buttons["Editor Display"].tap()
        app.buttons["Font & Text Size…"].tap()
        let picker = app.buttons["editor-font-family"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        app.buttons["Serif"].tap()
        XCTAssertEqual(editor.value as? String, source)
        picker.tap()
        let serif = app.buttons["Serif"]
        XCTAssertTrue(serif.waitForExistence(timeout: 5))
        XCTAssertTrue(serif.isSelected)
    }

    func testToolbarOrderPersistsWithoutChangingNote() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launch()
        let editor = openToolbarTestNote(app)
        editor.typeText("Fictional toolbar sample")
        let source = try XCTUnwrap(editor.value as? String)
        let toolbar = toolbarContainer(in: app)
        XCTAssertTrue(toolbar.waitForExistence(timeout: 5))
        let expectedCommands = [
            "bold", "italic", "task-list", "insert-table", "indent",
            "outdent", "heading", "link", "strikethrough", "highlight",
            "inline-code", "code-block", "toggle-task",
        ]
        assertToolbarCommandsReachable(expectedCommands, in: app, toolbar: toolbar)
        let table = toolbarCommand("editor-table-menu", in: app)
        let neighbours = toolbar.buttons.allElementsBoundByIndex.filter {
            $0.identifier != "editor-table-menu" && $0.isHittable
                && $0.frame.midX < table.frame.midX
        }
        let initialNeighbour = try XCTUnwrap(
            neighbours.max { $0.frame.midX < $1.frame.midX },
            "The Table menu should have a visible command to its left"
        )
        // Resolve by stable identity: an index-bound query changes after
        // reordering, so read the identifier once, before the drag.
        let neighbourID = initialNeighbour.identifier
        let neighbour = app.buttons[neighbourID].firstMatch
        let initialVisibleOrder = visibleToolbarOrder(in: toolbar)
        capture(app, name: "Formatting bar before reorder")

        drag(table, onto: neighbour, before: true, in: app)
        let reorderedVisibleOrder = visibleToolbarOrder(in: toolbar)
        XCTAssertNotEqual(reorderedVisibleOrder, initialVisibleOrder)
        assertToolbarOrderStaysStable(reorderedVisibleOrder, in: toolbar)
        XCTAssertEqual(editor.value as? String, source)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        capture(app, name: "Reordered formatting bar")

        app.terminate()
        app.launch()
        let relaunchedEditor = openToolbarTestNote(app)
        let relaunchedToolbar = toolbarContainer(in: app)
        let relaunchedTable = toolbarCommand("editor-table-menu", in: app)
        let relaunchedNeighbour = app.buttons[neighbourID].firstMatch
        XCTAssertLessThan(relaunchedTable.frame.midX, relaunchedNeighbour.frame.midX)
        XCTAssertEqual(
            visibleToolbarOrder(in: relaunchedToolbar), reorderedVisibleOrder
        )

        drag(relaunchedTable, onto: relaunchedNeighbour, before: false, in: app)
        let restoredVisibleOrder = visibleToolbarOrder(in: relaunchedToolbar)
        XCTAssertEqual(restoredVisibleOrder, initialVisibleOrder)
        assertToolbarOrderStaysStable(restoredVisibleOrder, in: relaunchedToolbar)
        capture(app, name: "Formatting bar after two drags")

        relaunchedTable.tap()
        let inserted = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "| Column 1 | Column 2 |"),
            object: relaunchedEditor
        )
        XCTAssertEqual(XCTWaiter.wait(for: [inserted], timeout: 5), .completed,
                       "The moved Table menu must still insert a table")
    }

    private func openToolbarTestNote(_ app: XCUIApplication) -> XCUIElement {
        let newItem = app.buttons["notebook-new-item"]
        XCTAssertTrue(newItem.waitForExistence(timeout: 15))
        newItem.tap()
        commitDefaultTitle(in: app)
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        return editor
    }

    private func commitDefaultTitle(in app: XCUIApplication) {
        let titleField = app.textFields["title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 10))
        titleField.tap()
        #if os(macOS)
        titleField.typeKey(.return, modifierFlags: [])
        #else
        titleField.typeText("\n")
        #endif
    }

    private func dragEditor(_ editor: XCUIElement) {
        let start = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let end = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func drag(
        _ button: XCUIElement, onto target: XCUIElement, before: Bool,
        in app: XCUIApplication
    ) {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: button.frame.midX, dy: button.frame.midY))
        let end = origin.withOffset(CGVector(
            dx: before ? target.frame.minX - 6 : target.frame.maxX + 6,
            dy: target.frame.midY
        ))
        start.press(forDuration: 0.8, thenDragTo: end)
        // A drop may scroll the toolbar and briefly remove the button's AX cell.
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            button.exists && target.exists && button.isHittable
                && (button.frame.midX < target.frame.midX) == before
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed)
    }

    @discardableResult
    private func toolbarCommand(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let command = app.buttons[identifier]
        let toolbar = toolbarContainer(in: app)
        XCTAssertTrue(toolbar.waitForExistence(timeout: 5))
        for _ in 0..<12 where !command.isHittable {
            if command.exists && command.frame.midX < toolbar.frame.midX {
                toolbar.swipeRight()
            } else {
                toolbar.swipeLeft()
            }
        }
        XCTAssertTrue(command.isHittable, "Could not reveal \(identifier)")
        return command
    }

    private func toolbarContainer(in app: XCUIApplication) -> XCUIElement {
        let identifier = "editor-keyboard-toolbar"
        let collection = app.collectionViews[identifier]
        if collection.waitForExistence(timeout: 2) {
            return collection
        }
        return app.scrollViews[identifier]
    }

    private func assertToolbarCommandsReachable(
        _ commands: [String], in app: XCUIApplication, toolbar: XCUIElement
    ) {
        for command in commands {
            let identifier = command == "insert-table"
                ? "editor-table-menu" : "editor-command-\(command)"
            let button = app.buttons[identifier]
            for _ in 0..<12 where !button.isHittable {
                toolbar.swipeLeft()
            }
            XCTAssertTrue(
                button.isHittable,
                "Missing or unreachable toolbar command icon: \(command)"
            )
        }

        let bold = app.buttons["editor-command-bold"]
        for _ in 0..<12 where !bold.isHittable {
            toolbar.swipeRight()
        }
        for _ in 0..<4 {
            toolbar.swipeRight()
        }
        XCTAssertTrue(bold.isHittable, "Could not return to the start of the toolbar")
    }

    private func visibleToolbarOrder(in toolbar: XCUIElement) -> [String] {
        toolbar.buttons.allElementsBoundByIndex
            .filter { $0.exists && $0.frame.intersects(toolbar.frame) }
            .sorted { $0.frame.midX < $1.frame.midX }
            .map { $0.identifier }
    }

    private func assertToolbarOrderStaysStable(
        _ expectedOrder: [String], in toolbar: XCUIElement,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for _ in 0..<5 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
            XCTAssertEqual(
                visibleToolbarOrder(in: toolbar), expectedOrder,
                "Visible toolbar order shifted after the drag completed",
                file: file, line: line
            )
        }
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
