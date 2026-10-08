import XCTest

final class NotebookSearchUITests: XCTestCase {
    func testGlobalSearchFindsAndOpensBodyMatch() throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launch()

        let marker = "quasar-\(UUID().uuidString.prefix(8))"
        let title = "Fictional Observatory"
        let body = String(repeating: "Earlier observation.\n", count: 30)
            + "A quiet \(marker) passes Mars.\n"
            + String(repeating: "Later observation.\n", count: 30)
        createNote(in: app, title: title, body: body)
        showSidebar(in: app)
        capture(app, name: "Fictional notebook library before search")

#if os(iOS)
        if app.frame.width < 600 {
            let menu = app.buttons["notebook-app-menu"]
            XCTAssertTrue(menu.waitForExistence(timeout: 5))
            menu.tap()
            XCTAssertFalse(
                app.buttons["Quick Open…"].exists,
                "Quick Open should stay a keyboard command on compact layouts"
            )
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        }
#endif

        let search = revealGlobalSearch(in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        XCTAssertTrue(
            search.placeholderValue == "Search all notes"
                || search.label == "Search all notes"
        )
        activate(search)
        search.typeText(marker)
        XCTAssertFalse(app.staticTexts["Preparing search…"].exists)

        let result = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "search-result-")
        ).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertTrue(result.label.contains(title))
        capture(app, name: "Global search with a fictional body match")
        activate(result)
        XCTAssertTrue(app.textViews["markdown-editor"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["note-title"].label, title)
        let keyboardHidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.keyboards.firstMatch
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [keyboardHidden], timeout: 3), .completed,
            "Opening a search result must dismiss search focus"
        )
        capture(app, name: "Search result opened without editing focus")
    }

    func testFindInNoteOpensNativeFind() throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launch()
        createNote(
            in: app,
            title: "Fictional Field Log",
            body: """
            Fictional Field Log

            18 September — North ridge
            A lantern crosses the valley before sunrise.
            Trail conditions: dry stone, light wind.
            Supplies: water, notebook, wool gloves.
            Follow the ridge past the old shelter.

            19 September — Forest path
            The lantern marks the turn toward the river.
            Cloud cover clears shortly after noon.
            Record the bridge and the narrow crossing.
            Leave enough time for the return walk.

            20 September — Quiet campsite
            A lantern hangs beside the fictional camp.
            Pack the tent after the morning dew dries.
            Check the route before climbing the hill.
            Return to the valley by late afternoon.
            """
        )

        #if os(macOS)
        let actions = app.menuButtons["notebook-note-actions"]
        #else
        let actions = app.buttons["notebook-note-actions"]
        #endif
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        activate(actions)
        let find = app.descendants(matching: .any)
            .matching(identifier: "notebook-find").firstMatch
        XCTAssertTrue(find.waitForExistence(timeout: 10))
        activate(find)
        #if os(macOS)
        // The global search remains in the toolbar while AppKit opens Find.
        let findField = app.searchFields.matching(
            NSPredicate(format: "placeholderValue == %@", "Find")
        ).firstMatch
        #else
        let findField = app.searchFields.firstMatch.exists
            ? app.searchFields.firstMatch : app.textFields.firstMatch
        #endif
        XCTAssertTrue(
            findField.waitForExistence(timeout: 5),
            "Expected the native Find field"
        )
        findField.typeText("lantern")
        #if os(macOS)
        findField.typeKey(.return, modifierFlags: [])
        #endif
        capture(app, name: "Native Find in a fictional note")
#if os(macOS)
        // AppKit's nonincremental Find bar has no occurrence-count label.
        // Verify its real selection ranges, including the exact wrap boundary.
        let editor = app.textViews["markdown-editor"]
        let source = try XCTUnwrap(editor.value as? String)
        let text = source as NSString
        var matches: [NSRange] = []
        var remainder = NSRange(location: 0, length: text.length)
        while remainder.length > 0 {
            let match = text.range(of: "lantern", range: remainder)
            if match.location == NSNotFound { break }
            matches.append(match)
            remainder = NSRange(location: NSMaxRange(match),
                                length: text.length - NSMaxRange(match))
        }
        XCTAssertEqual(matches.count, 3)
        guard matches.count == 3 else { return }
        let next = app.buttons["find next"]
        let previous = app.buttons["find previous"]
        let done = app.windows.firstMatch.buttons["Done"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertTrue(previous.exists)
        XCTAssertTrue(done.exists)
        done.click()
        // Closing Find keeps its selected match. Replacing that match proves
        // the exact native range without requiring separate AX permissions.
        let paths: [(nextCount: Int, backwards: Bool, matchIndex: Int)] = [
            (0, false, 0), (1, false, 1), (2, false, 2),
            (3, false, 0), (0, true, 2),
        ]
        for (index, path) in paths.enumerated() {
            XCTAssertFalse(findField.exists)
            editor.typeKey(.upArrow, modifierFlags: .command)
            app.typeKey("f", modifierFlags: .command)
            XCTAssertTrue(findField.waitForExistence(timeout: 5))
            findField.typeKey("a", modifierFlags: .command)
            findField.typeText("lantern")
            findField.typeKey(.return, modifierFlags: [])
            for _ in 0..<path.nextCount { next.click() }
            if path.backwards { previous.click() }
            done.click()
            XCTAssertFalse(findField.exists)
            let marker = "FictionalFindSelection\(index)"
            let expected = text.replacingCharacters(in: matches[path.matchIndex],
                                                   with: marker)
            editor.typeText(marker)
            assertNativeFindSource(expected, editor: editor,
                                   message: "Native Find selected range \(matches[path.matchIndex])")
            editor.typeKey("z", modifierFlags: .command)
            assertNativeFindSource(source, editor: editor,
                                   message: "Undo must restore every original source byte")
        }
        capture(app, name: "Native Find traverses exactly three occurrences")
#else
        let matchIndicator = app.staticTexts["1 of 3"]
        XCTAssertTrue(
            matchIndicator.waitForExistence(timeout: 5),
            "Expected native Find to report the matching occurrence"
        )
#endif
#if os(iOS)
        let next = app.buttons["find.nextButton"]
        let previous = app.buttons["find.previousButton"]
        next.tap()
        XCTAssertTrue(app.staticTexts["2 of 3"].waitForExistence(timeout: 5))
        next.tap()
        XCTAssertTrue(app.staticTexts["3 of 3"].waitForExistence(timeout: 5))
        let keyboardVisible = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let keyboard = app.keyboards.firstMatch
                return keyboard.exists
                    && keyboard.frame.minY < app.frame.maxY - 100
            }, object: app
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [keyboardVisible], timeout: 5), .completed
        )
        capture(app, name: "Native Find reveals the last occurrence")
        XCTAssertGreaterThan(
            app.textViews["markdown-editor"].frame.maxY, findField.frame.maxY,
            "The document must extend behind the native Find controls"
        )
        previous.tap()
        XCTAssertTrue(app.staticTexts["2 of 3"].waitForExistence(timeout: 5))
        app.buttons["find.doneButton"].tap()
        XCTAssertFalse(app.searchFields["find.searchField"].exists)
        let editor = app.textViews["markdown-editor"]
        let originalText = editor.value as? String ?? ""
        editor.tap()
        XCTAssertTrue(
            app.buttons["editor-command-bold"].waitForExistence(timeout: 5),
            "Writing controls should return after closing Find"
        )
        capture(app, name: "Native selection before writing after Find")
        let insertion = " Written after Find."
        editor.typeText(insertion)
        let editedText = try XCTUnwrap(editor.value as? String)
        let unchangedParts = editedText.components(separatedBy: insertion)
        let insertionOnly = unchangedParts.count == 2
            && Array(unchangedParts.joined().utf8) == Array(originalText.utf8)
        // Native Find may retain its selected second match after closing.
        // Permit replacement of that exact word, preserving all other bytes.
        let sentence = "The lantern marks the turn toward the river."
        XCTAssertEqual(originalText.components(separatedBy: sentence).count, 2)
        let sentenceRange = try XCTUnwrap(originalText.range(of: sentence))
        let selectedMatch = try XCTUnwrap(
            originalText.range(of: "lantern", range: sentenceRange)
        )
        let replacedMatch = originalText.replacingCharacters(
            in: selectedMatch, with: insertion
        )
        XCTAssertTrue(
            insertionOnly || Array(editedText.utf8) == Array(replacedMatch.utf8),
            "Writing must insert text or replace only the selected second match"
        )
        capture(app, name: "Writing resumes after closing native Find")
#endif
    }

#if os(macOS)
    private func assertNativeFindSource(
        _ expected: String, editor: XCUIElement, message: String
    ) {
        let matches = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard let actual = editor.value as? String else { return false }
                return Array(actual.utf8) == Array(expected.utf8)
            }, object: editor
        )
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 5), .completed,
                       message)
        XCTAssertEqual(Array((editor.value as? String ?? "").utf8),
                       Array(expected.utf8), message)
    }

    func testQuickOpenShortcutSearchesAndOpensNote() throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launch()

        let marker = "nebula-\(UUID().uuidString.prefix(8))"
        createNote(in: app, title: "Fictional Nebula", body: marker)
        app.typeKey("o", modifierFlags: [.command, .shift])

        let query = app.textFields["quick-open-query"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        query.typeText(marker)
        let result = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "quick-result-")
        ).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        capture(app, name: "Quick Open results")
        query.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.textViews["markdown-editor"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["note-title"].label, "Fictional Nebula")
        capture(app, name: "Quick Open selected a fictional note")
    }
#endif

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = "search-ui-\(UUID().uuidString)"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "source"]
        return app
    }

    private func createNote(
        in app: XCUIApplication, title: String, body: String
    ) {
        #if os(macOS)
        let control = app.descendants(matching: .any)
            .matching(identifier: "notebook-new-item").firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 15))
        let newNote = control.buttons.firstMatch
        XCTAssertTrue(newNote.waitForExistence(timeout: 5))
        #else
        let newNote = app.buttons["notebook-new-item"].firstMatch
        XCTAssertTrue(newNote.waitForExistence(timeout: 15))
        #endif
        activate(newNote)
        #if os(macOS)
        let titleField = app.descendants(matching: .any)
            .matching(identifier: "title-field").firstMatch
        #else
        let titleField = app.textFields["title-field"]
        #endif
        XCTAssertTrue(titleField.waitForExistence(timeout: 10))
#if os(macOS)
        titleField.click()
        titleField.typeKey("a", modifierFlags: .command)
        titleField.typeText(title)
        titleField.typeKey(.return, modifierFlags: [])
#else
        titleField.tap()
        let existing = titleField.value as? String ?? ""
        titleField.typeText(
            String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count)
                + title
        )
        titleField.typeText("\n")
#endif
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.typeText(body)
        XCTAssertEqual(editor.value as? String, body)
    }

    private func showSidebar(in app: XCUIApplication) {
#if os(iOS)
        if app.frame.width < 600 && !app.searchFields.firstMatch.isHittable {
            app.navigationBars.buttons.firstMatch.tap()
        }
#endif
        XCTAssertTrue(
            app.buttons["notebook-app-menu"].waitForExistence(timeout: 10)
                || app.searchFields.firstMatch.waitForExistence(timeout: 10)
        )
    }

    private func revealGlobalSearch(in app: XCUIApplication) -> XCUIElement {
        let field = app.searchFields.firstMatch
        if field.exists { return field }
        let searchButton = app.buttons["Search"]
        if searchButton.waitForExistence(timeout: 3) {
            activate(searchButton)
        }
        return field
    }

    private func activate(_ element: XCUIElement) {
#if os(macOS)
        element.click()
#else
        element.tap()
#endif
    }

    private func capture(_ app: XCUIApplication, name: String) {
#if os(macOS)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
#else
        let attachment = XCTAttachment(screenshot: app.screenshot())
#endif
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
