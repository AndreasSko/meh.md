import XCTest

#if os(macOS)
@MainActor
final class MacRecentsUITests: XCTestCase {
    func testMoreBrowsesOlderNotesAndRestoresFiles() throws {
        continueAfterFailure = false
        let app = makeFixture()
        let recents = app.buttons["notebook-recents-toggle"]
        XCTAssertTrue(recents.waitForExistence(timeout: 15))
        if recents.value as? String == "Collapsed" { recents.click() }
        var rows = recentButtons(app)
        XCTAssertEqual(rows.count, 5)
        let newest = rows.firstMatch
        newest.click()
        let newestFrame = newest.frame
        let newestIdentifier = newest.identifier
        XCTAssertTrue(app.textViews["markdown-editor"].waitForExistence(timeout: 10))
        let files = app.buttons["notebook-tree-toggle"]
        if files.value as? String == "Collapsed" { files.click() }
        XCTAssertTrue(files.isHittable)
        assertMoreVisible(app.buttons["notebook-recents-more"], in: app)
        let filesFrame = files.frame
        let initialText = app.textViews["markdown-editor"].value as? String
        capture(app, name: "Mac compact Recents")
        if ProcessInfo.processInfo.environment["MEH_RECENTS_UI_BASELINE"] == "1" {
            return
        }
        let more = app.buttons["notebook-recents-more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        clickMore(more, in: app)
        rows = recentButtons(app)
        let expandedNewest = rows.matching(identifier: newestIdentifier).firstMatch
        let collapse = app.buttons["notebook-recents-collapse"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 5))
        XCTAssertTrue(collapse.isHittable)
        XCTAssertLessThanOrEqual(collapse.frame.maxY,
                                 app.windows.firstMatch.frame.maxY - 8)
        let steadyRow = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                abs(expandedNewest.frame.minX - newestFrame.minX) <= 1
                    && abs(expandedNewest.frame.minY - newestFrame.minY) <= 1
                    && abs(expandedNewest.frame.width - newestFrame.width) <= 1
            }, object: expandedNewest
        )
        XCTAssertEqual(XCTWaiter.wait(for: [steadyRow], timeout: 5), .completed)
        XCTAssertFalse(files.isHittable)
        XCTAssertEqual(app.textViews["markdown-editor"].value as? String, initialText)
        XCTAssertGreaterThan(rows.count, 5)
        capture(app, name: "Mac expanded Recents")
        app.typeKey(.downArrow, modifierFlags: [])
        let firstArrowTitle = app.buttons["note-title"].label
        app.typeKey(.downArrow, modifierFlags: [])
        let differentNote = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", firstArrowTitle),
            object: app.buttons["note-title"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [differentNote], timeout: 5), .completed)
        XCTAssertTrue(collapse.isHittable)
        app.typeKey(.escape, modifierFlags: [])
        assertMoreVisible(more, in: app)
        app.typeKey("r", modifierFlags: [.command, .shift])
        XCTAssertTrue(collapse.isHittable)
        app.typeKey("r", modifierFlags: [.command, .shift])
        assertMoreVisible(more, in: app)
        clickMore(more, in: app)
        rows = recentButtons(app)
        let older = rows.matching(NSPredicate(
            format: "label CONTAINS %@", "Moonrise"
        )).firstMatch
        let list = app.descendants(matching: .any)["notebook-all-recents"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        for _ in 0..<4 where !older.isHittable {
            list.scroll(byDeltaX: 0, deltaY: -300)
        }
        XCTAssertTrue(older.isHittable)
        XCTAssertTrue(collapse.isHittable)
        older.click()
        XCTAssertTrue(app.buttons["note-title"].label.contains("Moonrise"))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        XCTAssertTrue(files.isHittable)
        XCTAssertEqual(files.frame.minY, filesFrame.minY, accuracy: 2)
        clickMore(more, in: app)
        rows = recentButtons(app)
        let contextRow = rows.firstMatch
        let contextNoteID = contextRow.identifier.replacingOccurrences(
            of: "notebook-recent-", with: ""
        )
        XCTAssertNotNil(UUID(uuidString: contextNoteID))
        contextRow.rightClick()
        // The global Recents menu has the same label. Target this row's
        // context action by its stable note identity rather than that label.
        let pinActions = app.menuItems.matching(
            identifier: "notebook-recent-pin-" + contextNoteID
        )
        let pinAction = pinActions.firstMatch
        XCTAssertTrue(pinAction.waitForExistence(timeout: 5))
        XCTAssertEqual(pinActions.count, 1)
        // Native menu items expose their title through keyed lookup, while
        // their label may be empty. Keep that lookup inside the identified row.
        XCTAssertTrue(pinActions["Pin in Recents"].exists
                      || pinActions["Unpin from Recents"].exists)
        pinAction.click()
        collapse.click()
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        XCTAssertTrue(files.isHittable)
        capture(app, name: "Mac Files restored after browsing Recents")
        recents.click()
        XCTAssertEqual(recents.value as? String, "Collapsed")
        let collapsedFilesFrame = files.frame
        app.typeKey("r", modifierFlags: [.command, .shift])
        XCTAssertTrue(collapse.isHittable)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(recents.isHittable)
        XCTAssertEqual(recents.value as? String, "Collapsed")
        XCTAssertTrue(files.isHittable)
        XCTAssertEqual(files.frame.minY, collapsedFilesFrame.minY, accuracy: 2)
    }

    private func assertMoreVisible(
        _ more: XCUIElement, in app: XCUIApplication,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(more.exists, file: file, line: line)
        let frame = more.frame
        XCTAssertTrue(frame.origin.x.isFinite && frame.origin.y.isFinite
                      && frame.width.isFinite && frame.height.isFinite,
                      file: file, line: line)
        XCTAssertGreaterThan(frame.width, 0, file: file, line: line)
        XCTAssertGreaterThan(frame.height, 0, file: file, line: line)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(frame),
                      file: file, line: line)
        XCTAssertTrue(app.notebookVisibleMacSidebar.frame.contains(frame),
                      file: file, line: line)
    }

    private func clickMore(_ more: XCUIElement, in app: XCUIApplication) {
        assertMoreVisible(more, in: app)
        // Hosted AppKit reports this native List button as not hittable even
        // when its complete frame is visible. Click the actual control's
        // center; the expansion and geometry checks verify mouse activation.
        more.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    private func makeFixture() -> XCUIApplication {
        let reuse = ProcessInfo.processInfo.environment["MEH_RECENTS_UI_REUSE_WORKSPACE"]
        let app = XCUIApplication()
        app.launchEnvironment["MEH_SYNC_TEST_TRANSPORT"] = "loopback"
        app.launchEnvironment["MEH_SYNC_URL"] =
            ProcessInfo.processInfo.ciLoopbackURL
            ?? ProcessInfo.processInfo.environment["MEH_RECENTS_UI_SYNC_URL"]
            ?? "http://127.0.0.1:9874"
        app.launchEnvironment["MEH_SYNC_WORKSPACE"] = reuse ?? "mac-recents-" + UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "source"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        // The geometry assertions need room for five Recents, More, Files,
        // and the fixed footer. The hosted Mac's initial 450-point window
        // clips Files under that footer before browsing even begins.
        if window.frame.height < 600 {
            let windowMenu = app.menuBars.menuBarItems["Window"]
            XCTAssertTrue(windowMenu.waitForExistence(timeout: 5))
            windowMenu.click()
            let zoom = app.menuItems["performZoom:"]
            XCTAssertTrue(zoom.waitForExistence(timeout: 5))
            XCTAssertTrue(zoom.isEnabled)
            zoom.click()
        }
        let sufficientHeight = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in window.frame.height >= 600 },
            object: window
        )
        XCTAssertEqual(XCTWaiter.wait(for: [sufficientHeight], timeout: 5), .completed,
                       "Recents geometry requires a window at least 600 points tall")
        if reuse == nil {
            let names = ["Moonrise", "Telescope setup", "Star chart", "Evening walk",
                         "Reading list", "Garden plans", "Weekend ideas", "Meteor shower",
                         "Sketchbook", "Travel notes", "Observatory log", "Aurora watch"]
            for (index, name) in names.enumerated() {
                let control = app.descendants(matching: .any)
                    .matching(identifier: "notebook-new-item").firstMatch
                XCTAssertTrue(control.waitForExistence(timeout: 15))
                let newNote = control.buttons.firstMatch
                XCTAssertTrue(newNote.waitForExistence(timeout: 5))
                let enabled = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "enabled == true"), object: newNote
                )
                XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed)
                newNote.click()
                let title = app.descendants(matching: .any)
                    .matching(identifier: "title-field").firstMatch
                XCTAssertTrue(title.waitForExistence(timeout: 10))
                title.click()
                title.typeKey("a", modifierFlags: .command)
                title.typeText(name)
                title.typeKey(.return, modifierFlags: [])
                let editor = app.textViews["markdown-editor"]
                XCTAssertTrue(editor.waitForExistence(timeout: 10))
                editor.click()
                editor.typeText("A fictional field note about " + name.lowercased()
                                + ". Entry " + String(index + 1) + ".")
            }
        }
        return app
    }

    private func recentButtons(_ app: XCUIApplication) -> XCUIElementQuery {
        app.notebookVisibleMacSidebar.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND NOT identifier BEGINSWITH %@ "
                + "AND NOT identifier BEGINSWITH %@",
            "notebook-recent-", "notebook-recent-pin-", "notebook-recent-swipe-"
        ))
    }

    private func capture(_ app: XCUIApplication, name: String) {
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
