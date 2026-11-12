import XCTest

/// Previews under notes in Files, and the Move sheet's search and recent
/// folders, in the fictional README notebook.
final class FilesPreviewAndMoveUITests: XCTestCase {
    func testPreviewsInFilesFollowTheSetting() throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launch()
        app.revealNotebookSidebar(timeout: 30)

        expandFolder(named: "Inbox", in: app)
        let groceries = itemID(named: "Groceries", in: app)
        let preview = app.staticTexts["notebook-sidebar-preview-" + groceries]
        XCTAssertFalse(preview.exists)

        app.openNotebookSettings(macTab: "Appearance")
        let toggle = previewsToggle(in: app)
        for _ in 0..<4 where !toggle.isHittable { scrollDown(in: app) }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        #if os(macOS)
        // The Mac reports no value for the switch; the preview line below
        // shows that it flipped.
        toggle.click()
        #else
        // The row's middle is its label, which doesn't flip the switch.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        #endif
        #if os(macOS)
        app.closeNotebookSettings()
        #else
        app.buttons["Done"].firstMatch.tap()
        #endif
        app.revealNotebookSidebar()

        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        waitForText("For Saturday: oat milk, lemons, coffee.", of: preview)

        // A note made from a template shows its first words, not the
        // template's headings.
        expandFolder(named: "Areas", in: app)
        let review = itemID(named: "Weekly review 2026-10-24", in: app)
        let reviewPreview = app.staticTexts["notebook-sidebar-preview-" + review]
        XCTAssertTrue(reviewPreview.waitForExistence(timeout: 10))
        waitForText("Lisbon is booked", of: reviewPreview, prefixOnly: true)
        capture(app, name: "Previews in Files")
    }

    func testMoveSearchOpensAFolderAndRemembersIt() throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launch()
        app.revealNotebookSidebar(timeout: 30)
        expandFolder(named: "Inbox", in: app)
        let groceries = itemID(named: "Groceries", in: app)

        openMoveSheet(forNote: groceries, in: app)
        let search = searchField(in: app)
        activate(search)
        search.typeText("temp")
        let result = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "notebook-move-search-result-"
        ))
        XCTAssertTrue(result.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(result.count, 1)
        let templates = result.firstMatch.identifier
            .replacingOccurrences(of: "notebook-move-search-result-", with: "")
        capture(app, name: "Move search")
        activate(result.firstMatch)

        let path = app.staticTexts["notebook-move-path"]
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        waitForText("Top Level / Resources / Templates", of: path)
        let confirm = app.buttons["notebook-confirm-move"]
        XCTAssertTrue(confirm.isEnabled)
        activate(confirm)
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 10))

        // Moving opens the destination, with the note inside it.
        let folderRow = app.descendants(matching: .any)["notebook-sidebar-folder-" + templates]
        let noteRow = app.descendants(matching: .any)["notebook-sidebar-note-" + groceries]
        scrollUntilExists(noteRow, in: app)
        XCTAssertTrue(folderRow.exists)
        XCTAssertEqual(
            app.descendants(matching: .any)["notebook-disclosure-" + templates].value as? String,
            "Expanded")
        XCTAssertGreaterThan(noteRow.frame.minY, folderRow.frame.minY)

        // The next move offers the folder under Recent.
        openMoveSheet(forNote: groceries, in: app)
        let recent = app.descendants(matching: .any)["notebook-move-recent-" + templates]
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        capture(app, name: "Move recent folders")
        activate(recent)
        waitForText("Top Level / Resources / Templates", of: path)
        activate(app.buttons["notebook-cancel-move"])
        XCTAssertTrue(path.waitForNonExistence(timeout: 5))
    }

    // MARK: Helpers

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] =
            "files-ui-\(UUID().uuidString)"
        app.launchEnvironment["MEH_NOTEBOOK_TEST_FIXTURE"] = "readme"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "source", "-AppleLanguages", "(en)"]
        return app
    }

    private func itemID(named name: String, in app: XCUIApplication) -> String {
        let title = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (label == %@ OR value == %@)",
            "notebook-sidebar-title-", name, name
        )).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "\(name) missing in Files")
        return title.identifier.replacingOccurrences(of: "notebook-sidebar-title-", with: "")
    }

    private func expandFolder(named name: String, in app: XCUIApplication) {
        let control = app.descendants(matching: .any)[
            "notebook-disclosure-" + itemID(named: name, in: app)]
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        if control.value as? String != "Expanded" { activate(control) }
    }

    private func openMoveSheet(forNote id: String, in app: XCUIApplication) {
        let row = app.descendants(matching: .any)["notebook-sidebar-note-" + id]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        #if os(macOS)
        row.rightClick()
        let move = app.menuItems["Move…"]
        XCTAssertTrue(move.waitForExistence(timeout: 5))
        move.click()
        #else
        app.chooseRowAction("Move…", on: row)
        #endif
        XCTAssertTrue(app.buttons["notebook-confirm-move"].waitForExistence(timeout: 5))
    }

    private func searchField(in app: XCUIApplication) -> XCUIElement {
        let field = app.searchFields.matching(NSPredicate(
            format: "placeholderValue == %@ OR label == %@", "Find a folder", "Find a folder"
        )).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        return field
    }

    private func previewsToggle(in app: XCUIApplication) -> XCUIElement {
        app.switches["notebook-appearance-file-previews"]
    }

    /// The Mac shows a static text's words as its value, iOS as its label.
    private func waitForText(
        _ expected: String, of element: XCUIElement, prefixOnly: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let predicate = NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            let text = (element.value as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? element.label
            return prefixOnly ? text.hasPrefix(expected) : text == expected
        }
        let result = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
            timeout: 10)
        if result != .completed {
            XCTFail("Expected “\(expected)”, found “\(element.label)”", file: file, line: line)
        }
    }

    private func scrollUntilExists(
        _ element: XCUIElement, in app: XCUIApplication,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for _ in 0..<5 where !element.waitForExistence(timeout: 2) {
            scrollDown(in: app)
        }
        XCTAssertTrue(element.exists, "Scrolled without finding \(element)", file: file, line: line)
    }

    private func scrollDown(in app: XCUIApplication) {
        #if os(macOS)
        app.windows.firstMatch.scroll(byDeltaX: 0, deltaY: -400)
        #else
        app.swipeUp()
        #endif
    }

    private func activate(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
