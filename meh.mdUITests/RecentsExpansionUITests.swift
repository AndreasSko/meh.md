import XCTest

#if os(iOS)
@MainActor
final class RecentsExpansionUITests: XCTestCase {
    func testCompactScrollAndTapExpansionRestoreFiles() throws {
        continueAfterFailure = false
        let app = try makeFixture()
        let showAll = app.buttons["notebook-recents-show-all"]
        XCTAssertTrue(showAll.waitForExistence(timeout: 10))
        XCTAssertTrue(showAll.isHittable)
        XCTAssertEqual(recentButtons(app).count, 5)
        let files = app.buttons["notebook-tree-toggle"]
        let filesFrame = files.frame
        let filesValue = files.value as? String
        capture(app, name: "Recents compact after")

        // A vertical swipe that begins on a compact recent row must scroll
        // the surrounding Files browser without unfolding Recents.
        let compactRow = recentButtons(app).firstMatch
        compactRow.swipeUp(velocity: .slow)
        XCTAssertLessThan(files.frame.minY, filesFrame.minY - 15)
        XCTAssertFalse(app.buttons["notebook-recents-close"].isHittable)
        if UIDevice.current.userInterfaceIdiom == .pad {
            // The browser AX frame extends behind the keyboard. Start the
            // return pan on visible Files content rather than that frame.
            let start = files.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
            )
            start.press(forDuration: 0.05,
                        thenDragTo: start.withOffset(CGVector(dx: 0, dy: 250)),
                        withVelocity: .slow, thenHoldForDuration: 0.2)
        } else {
            app.collectionViews.firstMatch.swipeDown(velocity: .slow)
        }
        XCTAssertTrue(showAll.isHittable)
        let restoredFilesFrame = files.frame

        showAll.tap()
        capture(app, name: "Recents immediately after expansion tap")
        let close = app.buttons["notebook-recents-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertTrue(close.isHittable)
        XCTAssertFalse(files.isHittable)
        XCTAssertGreaterThan(recentButtons(app).count, 5)
        capture(app, name: "Recents expanded after")

        close.tap()
        XCTAssertTrue(showAll.waitForExistence(timeout: 5))
        XCTAssertTrue(files.isHittable)
        XCTAssertEqual(files.value as? String, filesValue)
        XCTAssertEqual(files.frame.minY, restoredFilesFrame.minY, accuracy: 2)
        XCTAssertEqual(recentButtons(app).count, 5)
        capture(app, name: "Recents closed with Files restored")
    }

    func testGrabberPullCancelsOpensAndCloses() throws {
        continueAfterFailure = false
        let app = try makeFixture()
        let footer = app.buttons["notebook-recents-show-all"]
        XCTAssertTrue(footer.waitForExistence(timeout: 10))
        capture(app, name: "Recents quiet footer compact")
        let start = footer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05,
                    thenDragTo: start.withOffset(CGVector(dx: 0, dy: 24)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
        capture(app, name: "Recents after cancelled downward footer pull")
        XCTAssertTrue(footer.isHittable)
        XCTAssertFalse(app.buttons["notebook-recents-close"].isHittable)
        XCTAssertEqual(recentButtons(app).count, 5)

        let committedStart = footer.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        committedStart.press(
            forDuration: 0.05,
            thenDragTo: committedStart.withOffset(CGVector(dx: 0, dy: 150)),
            withVelocity: .slow, thenHoldForDuration: 0.3
        )
        let close = app.buttons["notebook-recents-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertTrue(close.isHittable)
        XCTAssertGreaterThan(recentButtons(app).count, 5)
        capture(app, name: "Recents expanded with downward footer pull")
        let grabber = app.descendants(matching: .any)["notebook-recents-drag-area"]
        XCTAssertTrue(grabber.waitForExistence(timeout: 5))
        let closingStart = grabber.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        closingStart.press(forDuration: 0.05,
                           thenDragTo: closingStart.withOffset(CGVector(dx: 0, dy: -24)),
                           withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(close.isHittable)
        capture(app, name: "Recents after cancelled upward bottom grabber pull")
        let committedClose = grabber.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        committedClose.press(
            forDuration: 0.05,
            thenDragTo: committedClose.withOffset(CGVector(dx: 0, dy: -150)),
            withVelocity: .slow, thenHoldForDuration: 0.3
        )
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertTrue(footer.isHittable)
        XCTAssertFalse(close.isHittable)
        XCTAssertEqual(recentButtons(app).count, 5)
        capture(app, name: "Recents closed with upward bottom grabber pull")
    }

    func testExpandedRecentsSurvivesNoteNavigationUntilClosed() throws {
        continueAfterFailure = false
        let app = try makeFixture()
        let footer = app.buttons["notebook-recents-show-all"]
        let close = app.buttons["notebook-recents-close"]
        XCTAssertTrue(footer.waitForExistence(timeout: 10))
        footer.tap()
        XCTAssertTrue(close.isHittable)

        let older = recentButtons(app).matching(NSPredicate(
            format: "label CONTAINS %@", "Moonrise"
        )).firstMatch
        for _ in 0..<4 where !older.isHittable {
            let row = recentButtons(app).allElementsBoundByIndex.first {
                $0.isHittable && $0.frame.midY > app.frame.height * 0.4
            }
            try XCTUnwrap(row).swipeUp(velocity: .slow)
        }
        XCTAssertTrue(older.isHittable)
        let visibleNeighbor = try XCTUnwrap(
            recentButtons(app).allElementsBoundByIndex.first {
                $0.isHittable && $0.identifier != older.identifier
                    && ($0.label.contains("Telescope setup")
                        || $0.label.contains("Star chart"))
            }
        )
        let neighborID = visibleNeighbor.identifier
        capture(app, name: "Expanded Recents before opening older note")
        older.tap()
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue((editor.value as? String ?? "").contains("moonrise"))
        showSidebar(app)
        capture(app, name: "Recents after returning from older note")
        XCTAssertTrue(close.isHittable,
                      "Recents must stay expanded until explicitly closed")
        XCTAssertGreaterThan(recentButtons(app).count, 5)
        XCTAssertTrue(recentButtons(app).matching(identifier: neighborID)
            .firstMatch.isHittable, "Keep the older Recents viewport on return")

        // Opening a note updates its recent order. Assert the expanded list
        // survives navigation rather than freezing the previous row order.
        close.tap()
        XCTAssertTrue(footer.waitForExistence(timeout: 5))
        XCTAssertTrue(footer.isHittable)
        XCTAssertEqual(recentButtons(app).count, 5)
        let compactNote = try XCTUnwrap(
            recentButtons(app).allElementsBoundByIndex.first { $0.isHittable }
        )
        compactNote.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        showSidebar(app)
        XCTAssertTrue(footer.isHittable)
        XCTAssertFalse(close.isHittable)
        XCTAssertEqual(recentButtons(app).count, 5)
        capture(app, name: "Recents remains compact after explicit close")
    }

    func testSwipeTrashRequiresTapInCompactAndExpanded() throws {
        continueAfterFailure = false
        let app = try makeFixture()
        for expanded in [false, true] {
            if expanded {
                app.buttons["notebook-recents-show-all"].tap()
                XCTAssertTrue(app.buttons["notebook-recents-close"].isHittable)
            }
            let visibleRow = try XCTUnwrap(recentButtons(app).allElementsBoundByIndex.first {
                $0.isHittable && !($0.value as? String ?? "").contains("Pinned")
            })
            let rowID = visibleRow.identifier
            let target = recentButtons(app).matching(identifier: rowID).firstMatch
            XCTAssertTrue(target.waitForExistence(timeout: 10))
            let start = target.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
            let end = target.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow,
                        thenHoldForDuration: 0.2)
            let trashAction = app.buttons["Move to Trash"]
            XCTAssertTrue(trashAction.waitForExistence(timeout: 5))
            XCTAssertTrue(target.exists, "A full swipe must preserve the note")
            capture(app, name: expanded ? "Expanded Recents Trash swipe" : "Compact Recents Trash swipe")
            trashAction.tap()
            XCTAssertTrue(target.waitForNonExistence(timeout: 5))
            if expanded {
                app.buttons["notebook-recents-close"].tap()
                XCTAssertTrue(
                    app.buttons["notebook-recents-show-all"].waitForExistence(timeout: 5)
                )
            }
        }
    }

    func testHiddenRecentStaysInFilesUntilExplicitlyShown() throws {
        continueAfterFailure = false
        let app = try makeFixture()
        // Recent enough for compact Recents, high enough in Files to stay
        // visible without scrolling.
        let target = recentButtons(app).matching(NSPredicate(
            format: "label CONTAINS %@", "Meteor shower"
        )).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        let noteID = target.identifier.replacingOccurrences(
            of: "notebook-recent-", with: ""
        )
        let filesTitle = app.staticTexts["notebook-sidebar-title-" + noteID]
        let recentToggle = app.buttons["notebook-recents-toggle"]
        let filesToggle = app.buttons["notebook-tree-toggle"]

        revealTrailingSwipeActions(target)
        let hide = app.buttons["Hide from Recents"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Move to Trash"].exists)
        XCTAssertTrue(target.exists, "Swiping must leave the note intact")
        capture(app, name: "Recents icon-only Trash and Hide swipe")
        hide.tap()
        XCTAssertTrue(target.waitForNonExistence(timeout: 5))
        recentToggle.tap()
        if filesToggle.value as? String == "Collapsed" { filesToggle.tap() }
        XCTAssertTrue(filesTitle.waitForExistence(timeout: 5))
        XCTAssertTrue(filesTitle.isHittable)
        filesTitle.tap()
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue((editor.value as? String ?? "").contains("meteor shower"))
        editor.tap()
        editor.typeText(" Still safely in Files.")
        app.terminate()
        app.launch()
        showSidebar(app)
        XCTAssertTrue(target.waitForNonExistence(timeout: 5),
                      "Opening, editing and relaunching must keep it hidden")
        if recentToggle.value as? String == "Expanded" { recentToggle.tap() }
        if filesToggle.value as? String == "Collapsed" { filesToggle.tap() }
        XCTAssertTrue(filesTitle.waitForExistence(timeout: 5))
        app.withoutIdleWait {
            filesTitle.press(forDuration: 1)
            let show = app.buttons["Show in Recents"]
            XCTAssertTrue(show.waitForExistence(timeout: 5))
            capture(app, name: "Hidden note Show in Recents Files menu")
            show.tap()
        }
        recentToggle.tap()
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        capture(app, name: "Hidden note explicitly restored to Recents")
    }

    private func revealTrailingSwipeActions(_ row: XCUIElement) {
        let start = row.coordinate(
            withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)
        )
        let end = row.coordinate(
            withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)
        )
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow,
                    thenHoldForDuration: 0.2)
    }

    private func makeFixture() throws -> XCUIApplication {
        let app = launchApp(run: "recents-ui-" + UUID().uuidString)
        let names = ["Moonrise", "Telescope setup", "Star chart", "Evening walk",
                     "Reading list", "Garden plans", "Weekend ideas", "Meteor shower",
                     "Sketchbook", "Travel notes", "Observatory log", "Aurora watch"]
        for (index, name) in names.enumerated() {
            let newNote = app.buttons["notebook-new-item"].firstMatch
            XCTAssertTrue(newNote.waitForExistence(timeout: 15))
            let enabled = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "enabled == true"), object: newNote
            )
            XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed)
            newNote.tap()
            let title = app.textFields["title-field"]
            XCTAssertTrue(title.waitForExistence(timeout: 10))
            title.tap()
            if let value = title.value as? String {
                title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                                      count: value.count))
            }
            title.typeText(name + "\n")
            let editor = app.textViews["markdown-editor"]
            XCTAssertTrue(editor.waitForExistence(timeout: 10))
            editor.tap()
            editor.typeText("A fictional field note about " + name.lowercased()
                            + ". Entry " + String(index + 1) + ".")
        }
        showSidebar(app)
        return app
    }

    private func launchApp(run: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = run
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "source"]
        app.launch()
        return app
    }

    private func showSidebar(_ app: XCUIApplication) {
        let recents = app.buttons["notebook-recents-toggle"]
        // Expanded Recents hides its toggle, but on iPad the sidebar is
        // still on screen; its first bar button would open the app menu.
        if !recents.isHittable && !app.buttons["notebook-recents-close"].isHittable {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(recents.waitForExistence(timeout: 10))
        if recents.value as? String == "Collapsed" { recents.tap() }
    }

    private func recentButtons(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND NOT identifier BEGINSWITH %@ "
                + "AND NOT identifier BEGINSWITH %@",
            "notebook-recent-", "notebook-recent-pin-", "notebook-recent-swipe-"
        ))
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + " hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
#endif
