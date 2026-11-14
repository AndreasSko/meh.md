import XCTest

/// Folder pages in the fictional README notebook: a screen in iPhone's
/// Files, and the big side beside Files on iPad and the Mac.
final class FolderPagesUITests: XCTestCase {
    func testFolderPageOpensNotesAndNewNotesGoIntoIt() throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launch()
        app.revealNotebookSidebar(timeout: 30)

        let resources = itemID(named: "Resources", in: app)
        openFolderPage(named: "Resources", in: app)
        // The Mac reads a row as its value, iOS as its label.
        let packing = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (label BEGINSWITH %@ OR value BEGINSWITH %@)",
            "notebook-folder-page-note-", "Packing list", "Packing list"
        )).firstMatch
        XCTAssertTrue(packing.waitForExistence(timeout: 5))
        // The row reads its name and first words as one.
        let withPreview = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                   "Everything else can be bought",
                                   "Everything else can be bought"),
            object: packing)
        XCTAssertEqual(XCTWaiter().wait(for: [withPreview], timeout: 10), .completed)
        capture(app, name: "Folder page")

        activate(packing)
        XCTAssertTrue(app.textViews["markdown-editor"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.openNoteTitle, "Packing list")
        let pathPart = app.buttons["notebook-path-" + resources]
        XCTAssertTrue(pathPart.waitForExistence(timeout: 5))
        capture(app, name: "Path above the note")

        // The path leads back to the folder's page.
        activate(pathPart)
        waitForPageTitle("Resources", in: app)

        // New Note, the main button, puts the note into the page's folder.
        let newNote = app.newNoteButton
        XCTAssertTrue(newNote.waitForExistence(timeout: 5))
        activate(newNote)
        XCTAssertTrue(app.textFields["title-field"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["notebook-path-" + resources].waitForExistence(timeout: 5))
    }

    func testEachFolderKeepsItsView() throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launch()
        app.revealNotebookSidebar(timeout: 30)

        openFolderPage(named: "Inbox", in: app)
        chooseView("Cards", in: app)
        let card = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "notebook-folder-page-card-"
        )).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        capture(app, name: "Cards")

        // Switching between Cards and List leaves the title in place. Beside
        // iPad's Files a List row reports its frame from the column, not the
        // screen.
        let title = app.staticTexts["notebook-folder-page-title"]
        let cardsTitle = title.frame
        chooseView("List", in: app)
        let row = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "notebook-folder-page-note-"
        )).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertFalse(card.exists)
        let checksX = !isIPadBesideFiles(app)
        let inPlace = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(title.frame.minY - cardsTitle.minY) <= 1
                && (!checksX || abs(title.frame.minX - cardsTitle.minX) <= 1)
        }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [inPlace], timeout: 5), .completed,
                       "Title moved from \(cardsTitle) to \(title.frame)")
        capture(app, name: "List")
        chooseView("Cards", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 5))

        openFolderPage(named: "Areas", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertFalse(card.exists)

        openFolderPage(named: "Inbox", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 5))

        // A card opens its note.
        activate(card)
        XCTAssertTrue(app.textViews["markdown-editor"].waitForExistence(timeout: 10))
    }

    /// On iPhone Files is behind the page, so a new folder's name field
    /// must be on the page, in Cards too.
    func testIPhoneNamesANewFolderOnACardsPage() throws {
        #if os(iOS)
        continueAfterFailure = false
        let app = makeApp()
        app.launch()
        app.revealNotebookSidebar(timeout: 30)
        try XCTSkipUnless(isCompact(app), "iPhone's Files only")

        openFolderPage(named: "Inbox", in: app)
        chooseView("Cards", in: app)
        activate(app.buttons["notebook-folder-page-actions"])
        let newFolder = app.buttons.matching(NSPredicate(format: "label == %@", "New Folder"))
            .allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(newFolder)
        newFolder?.tap()
        let field = app.textFields["notebook-folder-page-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(field.isHittable)
        field.typeText(" Receipts\n")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "notebook-folder-page-folder-", "Receipts"
        )).firstMatch.waitForExistence(timeout: 5))
        #else
        throw XCTSkip("iPhone only")
        #endif
    }

    func testIPhoneShowInFilesLeavesThePages() throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launch()
        app.revealNotebookSidebar(timeout: 30)
        try XCTSkipUnless(isCompact(app), "iPhone's Files only")

        openFolderPage(named: "Inbox", in: app)
        let groceries = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
            "notebook-folder-page-note-", "Groceries"
        )).firstMatch
        XCTAssertTrue(groceries.waitForExistence(timeout: 5))
        activate(groceries)
        XCTAssertTrue(app.textViews["markdown-editor"].waitForExistence(timeout: 10))
        activate(app.buttons["notebook-note-actions"])
        activate(app.buttons["Show in Files"])
        XCTAssertTrue(app.buttons["notebook-tree-toggle"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["notebook-folder-page"].exists)
    }

    func testPageBesideFilesClosesBackToTheNote() throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launch()
        app.revealNotebookSidebar(timeout: 30)
        try XCTSkipIf(isCompact(app), "Beside Files only")

        let review = itemID(named: "Weekly review 2026-10-24", in: app, expanding: "Areas")
        activate(app.staticTexts["notebook-sidebar-title-" + review])
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        activate(editor)
        editor.typeText("Alpha")

        openFolderPage(named: "Inbox", in: app)
        let close = app.buttons["notebook-folder-page-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        capture(app, name: "Page beside Files")
        #if os(macOS)
        app.typeKey(.escape, modifierFlags: [])
        #else
        activate(close)
        #endif
        XCTAssertTrue(app.descendants(matching: .any)["notebook-folder-page"]
            .waitForNonExistence(timeout: 5))
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(app.openNoteTitle, "Weekly review 2026-10-24")

        // The note has the keyboard again, with the caret where it was.
        app.typeText("Bravo")
        let typed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "AlphaBravo"), object: editor)
        XCTAssertEqual(XCTWaiter().wait(for: [typed], timeout: 10), .completed)

        #if os(macOS)
        // Keys while a page shows must not reach the note underneath.
        openFolderPage(named: "Inbox", in: app)
        app.typeText("Zulu")
        activate(close)
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertFalse((editor.value as? String ?? "").contains("Zulu"))
        #endif
    }

    func testMacCommandClickSelectsPageRowsWithoutOpeningThem() throws {
        #if os(macOS)
        continueAfterFailure = false
        let app = makeApp()
        app.launch()
        openFolderPage(named: "Inbox", in: app)
        let rows = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "notebook-folder-page-note-"))
        XCTAssertTrue(rows.element(boundBy: 1).waitForExistence(timeout: 5))
        let first = rows.element(boundBy: 0)
        let second = rows.element(boundBy: 1)
        XCUIElement.perform(withKeyModifiers: .command) { first.click() }
        XCUIElement.perform(withKeyModifiers: .command) { second.click() }
        // Opening a note would close the page.
        XCTAssertTrue(app.descendants(matching: .any)["notebook-folder-page"].exists)

        second.rightClick()
        // The menu bar has the same command; pick the context menu's.
        let items = app.menuItems.matching(NSPredicate(format: "title == %@", "Move Selected…"))
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 5))
        let moveSelected = items.allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(moveSelected)
        moveSelected?.click()
        let source = app.staticTexts["notebook-move-source"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertEqual(source.text, "2 items")
        #else
        throw XCTSkip("⌘-click selects rows on the Mac")
        #endif
    }

    func testDraggingSelectedRowsOntoAFolderOfThePageMovesThem() throws {
        try dragSelectedNotesOntoAFolder(view: "List")
    }

    func testDraggingSelectedCardsOntoAFolderOfThePageMovesThem() throws {
        try dragSelectedNotesOntoAFolder(view: "Cards")
    }

    /// On iPhone the page covers Files, so its own folders take the drop.
    private func dragSelectedNotesOntoAFolder(view: String) throws {
        #if os(iOS)
        continueAfterFailure = false
        let app = makeApp()
        app.launch()
        app.revealNotebookSidebar(timeout: 30)
        let templates = itemID(named: "Templates", in: app, expanding: "Resources")
        openFolderPage(named: "Resources", in: app)
        chooseView(view, in: app)

        func pageNote(_ name: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(
                format: "(identifier BEGINSWITH %@ OR identifier BEGINSWITH %@) AND label BEGINSWITH %@",
                "notebook-folder-page-note-", "notebook-folder-page-card-", name
            )).firstMatch
        }
        let actions = app.buttons["notebook-folder-page-actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        actions.tap()
        let select = app.buttons["notebook-folder-page-select"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        select.tap()
        let packing = pageNote("Packing list")
        let book = pageNote("Book notes")
        XCTAssertTrue(packing.waitForExistence(timeout: 5))
        packing.tap()
        book.tap()
        XCTAssertTrue(app.staticTexts["2 selected"].waitForExistence(timeout: 5))

        let folder = app.descendants(matching: .any)["notebook-folder-page-folder-" + templates]
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        book.press(
            forDuration: 1.0, thenDragTo: folder, withVelocity: .slow,
            thenHoldForDuration: 0.8)
        XCTAssertTrue(book.waitForNonExistence(timeout: 10), "Book notes stayed on the page")
        XCTAssertFalse(packing.exists, "The other selected note stayed")

        app.buttons["notebook-folder-page-done"].tap()
        folder.tap()
        waitForPageTitle("Templates", in: app)
        XCTAssertTrue(pageNote("Book notes").waitForExistence(timeout: 5))
        XCTAssertTrue(pageNote("Packing list").exists)
        #else
        throw XCTSkip("The Mac drags with AppKit")
        #endif
    }

    func testMacDraggingFromAPageMovesNotesIntoAFolder() throws {
        #if os(macOS)
        continueAfterFailure = false
        let app = makeApp()
        app.launch()
        let projects = itemID(named: "Projects", in: app)
        let archive = itemID(named: "Archive", in: app)
        openFolderPage(named: "Inbox", in: app)

        func pageNote(_ name: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(
                format: "(identifier BEGINSWITH %@ OR identifier BEGINSWITH %@) "
                    + "AND (label BEGINSWITH %@ OR value BEGINSWITH %@)",
                "notebook-folder-page-note-", "notebook-folder-page-card-", name, name
            )).firstMatch
        }
        func dragNote(_ name: String, onto folder: String) {
            let source = pageNote(name)
            XCTAssertTrue(source.waitForExistence(timeout: 5), "\(name) missing on the page")
            let target = app.staticTexts["notebook-sidebar-title-" + folder]
            XCTAssertTrue(target.waitForExistence(timeout: 5))
            source.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).click(
                forDuration: 0.15,
                thenDragTo: target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                withVelocity: .slow, thenHoldForDuration: 0.5)
            XCTAssertTrue(source.waitForNonExistence(timeout: 10), "\(name) stayed on the page")
        }

        // A row of the list, then a card.
        dragNote("Groceries", onto: projects)
        chooseView("Cards", in: app)
        dragNote("Call landlord", onto: archive)
        XCTAssertTrue(app.descendants(matching: .any)["notebook-folder-page-empty"]
            .waitForExistence(timeout: 5))
        // Each note arrived in its folder.
        openFolderPage(named: "Projects", in: app)
        XCTAssertTrue(pageNote("Groceries").waitForExistence(timeout: 5))
        openFolderPage(named: "Archive", in: app)
        XCTAssertTrue(pageNote("Call landlord").waitForExistence(timeout: 5))
        #else
        throw XCTSkip("Mac drags")
        #endif
    }

    func testTrashingTheFolderClosesItsPage() throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launch()
        app.revealNotebookSidebar(timeout: 30)
        try XCTSkipIf(isCompact(app), "Beside Files only")

        let review = itemID(named: "Weekly review 2026-10-24", in: app, expanding: "Areas")
        activate(app.staticTexts["notebook-sidebar-title-" + review])
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))

        let archive = itemID(named: "Archive", in: app)
        openFolderPage(named: "Archive", in: app)
        let row = app.descendants(matching: .any)["notebook-sidebar-folder-" + archive]
        #if os(macOS)
        row.rightClick()
        let trash = app.menuItems.matching(NSPredicate(format: "title == %@", "Move to Trash"))
            .allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(trash)
        trash?.click()
        #else
        app.chooseRowAction("Move to Trash", on: row)
        #endif
        XCTAssertTrue(app.descendants(matching: .any)["notebook-folder-page"]
            .waitForNonExistence(timeout: 10))
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(app.openNoteTitle, "Weekly review 2026-10-24")
        activate(editor)
        editor.typeText("Charlie")
        let typed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "Charlie"), object: editor)
        XCTAssertEqual(XCTWaiter().wait(for: [typed], timeout: 10), .completed)
    }

    /// A large iPhone shows Files beside the note in landscape. Turning it
    /// upright must give the note back, with the page one Back away.
    func testIPhoneRotationMovesThePageIntoFiles() throws {
        #if os(iOS)
        continueAfterFailure = false
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "Rotates an iPhone")
        let app = makeApp()
        let editor = app.textViews["markdown-editor"]
        let placeholder = app.descendants(matching: .any)["notebook-empty-detail"]
        let recent = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Weekly review 2026-10-24")).firstMatch
        // Recents would push Files below the short landscape screen.
        let recents = app.buttons["notebook-recents-toggle"]
        let inbox = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@",
            "notebook-sidebar-title-", "Inbox")).firstMatch
        let title = app.descendants(matching: .any)["notebook-folder-page-title"]
        let back = app.navigationBars.buttons.element(boundBy: 0)
        var besideFiles = false
        var steps: [String] = []
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        // Once a test turns the device, XCTest never hears that animations
        // finished and waits a minute before every step; wait explicitly.
        // Launching inside this block would turn the waits back on.
        app.withoutIdleWait {
            XCUIDevice.shared.orientation = .landscapeLeft
            defer { XCUIDevice.shared.orientation = .portrait }
            besideFiles = placeholder.waitForExistence(timeout: 10)
            guard besideFiles else { return }
            guard recent.waitForExistence(timeout: 5) else { return steps.append("recent") }
            recent.tap()
            guard editor.waitForExistence(timeout: 10),
                  recents.waitForExistence(timeout: 5) else { return steps.append("note") }
            recents.tap()
            guard inbox.waitForExistence(timeout: 5) else { return steps.append("inbox") }
            inbox.tap()
            guard title.waitForExistence(timeout: 10) else { return steps.append("page") }

            XCUIDevice.shared.orientation = .portrait
            guard editor.waitForExistence(timeout: 10) else { return steps.append("upright") }
            editor.tap()
            editor.typeText("Delta")
            let typed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value CONTAINS %@", "Delta"), object: editor)
            guard XCTWaiter().wait(for: [typed], timeout: 10) == .completed
            else { return steps.append("typing") }
            back.tap()
            guard title.waitForExistence(timeout: 10) else { return steps.append("back") }
        }
        try XCTSkipUnless(besideFiles, "This iPhone shows no Files beside the note in landscape")
        XCTAssertEqual(steps, [], "Stopped at: \(steps)")
        #else
        throw XCTSkip("Rotates an iPhone")
        #endif
    }

    func testIPhoneBackReturnsToWherePagesWereOpened() throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launch()
        app.revealNotebookSidebar(timeout: 30)
        try XCTSkipUnless(isCompact(app), "iPhone's Files only")
        let page = app.descendants(matching: .any)["notebook-folder-page"]
        let back = app.navigationBars.buttons.element(boundBy: 0)

        // A nested folder opened from Files is one page.
        activate(app.staticTexts["notebook-sidebar-title-"
            + itemID(named: "Templates", in: app, expanding: "Resources")])
        waitForPageTitle("Templates", in: app)
        back.tap()
        XCTAssertTrue(page.waitForNonExistence(timeout: 5))

        // A folder opened from a page goes on top of it, and the edge swipe
        // goes back like Back.
        openFolderPage(named: "Resources", in: app)
        let templates = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@",
            "notebook-folder-page-folder-", "Templates"
        )).firstMatch
        XCTAssertTrue(templates.waitForExistence(timeout: 5))
        activate(templates)
        waitForPageTitle("Templates", in: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5)).press(
            forDuration: 0.05,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        waitForPageTitle("Resources", in: app)
        back.tap()
        XCTAssertTrue(page.waitForNonExistence(timeout: 5))

        // Top Level goes home from any depth.
        openFolderPage(named: "Resources", in: app)
        activate(templates)
        waitForPageTitle("Templates", in: app)
        let topLevel = app.buttons["notebook-path-top-level"]
        XCTAssertTrue(topLevel.waitForExistence(timeout: 5))
        activate(topLevel)
        XCTAssertTrue(page.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["notebook-tree-toggle"].waitForExistence(timeout: 5))
    }

    // MARK: Helpers

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] =
            "folder-pages-ui-\(UUID().uuidString)"
        app.launchEnvironment["MEH_NOTEBOOK_TEST_FIXTURE"] = "readme"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "source", "-AppleLanguages", "(en)"]
        return app
    }

    private func isIPadBesideFiles(_ app: XCUIApplication) -> Bool {
        #if os(macOS)
        false
        #else
        !isCompact(app)
        #endif
    }

    private func isCompact(_ app: XCUIApplication) -> Bool {
        #if os(macOS)
        false
        #else
        app.windows.firstMatch.frame.width < 600
        #endif
    }

    private func itemID(
        named name: String, in app: XCUIApplication, expanding folder: String? = nil
    ) -> String {
        if let folder {
            let control = app.descendants(matching: .any)[
                "notebook-disclosure-" + itemID(named: folder, in: app)]
            XCTAssertTrue(control.waitForExistence(timeout: 5))
            if control.value as? String != "Expanded" { activate(control) }
        }
        let title = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (label == %@ OR value == %@)",
            "notebook-sidebar-title-", name, name
        )).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "\(name) missing in Files")
        return title.identifier.replacingOccurrences(of: "notebook-sidebar-title-", with: "")
    }

    /// A tap on a folder's name in Files opens its page.
    private func openFolderPage(named name: String, in app: XCUIApplication) {
        if isCompact(app), app.descendants(matching: .any)["notebook-folder-page"].exists {
            activate(app.buttons["notebook-path-top-level"])
        }
        let title = app.staticTexts["notebook-sidebar-title-" + itemID(named: name, in: app)]
        activate(title)
        waitForPageTitle(name, in: app)
    }

    private func waitForPageTitle(_ name: String, in app: XCUIApplication) {
        // The Mac shows a static text's words as its label or its value.
        let title = app.descendants(matching: .any)["notebook-folder-page-title"]
        let named = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@ OR value == %@", name, name),
            object: title)
        XCTAssertEqual(XCTWaiter().wait(for: [named], timeout: 10), .completed,
                       "Page of \(name) missing")
    }

    private func chooseView(_ name: String, in app: XCUIApplication) {
        let picker = app.descendants(matching: .any)["notebook-folder-view"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        #if os(macOS)
        let segment = picker.radioButtons[name].exists ? picker.radioButtons[name]
            : picker.buttons[name]
        #else
        let segment = picker.buttons[name]
        #endif
        XCTAssertTrue(segment.waitForExistence(timeout: 5))
        activate(segment)
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
