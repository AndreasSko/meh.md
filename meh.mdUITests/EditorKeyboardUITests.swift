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
        capture(app, name: "Clear Heading toolbar button")

        heading.tap()
        let picker = app.scrollViews["editor-heading-style-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["More Levels"].exists)
        XCTAssertGreaterThanOrEqual(picker.frame.width, min(320, app.frame.width - 32) - 4)
        XCTAssertLessThanOrEqual(picker.frame.height, 80)
        XCTAssertTrue(app.frame.contains(picker.frame))
        capture(app, name: "Wide shallow heading previews with Body selected")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        let outside = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: editor.frame.minX + 5,
                                 dy: picker.frame.minY - 25))
        outside.tap()
        assertHeadingPickerDismissed(picker, source: "Observatory plans",
                                     editor: editor, app: app)

        for level in 1...6 {
            heading.tap()
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            XCTAssertTrue(app.keyboards.firstMatch.exists)
            for identifier in ["editor-command-body"] + (1...6).map({
                "editor-command-heading-\($0)"
            }) {
                XCTAssertTrue(app.buttons[identifier].exists)
            }
            capture(app, name: "Heading choices before H\(level)")
            let choice = horizontalHeadingPickerChoice(level, in: app)
            XCTAssertEqual(choice.label, "Heading \(level)")
            choice.tap()
            let expected = String(repeating: "#", count: level)
                + " Observatory plans"
            XCTAssertEqual(editor.value as? String, expected)
            XCTAssertTrue(app.keyboards.firstMatch.exists)
            capture(app, name: "H\(level) applied in Live Preview")

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
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Active H\(level) picker hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            capture(app, name: "Active H\(level) native selected style")
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
        capture(app, name: "Body restores ordinary writing")

        heading.tap()
        let body = app.buttons["editor-command-body"]
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertTrue(body.isSelected)
        capture(app, name: "Body native selected style")
    }

    func testHeadingPickerRetainsSourceTypingAndToolbarReordering() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.keyboardToolbar.commands", "()"]
        app.launchArguments += ["-editor.mode", "source"]
        app.launch()
        let editor = openToolbarTestNote(app)
        editor.typeText("Observatory plans")
        let heading = toolbarCommand("editor-command-heading", in: app)
        heading.tap()
        horizontalHeadingPickerChoice(2, in: app).tap()
        XCTAssertEqual(editor.value as? String, "## Observatory plans")
        editor.typeText(" for tonight")
        let source = "## Observatory plans for tonight"
        XCTAssertEqual(editor.value as? String, source)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        capture(app, name: "Heading retains Source mode typing")

        let bold = app.buttons["editor-command-bold"]
        let originalHeadingX = heading.frame.midX
        let originalBoldX = bold.frame.midX
        XCTAssertGreaterThan(originalHeadingX, originalBoldX)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: heading.frame.midX,
                                               dy: heading.frame.midY))
        let end = origin.withOffset(CGVector(dx: bold.frame.midX - 20,
                                             dy: bold.frame.midY))
        start.press(forDuration: 0.8, thenDragTo: end)
        let moved = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in heading.frame.midX < bold.frame.midX },
            object: app
        )
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed)
        XCTAssertEqual(editor.value as? String, source)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        capture(app, name: "Heading picker button reordered")
        heading.tap()
        XCTAssertTrue(horizontalHeadingPickerChoice(2, in: app).isSelected)
        horizontalHeadingPickerChoice(nil, in: app).tap()
        XCTAssertEqual(editor.value as? String, "Observatory plans for tonight")

        let returnStart = origin.withOffset(CGVector(dx: heading.frame.midX,
                                                     dy: heading.frame.midY))
        let returnEnd = origin.withOffset(CGVector(dx: originalHeadingX + 20,
                                                   dy: heading.frame.midY))
        returnStart.press(forDuration: 0.8, thenDragTo: returnEnd)
        let restored = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in heading.frame.midX > bold.frame.midX },
            object: app
        )
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
        XCTAssertEqual(heading.frame.midX, originalHeadingX, accuracy: 1)
        XCTAssertEqual(editor.value as? String, "Observatory plans for tonight")
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
        toolbarCommand("editor-command-heading", in: app).tap()
        let body = horizontalHeadingPickerChoice(nil, in: app)
        XCTAssertTrue(body.isHittable)
        body.tap()
        XCTAssertEqual(editor.value as? String, "Lunar watch")
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
        editor.typeText("> Sky\n\n* > Stars\n")
        editor.typeText((1...24).map { "Line \($0)" }.joined(separator: "\n"))
        let editedText = try XCTUnwrap(editor.value as? String)
        XCTAssertFalse(app.buttons["dismiss-editor-keyboard"].exists)
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
        capture(app, name: "Short quotes with keyboard dismissed")
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        capture(app, name: "Short quotes after keyboard reopening")
        editor.typeText("Still editable")
        XCTAssertTrue((editor.value as? String)?.contains("Still editable") == true)
        dragEditor(editor)
    }

    func testIPadScrollKeepsCaretAndTypingRevealsIt() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "iPad-specific editor focus behavior"
        )
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
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

    func testWritingControlsContinueListsAndSwitchModes() throws {
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
        editor.typeText("* Moon\n")
        XCTAssertEqual(editor.value as? String, "* Moon\n* ")
        editor.typeText("Orbit")
        let bold = app.buttons["editor-command-bold"]
        XCTAssertTrue(bold.waitForExistence(timeout: 5))
        XCTAssertLessThan(bold.frame.midY, app.keyboards.firstMatch.frame.minY)
        let italic = app.buttons["editor-command-italic"]
        XCTAssertTrue(italic.exists)
        XCTAssertFalse(bold.frame.intersects(italic.frame))
        capture(app, name: "Swipeable glass formatting bar")
        bold.tap()
        editor.typeText("bright")
        XCTAssertTrue((editor.value as? String)?.contains("**bright**") == true)
        let highlight = toolbarCommand("editor-command-highlight", in: app)
        XCTAssertTrue(highlight.exists)
        XCTAssertLessThan(highlight.frame.maxY, app.keyboards.firstMatch.frame.minY)
        highlight.tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        editor.typeText("glow")
        XCTAssertTrue((editor.value as? String)?.contains("==glow==") == true)
        let source = try XCTUnwrap(editor.value as? String)
        dragEditor(editor)
        app.buttons["notebook-note-actions"].tap()
        app.buttons["Source"].tap()
        XCTAssertEqual(editor.value as? String, source)
        capture(app, name: "Writing tools in Source mode")
        app.buttons["notebook-note-actions"].tap()
        app.buttons["Live Preview"].tap()
        XCTAssertEqual(editor.value as? String, source)
        capture(app, name: "Writing tools in Live Preview")
    }

    func testTypingStrikethroughAfterBoldRemainsResponsive() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
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

    func testLivePreviewListAndQuotePresentationPreservesSource() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "livePreview"]
        app.launch()
        let editor = openToolbarTestNote(app)
        editor.typeText("* Moon\nOrbit\n\n> Sky\nLight\n\nPlain")
        let source = try XCTUnwrap(editor.value as? String)
        XCTAssertTrue(source.contains("* Moon"))
        XCTAssertTrue(source.contains("> Sky"))
        capture(app, name: "Live Preview native bullets and quote rail")
        dragEditor(editor)
        XCTAssertEqual(editor.value as? String, source)
        capture(app, name: "Preview markers after keyboard dismissal")
        app.buttons["notebook-note-actions"].tap()
        app.buttons["Source"].tap()
        XCTAssertEqual(editor.value as? String, source)
        capture(app, name: "Original list and quote source markers")
    }

    func testFontPickerPreservesNoteAndShowsChoices() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launch()
        let editor = openToolbarTestNote(app)
        editor.typeText("A fictional font sample")
        let source = try XCTUnwrap(editor.value as? String)
        dragEditor(editor)
        app.buttons["notebook-note-actions"].tap()
        app.buttons["Font & Text Size…"].tap()
        let picker = app.buttons["editor-font-family"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        app.buttons["Serif"].tap()
        XCTAssertEqual(editor.value as? String, source)
        capture(app, name: "Native font and text size settings")
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
        let bold = app.buttons["editor-command-bold"]
        XCTAssertTrue(bold.waitForExistence(timeout: 5))
        let italic = app.buttons["editor-command-italic"]
        XCTAssertTrue(italic.waitForExistence(timeout: 5))
        let boldWasFirst = bold.frame.midX < italic.frame.midX
        XCTAssertNotEqual(bold.frame.midX, italic.frame.midX)
        let initialVisibleOrder = visibleToolbarOrder(in: toolbar)
        XCTAssertTrue(initialVisibleOrder.contains("editor-command-bold"))
        XCTAssertTrue(initialVisibleOrder.contains("editor-command-italic"))
        capture(app, name: "Formatting bar before reorder")
        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: italic.frame.midX, dy: italic.frame.midY))
        let end = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(
                dx: bold.frame.midX + (boldWasFirst ? -20 : 20),
                dy: bold.frame.midY
            ))
        start.press(forDuration: 0.8, thenDragTo: end)
        let reordered = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                (bold.frame.midX < italic.frame.midX) != boldWasFirst
            },
            object: app
        )
        XCTAssertEqual(XCTWaiter.wait(for: [reordered], timeout: 5), .completed)
        let italicVisible = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"), object: italic
        )
        XCTAssertEqual(XCTWaiter.wait(for: [italicVisible], timeout: 5), .completed)
        let reorderedVisibleOrder = visibleToolbarOrder(in: toolbar)
        XCTAssertNotEqual(reorderedVisibleOrder, initialVisibleOrder)
        assertToolbarOrderStaysStable(reorderedVisibleOrder, in: toolbar)
        XCTAssertEqual(editor.value as? String, source)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        capture(app, name: "Reordered formatting bar")
        app.terminate()
        app.launch()
        _ = openToolbarTestNote(app)
        let relaunchedBold = app.buttons["editor-command-bold"]
        let relaunchedItalic = app.buttons["editor-command-italic"]
        XCTAssertTrue(relaunchedBold.waitForExistence(timeout: 5))
        XCTAssertTrue(relaunchedItalic.waitForExistence(timeout: 5))
        XCTAssertEqual(
            relaunchedBold.frame.midX < relaunchedItalic.frame.midX,
            !boldWasFirst
        )
        let relaunchedToolbar = toolbarContainer(in: app)
        XCTAssertEqual(
            visibleToolbarOrder(in: relaunchedToolbar), reorderedVisibleOrder
        )
        let returnStart = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: relaunchedBold.frame.midX,
                                 dy: relaunchedBold.frame.midY))
        let returnEnd = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(
                dx: relaunchedItalic.frame.midX + (boldWasFirst ? -20 : 20),
                dy: relaunchedItalic.frame.midY
            ))
        returnStart.press(forDuration: 0.8, thenDragTo: returnEnd)
        let restored = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                (relaunchedBold.frame.midX < relaunchedItalic.frame.midX)
                    == boldWasFirst
            },
            object: app
        )
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
        let boldVisible = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: relaunchedBold
        )
        XCTAssertEqual(XCTWaiter.wait(for: [boldVisible], timeout: 5), .completed)
        let restoredVisibleOrder = visibleToolbarOrder(in: relaunchedToolbar)
        XCTAssertEqual(restoredVisibleOrder, initialVisibleOrder)
        assertToolbarOrderStaysStable(restoredVisibleOrder, in: relaunchedToolbar)
        capture(app, name: "Formatting bar after two drags")
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
