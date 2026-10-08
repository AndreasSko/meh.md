import XCTest

#if os(iOS)
import UIKit

@MainActor
final class MarkdownRenderedTableEditingUITests: XCTestCase {
    private let source = """
    | Activity | Time | Status |
    | :--- | :---: | ---: |
    | **Coastal walk** | 09:30 | Ready |
    | Museum and a relaxed lunch by the harbour | 12:00 | Planned |
    | Cafe | 15:00 | Open |

    A quiet afternoon by the sea.
    """

    private let overflowSource = "| Column 1 | Column 2 |\n| --- | --- |\n"
        + "|  Sample |  ||  |  |\n"
        + "| Harbour | 12:00 | Kept extra | Another extra |\n"

    func testOverflowRowsRenderAndCellEditsPreserveCompleteSource() {
        let (app, editor) = launchFixture(fixtureSource: overflowSource)
        XCTAssertTrue(cell("markdown-table-cell-2-1", in: app).exists)
        XCTAssertFalse(cell("markdown-table-cell-1-2", in: app).exists)
        XCTAssertFalse(cell("markdown-table-cell-2-2", in: app).exists)
        XCTAssertEqual(editor.value as? String, overflowSource)
        editor.swipeDown()
        capture(app, name: "Overflow rows rendered without changing Markdown")
        let cellEditor = activateFirstBodyCell(in: app)
        XCTAssertEqual(cellEditor.value as? String, "Sample")
        cellEditor.typeText("!")
        guard let editedSample = cellEditor.value as? String else {
            XCTFail("The native cell editor should expose its literal text")
            return
        }
        XCTAssertEqual(editedSample.replacingOccurrences(of: "!", with: ""), "Sample")
        XCTAssertTrue(editedSample.contains("!"))
        let expected = overflowSource.replacingOccurrences(of: "Sample", with: editedSample)
        XCTAssertTrue(waitForSource(editor) { $0 == expected })
        XCTAssertTrue(cell("markdown-table-cell-2-1", in: app).exists)
        switchToSource(in: app)
        XCTAssertTrue(cellEditor.waitForNonExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, expected)
        XCTAssertTrue(expected.contains("||  |  |\n"))
        XCTAssertTrue(expected.contains("| Kept extra | Another extra |\n"))
        capture(app, name: "Overflow cells preserved in literal Source mode")
    }

    func testCellEditingKeepsTableRenderedAndOtherMarkdownUnchanged() {
        let (app, editor) = launchFixture()
        let cellEditor = activateFirstBodyCell(in: app)
        capture(app, name: "Rendered table with native cell editor")
        XCTAssertEqual(cellEditor.value as? String, "**Coastal walk**")
        cellEditor.typeText("!")
        XCTAssertTrue(waitForSource(editor) {
            $0 != self.source && $0.replacingOccurrences(of: "!", with: "") == self.source
        })
        XCTAssertTrue(cellEditor.isHittable)
        XCTAssertTrue(cell("markdown-table-cell-0-1", in: app).exists)
        XCTAssertTrue(cell("markdown-table-cell-2-2", in: app).exists)
        capture(app, name: "Edited cell with table still rendered")
    }

    func testTableButtonCanBeReorderedWithoutChangingNote() {
        let (app, editor) = launchFixture()
        let cellEditor = activateFirstBodyCell(in: app)
        let menu = toolbarButton("editor-table-menu", in: app)
        let toolbar = app.collectionViews["editor-keyboard-toolbar"]
        let neighbours = toolbar.buttons.allElementsBoundByIndex.filter {
            $0.identifier != "editor-table-menu" && $0.isHittable
                && $0.frame.midX < menu.frame.midX
        }
        guard let initialNeighbour = neighbours.max(by: { $0.frame.midX < $1.frame.midX }) else {
            XCTFail("The Table control should have a visible command to its left")
            return
        }
        // Resolve by stable identity: an index-bound query changes after reordering.
        let neighbour = toolbar.buttons[initialNeighbour.identifier].firstMatch
        func moveTable(before: Bool) {
            let center = CGVector(dx: 0.5, dy: 0.5)
            let start = menu.coordinate(withNormalizedOffset: center)
            let end = neighbour.coordinate(withNormalizedOffset: center)
                .withOffset(CGVector(dx: before ? -18 : 18, dy: 0))
            // Give UIKit time to lift the cell and accept a one-cell insertion.
            // Match the native toolbar drag used by the keyboard-order tests.
            start.press(forDuration: 1.2, thenDragTo: end,
                        withVelocity: .slow, thenHoldForDuration: 0.6)
            // A drop may scroll the collection and temporarily remove its AX cell.
            _ = toolbarButton("editor-table-menu", in: app)
            let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                menu.exists && neighbour.exists
                    && (menu.frame.midX < neighbour.frame.midX) == before
            }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed)
        }
        moveTable(before: true)
        XCTAssertEqual(editor.value as? String, source)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        capture(app, name: "Table icon remains draggable")
        moveTable(before: false)
        XCTAssertEqual(editor.value as? String, source)
        menu.tap()
        menuAction("Next Cell", in: app).tap()
        XCTAssertTrue(waitForSource(cellEditor) { $0 == "09:30" })
    }

    func testTableMenuLabelsCancelDeletionAndKeepCellFocus() {
        let (app, editor) = launchFixture()
        let cellEditor = activateFirstBodyCell(in: app)
        let menu = toolbarButton("editor-table-menu", in: app)
        XCTAssertTrue(menu.label.contains("Table"))
        capture(app, name: "Rendered table with Table toolbar icon")
        menu.tap()
        for title in ["Row", "Column", "Column Alignment", "Previous Cell", "Next Cell"] {
            XCTAssertTrue(menuAction(title, in: app).isEnabled)
        }
        capture(app, name: "Readable native Table actions")
        menuAction("Column Alignment", in: app).tap()
        for title in ["Align Left", "Align Center", "Align Right"] {
            XCTAssertTrue(menuAction(title, in: app).isEnabled)
        }
        capture(app, name: "Readable column alignment choices")
        menuAction("Align Left", in: app).tap()
        tableCommand("editor-command-table-delete-row", in: app).tap()
        let rowPrompt = app.sheets["Delete row?"].firstMatch
        XCTAssertTrue(rowPrompt.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, source)
        capture(app, name: "Delete table row requires confirmation")
        cancelDeletion(in: app, prompt: rowPrompt)
        XCTAssertEqual(editor.value as? String, source)
        XCTAssertTrue(cellEditor.isHittable)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        cellEditor.typeText("!")
        XCTAssertTrue(waitForSource(editor) {
            $0 != self.source && $0.replacingOccurrences(of: "!", with: "") == self.source
        })
        let beforeColumnCancel = editor.value as? String
        tableCommand("editor-command-table-delete-column", in: app).tap()
        let columnPrompt = app.sheets["Delete column?"].firstMatch
        XCTAssertTrue(columnPrompt.waitForExistence(timeout: 5))
        cancelDeletion(in: app, prompt: columnPrompt)
        XCTAssertTrue(cellEditor.isHittable)
        XCTAssertEqual(editor.value as? String, beforeColumnCancel)
    }

    func testTableMenuDeleteRowPreservesOtherCellsAndParagraph() {
        let (app, editor) = launchFixture()
        let cellEditor = activateFirstBodyCell(in: app)
        tableCommand("editor-command-table-delete-row", in: app).tap()
        let delete = app.buttons["Delete Row"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, source)
        delete.tap()
        let expected = source.replacingOccurrences(
            of: "| **Coastal walk** | 09:30 | Ready |\n", with: ""
        )
        XCTAssertTrue(waitForSource(editor) { $0 == expected })
        XCTAssertTrue(cellEditor.exists)
        XCTAssertTrue(cellEditor.isHittable)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        capture(app, name: "Confirmed row deletion preserves the rendered table")
    }

    func testAccessibilityTextSizeCellEditorRemainsVisible() {
        let (app, editor) = launchFixture(
            contentSizeCategory: "UICTContentSizeCategoryAccessibilityXXXL"
        )
        let cellEditor = activateFirstBodyCell(in: app)
        XCTAssertTrue(cellEditor.frame.intersects(editor.frame))
        cellEditor.typeText("!")
        XCTAssertTrue(waitForSource(editor) {
            $0 != self.source && $0.replacingOccurrences(of: "!", with: "") == self.source
        })
        XCTAssertTrue(cellEditor.isHittable)
        capture(app, name: "Accessible text size native cell editing")
        let menu = toolbarButton("editor-table-menu", in: app)
        XCTAssertTrue(menu.label.contains("Table"))
        XCTAssertGreaterThanOrEqual(menu.frame.width, 44)
        capture(app, name: "Accessible text size Table icon")
        menu.tap()
        XCTAssertTrue(menuAction("Next Cell", in: app).isEnabled)
        capture(app, name: "Accessible text size native Table actions")
        menuAction("Next Cell", in: app).tap()
        XCTAssertTrue(waitForSource(cellEditor) { $0 == "09:30" })
        XCTAssertTrue(cellEditor.isHittable)
    }

    func testNativeUndoRestoresSourceAndActiveCell() {
        let (app, editor) = launchFixture()
        let cellEditor = activateFirstBodyCell(in: app)
        cellEditor.typeText("!")
        XCTAssertTrue(waitForSource(editor) {
            $0 != self.source && $0.replacingOccurrences(of: "!", with: "") == self.source
        })
        // UIKit's native keyboard command uses the shared note undo manager.
        XCTAssertTrue(cellEditor.isHittable)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        cellEditor.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitForSource(editor) { $0 == self.source },
                      "Source after native undo: \(editor.value ?? "nil")")
        XCTAssertTrue(waitForSource(cellEditor) { $0 == "**Coastal walk**" })
        XCTAssertTrue(cellEditor.isHittable)
        XCTAssertTrue(cell("markdown-table-cell-0-1", in: app).exists)
        capture(app, name: "Native undo restored the active rendered cell")

        cellEditor.typeText("!")
        XCTAssertTrue(waitForSource(editor) { $0 != self.source })
        switchToSource(in: app)
        XCTAssertTrue(cellEditor.waitForNonExistence(timeout: 5))
        XCTAssertTrue(editor.isHittable)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        editor.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitForSource(editor) { $0 == self.source })
        app.buttons["notebook-note-actions"].tap()
        app.buttons["Live Preview"].tap()
        XCTAssertTrue(cellEditor.waitForExistence(timeout: 5))
        XCTAssertEqual(cellEditor.value as? String, "**Coastal walk**")
        XCTAssertTrue(cellEditor.isHittable)
        capture(app, name: "Source undo refreshed the rendered cell")
    }

    func testNativeKeyboardUndoOnIPad() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad,
                      "The native keyboard Undo control is checked on iPad")
        let (app, editor) = launchFixture()
        let cellEditor = activateFirstBodyCell(in: app)
        cellEditor.typeText("!")
        XCTAssertTrue(waitForSource(editor) { $0 != self.source })
        capture(app, name: "iPad native Undo control before tap")
        let undo = app.buttons["assistantUndo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        XCTAssertTrue(undo.isEnabled)
        undo.tap()
        XCTAssertTrue(waitForSource(editor) { $0 == self.source },
                      "Source after Undo control: \(editor.value ?? "nil")")
        XCTAssertTrue(waitForSource(cellEditor) { $0 == "**Coastal walk**" })
        capture(app, name: "iPad native Undo control restored rendered cell")
        cellEditor.typeText("\n")
        XCTAssertTrue(waitForSource(cellEditor) {
            $0 == "Museum and a relaxed lunch by the harbour"
        })
        capture(app, name: "iPad software Return moved to the next table row")
    }

    func testNextPreviousAndReturnNavigateNativeCellEditor() {
        let (app, editor) = launchFixture()
        let cellEditor = activateFirstBodyCell(in: app)
        tableCommand("editor-command-table-next-cell", in: app).tap()
        XCTAssertTrue(waitForSource(cellEditor) { $0 == "09:30" })
        // Navigation selects the entire destination so replacement is native.
        cellEditor.typeText("10:00")
        XCTAssertTrue(waitForSource(editor) {
            $0 == self.source.replacingOccurrences(of: "09:30", with: "10:00")
        })
        tableCommand("editor-command-table-previous-cell", in: app).tap()
        XCTAssertTrue(waitForSource(cellEditor) { $0 == "**Coastal walk**" })
        cellEditor.typeText("\n")
        XCTAssertTrue(waitForSource(cellEditor) {
            $0 == "Museum and a relaxed lunch by the harbour"
        })
        XCTAssertTrue(cell("markdown-table-cell-0-1", in: app).exists)
        XCTAssertFalse((editor.value as? String ?? "").contains("\n\n| Museum"))
    }

    func testHardwareTabAndShiftTabNavigateCellsOnIPad() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad,
                      "Hardware keyboard navigation is checked on iPad")
        let (app, editor) = launchFixture()
        let cellEditor = activateFirstBodyCell(in: app)
        app.typeKey(.tab, modifierFlags: [])
        XCTAssertTrue(waitForSource(cellEditor) { $0 == "09:30" })
        cellEditor.typeText("10:00")
        XCTAssertTrue(waitForSource(editor) {
            $0 == self.source.replacingOccurrences(of: "09:30", with: "10:00")
        })
        app.typeKey(.tab, modifierFlags: .shift)
        XCTAssertTrue(waitForSource(cellEditor) { $0 == "**Coastal walk**" })
        // XCTest emits no Return HID event in this iPad simulator's source
        // or cell editor. Software Return is covered by the native Undo test.
        capture(app, name: "iPad native hardware keyboard cell navigation")
    }

    func testLiteralPipeAndUnicodeRemainOneCellInSourceMode() {
        let (app, editor) = launchFixture()
        let cellEditor = activateFirstBodyCell(in: app)
        tableCommand("editor-command-table-next-cell", in: app).tap()
        cellEditor.typeText("09:30 | 🌊")
        let expected = source.replacingOccurrences(of: "09:30", with: "09:30 \\| 🌊")
        XCTAssertTrue(waitForSource(editor) { $0 == expected })
        XCTAssertTrue(cell("markdown-table-cell-1-2", in: app).exists)
        switchToSource(in: app)
        XCTAssertTrue(cellEditor.waitForNonExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, expected)
        capture(app, name: "Cell edit preserved as escaped Markdown source")
    }

    func testMultilinePastePreservesTableAndSurroundingSource() {
        let (app, editor) = launchFixture()
        let cellEditor = activateFirstBodyCell(in: app)
        tableCommand("editor-command-table-next-cell", in: app).tap()
        UIPasteboard.general.string = "09:30 | ferry\narrives"
        cellEditor.doubleTap()
        let paste = app.menuItems.matching(NSPredicate(format: "label IN %@", ["Paste", "Einsetzen"])).firstMatch
        let pasteButton = app.buttons.matching(NSPredicate(format: "label IN %@", ["Paste", "Einsetzen"])).firstMatch
        if paste.waitForExistence(timeout: 2) {
            paste.tap()
        } else {
            XCTAssertTrue(pasteButton.waitForExistence(timeout: 3))
            pasteButton.tap()
        }
        let allow = app.alerts.buttons["Allow Paste"].firstMatch
        if allow.waitForExistence(timeout: 1) { allow.tap() }
        XCTAssertTrue(waitForSource(editor) {
            $0.contains("ferry") && $0.contains("arrives")
                && $0.contains("\\|") && $0.hasSuffix("A quiet afternoon by the sea.")
                && $0.components(separatedBy: "\n").count == self.source.components(separatedBy: "\n").count
        })
        XCTAssertTrue(cell("markdown-table-cell-1-2", in: app).exists)
        XCTAssertTrue(cellEditor.exists)
        capture(app, name: "Multiline paste kept inside rendered cell")
    }

    private func launchFixture(
        contentSizeCategory: String? = nil,
        fixtureSource: String? = nil
    ) -> (XCUIApplication, XCUIElement) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = "rendered-table-ui-\(UUID().uuidString)"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        // Keep fixture captures independent of a previous persisted toolbar drag.
        app.launchArguments += [
            "-editor.keyboardToolbar.commands",
            "(bold,italic,taskList,insertTable,indent,outdent,heading,link,"
                + "strikethrough,highlight,inlineCode,codeBlock,toggleTask)",
        ]
        if let contentSizeCategory {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSizeCategory]
        }
        app.launch()
        let newNote = app.buttons["notebook-new-item"].firstMatch
        XCTAssertTrue(newNote.waitForExistence(timeout: 15))
        newNote.tap()
        let title = app.textFields["title-field"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        title.typeText("\n")
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        app.buttons["notebook-note-actions"].tap()
        app.buttons["Live Preview"].tap()
        editor.tap()
        let fixture = fixtureSource ?? source
        editor.typeText(fixture)
        XCTAssertEqual(editor.value as? String, fixture)
        editor.swipeDown()
        let firstCell = cell("markdown-table-cell-1-0", in: app)
        XCTAssertTrue(firstCell.waitForExistence(timeout: 5))
        for _ in 0..<4 where firstCell.frame.minY < app.navigationBars.firstMatch.frame.maxY {
            editor.swipeDown()
        }
        for _ in 0..<3 where firstCell.frame.maxY > editor.frame.maxY - 12 {
            let start = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.72))
            let end = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.42))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        return (app, editor)
    }

    private func activateFirstBodyCell(in app: XCUIApplication) -> XCUIElement {
        let bodyCell = cell("markdown-table-cell-1-0", in: app)
        XCTAssertTrue(bodyCell.waitForExistence(timeout: 5))
        if bodyCell.isHittable {
            bodyCell.tap()
        } else {
            let sourceEditor = app.textViews["markdown-editor"]
            let visible = bodyCell.frame.intersection(sourceEditor.frame)
            XCTAssertGreaterThan(visible.width, 20)
            XCTAssertGreaterThan(visible.height, 20)
            app.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(dx: visible.midX, dy: visible.midY)
            ).tap()
        }
        let editor = app.textViews["markdown.table.cell.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(editor.isHittable, "The native editor must occupy the active cell")
        XCTAssertGreaterThan(editor.frame.width, 20)
        XCTAssertGreaterThan(editor.frame.height, 20)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        return editor
    }

    private func switchToSource(in app: XCUIApplication) {
        let actions = app.buttons["notebook-note-actions"].firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        actions.tap()
        let source = app.buttons["Source"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        source.tap()
    }

    private func cell(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func toolbarButton(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let command = app.buttons[identifier].firstMatch
        let toolbar = app.collectionViews["editor-keyboard-toolbar"]
        XCTAssertTrue(toolbar.waitForExistence(timeout: 5))
        for _ in 0..<4 where !command.isHittable { toolbar.swipeRight() }
        for _ in 0..<8 where !command.isHittable { toolbar.swipeLeft() }
        XCTAssertTrue(command.isHittable, "Could not reveal \(identifier)")
        return command
    }

    private func tableCommand(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        toolbarButton("editor-table-menu", in: app).tap()
        let titles: [String: String] = [
            "editor-command-table-next-cell": "Next Cell",
            "editor-command-table-previous-cell": "Previous Cell",
            "editor-command-table-row-above": "Add Row Above",
            "editor-command-table-row-below": "Add Row Below",
            "editor-command-table-align-center": "Align Center",
            "editor-command-table-delete-row": "Delete Row",
            "editor-command-table-delete-column": "Delete Column",
        ]
        if identifier.contains("table-row-") || identifier == "editor-command-table-delete-row" {
            menuAction("Row", in: app).tap()
        } else if identifier.contains("table-column-") || identifier == "editor-command-table-delete-column" {
            menuAction("Column", in: app).tap()
        } else if identifier.contains("table-align-") {
            menuAction("Column Alignment", in: app).tap()
        }
        return menuAction(titles[identifier] ?? identifier, in: app)
    }

    private func cancelDeletion(in app: XCUIApplication, prompt: XCUIElement) {
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists { cancel.tap() }
        else {
            // UIKit presents this confirmation as a popover on iOS 27.
            // Its native cancellation is a tap on the surrounding backdrop.
            let point = app.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(dx: app.frame.midX, dy: max(app.frame.minY + 20, prompt.frame.minY - 30))
            )
            point.tap()
        }
        XCTAssertTrue(prompt.waitForNonExistence(timeout: 5))
    }

    private func menuAction(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let labels = [title, title + "…", title + "..."]
        let query = NSPredicate(format: "label IN %@", labels)
        let button = app.buttons.matching(query).firstMatch
        if button.waitForExistence(timeout: 2) { return button }
        if let menu = app.collectionViews.allElementsBoundByIndex.last(where: {
            $0.identifier != "editor-keyboard-toolbar" && $0.frame.width > 100
        }) {
            let keyboardTop = app.keyboards.firstMatch.frame.minY
            let visible = menu.frame.intersection(CGRect(
                x: app.frame.minX, y: app.frame.minY, width: app.frame.width,
                height: keyboardTop - app.frame.minY
            ))
            for upward in [true, true, true, true, false, false, false, false] {
                let origin = app.coordinate(withNormalizedOffset: .zero)
                let start = origin.withOffset(CGVector(
                    dx: visible.midX, dy: upward ? visible.maxY - 30 : visible.minY + 30
                ))
                let end = origin.withOffset(CGVector(
                    dx: visible.midX, dy: upward ? visible.minY + 30 : visible.maxY - 30
                ))
                start.press(forDuration: 0.05, thenDragTo: end)
                if button.exists { return button }
            }
        }
        let item = app.menuItems.matching(query).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 3), "Missing Table menu action \(title)")
        return item
    }

    private func waitForSource(_ editor: XCUIElement, where predicate: (String) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if let source = editor.value as? String, predicate(source) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return false
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
