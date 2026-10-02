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
        let rows = recentButtons(app)
        XCTAssertEqual(rows.count, 5)
        let newest = rows.firstMatch
        newest.click()
        let newestFrame = newest.frame
        XCTAssertTrue(app.textViews["markdown-editor"].waitForExistence(timeout: 10))
        let files = app.buttons["notebook-tree-toggle"]
        if files.value as? String == "Collapsed" { files.click() }
        let filesFrame = files.frame
        let initialText = app.textViews["markdown-editor"].value as? String
        capture(app, name: "Mac compact Recents")
        if ProcessInfo.processInfo.environment["MEH_RECENTS_UI_BASELINE"] == "1" {
            return
        }
        let more = app.buttons["notebook-recents-more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.click()
        let collapse = app.buttons["notebook-recents-collapse"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 5))
        XCTAssertTrue(collapse.isHittable)
        XCTAssertLessThanOrEqual(collapse.frame.maxY,
                                 app.windows.firstMatch.frame.maxY - 8)
        let steadyRow = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                abs(newest.frame.minX - newestFrame.minX) <= 1
                    && abs(newest.frame.minY - newestFrame.minY) <= 1
                    && abs(newest.frame.width - newestFrame.width) <= 1
            }, object: newest
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
        XCTAssertTrue(more.isHittable)
        app.typeKey("r", modifierFlags: [.command, .shift])
        XCTAssertTrue(collapse.isHittable)
        app.typeKey("r", modifierFlags: [.command, .shift])
        XCTAssertTrue(more.isHittable)
        more.click()
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
        more.click()
        rows.firstMatch.rightClick()
        let pin = app.menuItems["Pin in Recents"]
        let unpin = app.menuItems["Unpin from Recents"]
        XCTAssertTrue(pin.exists || unpin.exists)
        if pin.exists { pin.click() } else { unpin.click() }
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

    private func makeFixture() -> XCUIApplication {
        let reuse = ProcessInfo.processInfo.environment["MEH_RECENTS_UI_REUSE_WORKSPACE"]
        let app = XCUIApplication()
        app.launchEnvironment["MEH_SYNC_TEST_TRANSPORT"] = "loopback"
        app.launchEnvironment["MEH_SYNC_URL"] =
            ProcessInfo.processInfo.environment["MEH_RECENTS_UI_SYNC_URL"]
            ?? "http://127.0.0.1:9874"
        app.launchEnvironment["MEH_SYNC_WORKSPACE"] = reuse ?? "mac-recents-" + UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "source"]
        app.launch()
        if reuse == nil {
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
                newNote.click()
                let title = app.textFields["title-field"]
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
        app.buttons.matching(NSPredicate(
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
