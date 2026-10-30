import XCTest

final class NotebookLinksUITests: XCTestCase {
    func testWikiLinkCompletionInsertsCompleteLink() throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launch()

        createNote(
            in: app,
            title: "Fictional Project",
            body: "# Next steps\n\nReview the sample plan."
        )
        // Taking the suggestion must replace the partial token with a
        // complete link.
        createNote(in: app, title: "Fictional Link Draft", body: "See [[Fictional")
        let suggestion = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "link-suggestion-", "Fictional Project"
            )
        ).firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 10))
        XCTAssertTrue(suggestion.isHittable)
#if os(iOS)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
#endif
        activate(suggestion)
        let draft = app.textViews["markdown-editor"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        XCTAssertTrue(
            (draft.value as? String ?? "").contains("[[Fictional Project]]"),
            "Selecting a completion should insert a complete wiki link; "
                + "draft was: \(draft.value as? String ?? "<unavailable>")"
        )
    }

#if os(iOS)
    func testWikiNavigationAndBacklinks() throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launch()

        createNote(
            in: app,
            title: "Fictional Project",
            body: "# Next steps\n\nReview the sample plan."
        )
        createNote(
            in: app,
            title: "Fictional Meeting",
            body: "See [[Fictional Project#Next steps|the project]]."
        )

        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        assertTitle("Fictional Meeting", in: app)

        // Reopen from Files to establish passive reading rather than depending
        // on the swipe distance needed to dismiss a short note's keyboard.
        activate(app.buttons["notebook-note-actions"])
        activate(app.buttons["notebook-show-in-files"])
        let meetingRow = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@",
            "notebook-sidebar-title-", "Fictional Meeting"
        )).firstMatch
        XCTAssertTrue(meetingRow.waitForExistence(timeout: 5))
        activate(meetingRow)
        // The selected editor can retain editing focus when its own Files row
        // is reopened. Relaunch also verifies the saved literal link survives.
        app.terminate()
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        assertTitle("Fictional Meeting", in: app)
        let keyboardHidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.keyboards.firstMatch
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [keyboardHidden], timeout: 5), .completed,
            "The editor should be passive before following a rendered link"
        )

        // The short fixture places its link near the beginning of the editor.
        followFixtureLink(in: app)
        assertTitle("Fictional Project", in: app)
        XCTAssertFalse(app.keyboards.firstMatch.exists)

        XCTAssertFalse(app.buttons["note-link-forward"].exists)
        goBack(from: app, returningTo: "Fictional Meeting")
        assertTitle("Fictional Meeting", in: app)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        followFixtureLink(in: app)
        assertTitle("Fictional Project", in: app)

        let actions = app.buttons["notebook-note-actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        activate(actions)
        let backlinksAction = app.buttons["notebook-backlinks"]
        XCTAssertTrue(backlinksAction.waitForExistence(timeout: 5))
        activate(backlinksAction)
        let backlink = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "backlink-")
        ).firstMatch
        XCTAssertTrue(backlink.waitForExistence(timeout: 10))
        XCTAssertTrue(backlink.label.contains("the project"))
        activate(app.buttons["Done"])
        goBack(from: app, returningTo: "Fictional Meeting")
        assertTitle("Fictional Meeting", in: app)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertFalse(app.buttons["note-link-forward"].exists)

        // Backlinks are target-scoped. Reopening the sheet for a note with no
        // incoming links must not briefly show the previous target's result.
        activate(actions)
        activate(backlinksAction)
        let noLinks = app.staticTexts["No linked notes"]
        XCTAssertTrue(noLinks.waitForExistence(timeout: 10))
        XCTAssertFalse(backlink.exists)
        activate(app.buttons["Done"])
    }

    func testCompactBackTransitionKeepsNoteContent() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        continueAfterFailure = false
        let app = makeApp()
        app.launch()
        createNote(in: app, title: "Fictional Project",
                   body: "# Next steps\n\nReview the sample plan.")
        createNote(in: app, title: "Fictional Meeting",
                   body: "See [[Fictional Project#Next steps|the project]].")
        // Leave normally to flush the new note before terminating the app.
        // Killing the fixture immediately after typing can discard its
        // pending save and leave no link for the transition check.
        activate(app.buttons["notebook-note-actions"])
        activate(app.buttons["notebook-show-in-files"])
        let meeting = fileRow("Fictional Meeting", in: app)
        XCTAssertTrue(meeting.waitForExistence(timeout: 10))
        activate(meeting)
        app.terminate()
        // Use a wrapped title for the transition without changing the
        // generated-title field while the fixtures are being created.
        app.launchArguments += ["-editor.fontFamily", "monospaced", "-editor.fontSize", "20"]
        app.launch()
        assertTitle("Fictional Meeting", in: app)
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String,
                       "See [[Fictional Project#Next steps|the project]].")
        let keyboardHidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.keyboards.firstMatch
        )
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardHidden], timeout: 5), .completed)
        let originalTitleY = app.buttons["note-title"].frame.minY

        followFixtureLink(in: app)
        assertTitle("Fictional Project", in: app)
        swipeBackFromLeadingEdge(in: app, slowly: true)
        assertTitle("Fictional Meeting", in: app)
        XCTAssertEqual(app.buttons["note-title"].frame.minY, originalTitleY, accuracy: 1,
                       "Returning should preserve the note's vertical position")
        XCTAssertEqual(editor.value as? String,
                       "See [[Fictional Project#Next steps|the project]].")
        XCTAssertFalse(app.searchFields.firstMatch.exists,
                       "Back through a link should remain in the note detail")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
    }

    func testCompactScrolledLinkOpeningKeepsVisitPosition() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        continueAfterFailure = false
        let app = makeApp()
        app.launch()

        let longBody = (0..<30).map { index in
            if index == 0 { return "TOP POSITION MARKER" }
            if index == 15 {
                return "[[Fictional Project|OPEN PROJECT FROM MIDPOINT]]\n\n"
                    + "MID POSITION MARKER"
            }
            if index == 29 { return "BOTTOM POSITION MARKER" }
            return "Paragraph \(index): This fictional passage gives the "
                + "source enough height for a stable middle scroll anchor."
        }.joined(separator: "\n\n")
        createNote(in: app, title: "Fictional Long Source", body: longBody)
        createNote(
            in: app,
            title: "Fictional Project",
            body: "See [[Fictional Long Source|return to observations]]."
        )

        activate(app.buttons["notebook-note-actions"])
        activate(app.buttons["notebook-show-in-files"])
        let project = fileRow("Fictional Project", in: app)
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        activate(project)
        app.terminate()
        app.launch()

        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        assertTitle("Fictional Project", in: app)
        XCTAssertEqual(
            editor.value as? String,
            "See [[Fictional Long Source|return to observations]]."
        )
        let keyboardHidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.keyboards.firstMatch
        )
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardHidden], timeout: 5), .completed)

        activate(app.buttons["notebook-note-actions"])
        activate(app.buttons["notebook-backlinks"])
        let backlink = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "backlink-")
        ).firstMatch
        XCTAssertTrue(backlink.waitForExistence(timeout: 10))
        XCTAssertTrue(backlink.label.contains("OPEN PROJECT FROM MIDPOINT"))
        activate(backlink)

        assertTitle("Fictional Long Source", in: app)
        XCTAssertEqual(editor.value as? String, longBody)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        let sourceTitle = app.buttons["note-title"]
        waitForScrollToSettle(sourceTitle)
        let sourceTitleY = sourceTitle.frame.minY

        // Leave the scrolled source through its own incoming link.
        activate(app.buttons["notebook-note-actions"])
        activate(app.buttons["notebook-backlinks"])
        XCTAssertTrue(backlink.waitForExistence(timeout: 10))
        XCTAssertTrue(backlink.label.contains("return to observations"))
        activate(backlink)
        assertTitle("Fictional Project", in: app)
        XCTAssertFalse(app.keyboards.firstMatch.exists)

        goBack(from: app, returningTo: "Fictional Long Source")
        assertTitle("Fictional Long Source", in: app)
        XCTAssertEqual(sourceTitle.frame.minY, sourceTitleY, accuracy: 1)
        XCTAssertEqual(editor.value as? String, longBody)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
    }

    func testCompactBackReturnsToFilesAndManualSelectionResetsLinkChain() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        continueAfterFailure = false
        let app = makeApp()
        app.launch()

        createNote(
            in: app,
            title: "Fictional Project",
            body: "# Next steps\n\nReview the sample plan."
        )
        createNote(
            in: app,
            title: "Fictional Meeting",
            body: "See [[Fictional Project#Next steps|the project]]."
        )
        createNote(
            in: app,
            title: "Fictional Unrelated",
            body: "An independent note."
        )

        goBack(from: app, returningTo: "Files")
        XCTAssertFalse(app.textViews["markdown-editor"].exists)
        let meetingRow = fileRow("Fictional Meeting", in: app)
        XCTAssertTrue(meetingRow.waitForExistence(timeout: 10))
        activate(meetingRow)
        assertTitle("Fictional Meeting", in: app)
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        app.terminate()
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        assertTitle("Fictional Meeting", in: app)
        let keyboardHidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.keyboards.firstMatch
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [keyboardHidden], timeout: 5), .completed,
            "Relaunching the preview should leave the editor passive"
        )

        followFixtureLink(in: app)
        assertTitle("Fictional Project", in: app)
        XCTAssertFalse(app.buttons["note-link-forward"].exists)
        goBack(from: app, returningTo: "Fictional Meeting")
        assertTitle("Fictional Meeting", in: app)

        goBack(from: app, returningTo: "Files")
        XCTAssertFalse(app.textViews["markdown-editor"].exists)
        let restoredMeetingRow = fileRow("Fictional Meeting", in: app)
        XCTAssertTrue(restoredMeetingRow.waitForExistence(timeout: 10))

        let unrelatedRow = fileRow("Fictional Unrelated", in: app)
        XCTAssertTrue(unrelatedRow.waitForExistence(timeout: 10))
        activate(unrelatedRow)
        assertTitle("Fictional Unrelated", in: app)
        XCTAssertFalse(app.buttons["note-link-forward"].exists)
        goBack(from: app, returningTo: "Files")
        XCTAssertFalse(app.textViews["markdown-editor"].exists)
        XCTAssertTrue(fileRow("Fictional Unrelated", in: app).exists)
    }

    func testCompactInlineRenameResetsLinkedNoteBackRoute() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        continueAfterFailure = false
        let app = makeApp()
        app.launch()

        createNote(
            in: app,
            title: "Fictional Project",
            body: "# Next steps\n\nReview the sample plan."
        )
        createNote(
            in: app,
            title: "Fictional Meeting",
            body: "See [[Fictional Project#Next steps|the project]]."
        )

        activate(app.buttons["notebook-note-actions"])
        activate(app.buttons["notebook-show-in-files"])
        let meeting = fileRow("Fictional Meeting", in: app)
        XCTAssertTrue(meeting.waitForExistence(timeout: 10))
        activate(meeting)
        app.terminate()
        app.launch()
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        assertTitle("Fictional Meeting", in: app)
        let keyboardHidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.keyboards.firstMatch
        )
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardHidden], timeout: 5), .completed)

        followFixtureLink(in: app)
        assertTitle("Fictional Project", in: app)
        activate(app.buttons["notebook-note-actions"])
        activate(app.buttons["notebook-show-in-files"])
        renameFileRow(in: app, from: "Fictional Project", to: "Renamed Project")
        goBack(from: app, returningTo: "Files")
        XCTAssertFalse(editor.exists)
        XCTAssertTrue(fileRow("Renamed Project", in: app).exists)
        XCTAssertTrue(fileRow("Fictional Meeting", in: app).exists)

        // Directly selecting an unrelated note creates a root-only journey;
        // renaming it from Files should also reopen with Files as Back.
        activate(fileRow("Fictional Meeting", in: app))
        assertTitle("Fictional Meeting", in: app)
        activate(app.buttons["notebook-note-actions"])
        activate(app.buttons["notebook-show-in-files"])
        renameFileRow(in: app, from: "Fictional Meeting", to: "Renamed Meeting")
        goBack(from: app, returningTo: "Files")
        XCTAssertFalse(editor.exists)
        XCTAssertTrue(fileRow("Renamed Meeting", in: app).exists)
    }
#endif

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] =
            "links-\(UUID().uuidString)"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "livePreview"]
        return app
    }

    private func createNote(
        in app: XCUIApplication, title: String, body: String
    ) {
        let newNote = app.buttons["notebook-new-item"].firstMatch
        XCTAssertTrue(newNote.waitForExistence(timeout: 15))
        activate(newNote)
        let titleField = app.textFields["title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 10))
#if os(iOS)
        titleField.tap()
        let existing = titleField.value as? String ?? ""
        titleField.typeText(
            String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count + 4)
        )
        titleField.typeText(title)
        if titleField.value as? String != title {
            // Initial title focus can finish selecting the generated date
            // during the first clear. Reset once against the settled value.
            let current = titleField.value as? String ?? ""
            titleField.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            titleField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                                      count: current.count + 4))
            titleField.typeText(title)
        }
        XCTAssertEqual(titleField.value as? String, title)
        titleField.typeText("\n")
#else
        titleField.typeKey("a", modifierFlags: .command)
        titleField.typeText(title)
        titleField.typeKey(.return, modifierFlags: [])
#endif
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        assertTitle(title, in: app)
        editor.typeText(body)
        XCTAssertEqual(editor.value as? String, body)
    }

    private func activate(_ element: XCUIElement) {
#if os(macOS)
        element.click()
#else
        element.tap()
#endif
    }

    private func goBack(
        from app: XCUIApplication, returningTo expectedTitle: String
    ) {
#if os(macOS)
        let back = app.buttons["note-link-back"]
#else
        let back = app.navigationBars.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label CONTAINS[c] %@"
                    + " OR label == %@",
                expectedTitle, "Back", "meh.md"
            )
        ).firstMatch
#endif
        XCTAssertTrue(
            back.waitForExistence(timeout: 10),
            "Expected Back navigation returning to \(expectedTitle)"
        )
        activate(back)
    }

    private func followFixtureLink(in app: XCUIApplication) {
        // "See the project." starts at the title's left edge; the link spans
        // about 35–115 pt from there. A share of the title's width would miss
        // it on iPad, where the title is wider.
        let title = app.buttons["note-title"]
        let linkPoint = title.coordinate(
            withNormalizedOffset: CGVector(dx: 0, dy: 1)
        ).withOffset(CGVector(dx: 75, dy: 26))
        linkPoint.tap()
    }

#if os(iOS)
    private func waitForScrollToSettle(_ element: XCUIElement) {
        var lastY = element.frame.minY
        var stableSamples = 0
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let y = element.frame.minY
                stableSamples = abs(y - lastY) <= 0.5 ? stableSamples + 1 : 0
                lastY = y
                return stableSamples >= 2
            }, object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [settled], timeout: 10), .completed,
            "Wait for scroll inertia to settle"
        )
    }

    private func fileRow(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@",
            "notebook-sidebar-title-", title
        )).firstMatch
    }

    private func renameFileRow(
        in app: XCUIApplication, from oldTitle: String, to newTitle: String
    ) {
        let row = fileRow(oldTitle, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.press(forDuration: 1.0)
        let rename = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Rename"
        )).firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        activate(rename)

        let name = app.textFields["notebook-inline-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let existingName = name.value as? String ?? ""
        XCTAssertFalse(existingName.isEmpty)
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                             count: existingName.count + 4))
        name.typeText(newTitle + "\n")
        assertTitle(newTitle, in: app)
        XCTAssertTrue(app.textViews["markdown-editor"].waitForExistence(timeout: 10))
    }

    private func swipeBackFromLeadingEdge(in app: XCUIApplication, slowly: Bool = false) {
        let start = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5)
        )
        let end = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)
        )
        if slowly {
            start.press(forDuration: 0.05, thenDragTo: end,
                        withVelocity: .slow, thenHoldForDuration: 0.6)
        } else {
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }
#endif

    private func assertTitle(
        _ title: String, in app: XCUIApplication,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let titleButton = app.buttons["note-title"]
        let expectedTitle = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", title),
            object: titleButton
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectedTitle], timeout: 10), .completed,
            "Expected the selected note to be titled \(title)",
            file: file, line: line
        )
    }

}
