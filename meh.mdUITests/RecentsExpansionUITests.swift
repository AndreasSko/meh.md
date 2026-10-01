import XCTest

#if os(iOS)
/// Uses a disposable loopback notebook in the iCloud Dev build.
/// Start Tools/LocalSyncServer/local_sync_server.py on port 9874 first.
@MainActor
final class RecentsExpansionUITests: XCTestCase {
    func testTapExpansionScrollPinAndRestoreFiles() throws {
        continueAfterFailure = false
        let app = try makeFixture()
        if UIDevice.current.userInterfaceIdiom == .pad {
            // Retained fixtures need the same keyboard-present viewport as
            // the freshly typed fixture for the browser scroll assertion.
            app.textViews["markdown-editor"].tap()
        }
        let showAll = app.buttons["notebook-recents-show-all"]
        XCTAssertTrue(showAll.waitForExistence(timeout: 10))
        XCTAssertTrue(showAll.isHittable)
        XCTAssertEqual(recentButtons(app).count, 5)
        let first = recentButtons(app).firstMatch
        if (first.value as? String)?.contains("Pinned") == true {
            revealSwipeActions(first)
            let unpin = app.buttons["Unpin from Recents"]
            XCTAssertTrue(unpin.waitForExistence(timeout: 5))
            unpin.tap()
        }
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

        try pinFirstVisibleRecent(app)

        let last = recentButtons(app).matching(
            NSPredicate(format: "label CONTAINS %@", "Moonrise")
        ).firstMatch
        for _ in 0..<4 where !last.isHittable {
            let row = recentButtons(app).allElementsBoundByIndex.first {
                $0.isHittable && $0.frame.midY > app.frame.height * 0.4
            }
            try XCTUnwrap(row).swipeUp(velocity: .slow)
        }
        XCTAssertTrue(last.isHittable, "Older recents must be reachable by scrolling")
        capture(app, name: "Older recents after scrolling")
        close.tap()
        XCTAssertTrue(showAll.waitForExistence(timeout: 5))
        XCTAssertTrue(files.isHittable)
        XCTAssertEqual(files.value as? String, filesValue)
        XCTAssertEqual(files.frame.minY, restoredFilesFrame.minY, accuracy: 2)
        XCTAssertEqual(recentButtons(app).count, 5)
        capture(app, name: "Recents closed with Files restored")
    }

    private func pinFirstVisibleRecent(_ app: XCUIApplication) throws {
        let first = try XCTUnwrap(recentButtons(app).allElementsBoundByIndex.first {
            $0.isHittable
        })
        let firstID = first.identifier
        revealSwipeActions(first)
        let unpin = app.buttons["Unpin from Recents"]
        if unpin.waitForExistence(timeout: 1), unpin.isHittable {
            unpin.tap()
            let refreshed = try XCTUnwrap(recentButtons(app).allElementsBoundByIndex.first {
                $0.identifier == firstID && $0.isHittable
            })
            revealSwipeActions(refreshed)
        }
        let pin = app.buttons["Pin in Recents"]
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        XCTAssertTrue(pin.isHittable)
        pin.tap()
        capture(app, name: "Recents after swipe pin")
        let pinnedRow = try XCTUnwrap(recentButtons(app).allElementsBoundByIndex.first {
            $0.identifier == firstID && $0.isHittable
        })
        let pinned = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "Pinned"),
            object: pinnedRow
        )
        XCTAssertEqual(XCTWaiter.wait(for: [pinned], timeout: 5), .completed)
    }

    private func revealSwipeActions(_ row: XCUIElement) {
        // A full-width swipe commits UIKit's action in a narrow iPad pane.
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        let end = row.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow,
                    thenHoldForDuration: 0.2)
    }

    func testGrabberPullCancelsOpensClosesAndOpensNote() throws {
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
        footer.tap()
        XCTAssertTrue(close.isHittable)
        let note = try XCTUnwrap(recentButtons(app).allElementsBoundByIndex.first {
            $0.isHittable
        })
        XCTAssertTrue(note.label.contains("Aurora watch"))
        note.tap()
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue((editor.value as? String ?? "").contains("aurora watch"))
        if UIDevice.current.userInterfaceIdiom == .phone {
            showSidebar(app)
            XCTAssertTrue(footer.waitForExistence(timeout: 5))
            XCTAssertFalse(close.isHittable)
        } else {
            XCTAssertTrue(close.isHittable)
        }
    }

    private func makeFixture() throws -> XCUIApplication {
        if let workspace = ProcessInfo.processInfo.environment[
            "MEH_RECENTS_UI_REUSE_WORKSPACE"
        ] {
            let app = launchApp(workspace: workspace)
            showSidebar(app)
            return app
        }
        let app = launchApp(workspace: "recents-ui-" + UUID().uuidString)
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

    private func launchApp(workspace: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MEH_SYNC_TEST_TRANSPORT"] = "loopback"
        app.launchEnvironment["MEH_SYNC_URL"] = "http://127.0.0.1:9874"
        app.launchEnvironment["MEH_SYNC_WORKSPACE"] = workspace
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "source"]
        app.launch()
        return app
    }

    private func showSidebar(_ app: XCUIApplication) {
        let recents = app.buttons["notebook-recents-toggle"]
        if !recents.isHittable {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(recents.waitForExistence(timeout: 10))
        if recents.value as? String == "Collapsed" { recents.tap() }
    }

    private func recentButtons(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND NOT identifier BEGINSWITH %@",
            "notebook-recent-", "notebook-recent-pin-"
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
