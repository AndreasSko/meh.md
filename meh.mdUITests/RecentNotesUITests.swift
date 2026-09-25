import XCTest
#if os(iOS)
import Vision
#endif

final class RecentNotesUITests: XCTestCase {
    func testFiveCurrentPreviewsAndCollapsedSectionsSurviveRelaunch() throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launch()
        var titles: [String] = []
        for index in 0..<6 {
            let newNote = app.buttons["notebook-new-item"].firstMatch
            XCTAssertTrue(newNote.waitForExistence(timeout: 15))
            waitUntilEnabled(newNote)
            activate(newNote)
            commitDefaultTitle(in: app)
            let editor = app.textViews["markdown-editor"]
            XCTAssertTrue(editor.waitForExistence(timeout: 10))
            editor.typeText("Fictional observatory entry \(index)")
            titles.append(app.buttons["note-title"].label)
        }
        showSidebar(app)
        let recents = recentButtons(app)
        if app.buttons["notebook-recents-toggle"].value as? String == "Collapsed" {
            activate(app.buttons["notebook-recents-toggle"])
        }
        XCTAssertEqual(recents.count, 5)
        XCTAssertTrue(recents.element(boundBy: 0).label.contains(titles[5]))
        XCTAssertTrue(recents.element(boundBy: 0).label.contains("entry 5"))
        XCTAssertFalse(recents.allElementsBoundByIndex.contains {
            $0.label.contains("entry 0")
        })
        let tree = app.buttons["notebook-tree-toggle"]
        let recentToggle = app.buttons["notebook-recents-toggle"]
        if tree.value as? String == "Expanded" { activate(tree) }
        if recentToggle.value as? String == "Expanded" { activate(recentToggle) }
        XCTAssertEqual(tree.value as? String, "Collapsed")
        XCTAssertEqual(recentToggle.value as? String, "Collapsed")
        app.terminate()
        app.launch()
        let editor = app.textViews["markdown-editor"]
        #if os(macOS)
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertEqual(editor.value as? String, "Fictional observatory entry 5")
        XCTAssertEqual(app.buttons["note-title"].label, titles[5])
        #endif
        showSidebar(app)
        XCTAssertEqual(tree.value as? String, "Collapsed")
        XCTAssertEqual(recentToggle.value as? String, "Collapsed")
        activate(recentToggle)
        XCTAssertEqual(recents.count, 5)
        activate(recents.element(boundBy: 1))
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, "Fictional observatory entry 4")
        // Reading a note leaves the most recently edited note first.
        showSidebar(app)
        XCTAssertTrue(recents.element(boundBy: 0).label.contains("entry 5"))
        XCTAssertTrue(recents.element(boundBy: 1).label.contains("entry 4"))
        capture(app, name: "Five local recent notes with current fictional previews")
    }

    #if os(iOS)
    func testIPhoneTrailingSwipePinsAndUnpinsWithoutOpeningRecent() throws {
        try XCTSkipIf(
            UIDevice.current.userInterfaceIdiom != .phone,
            "This test verifies the iPhone-only trailing swipe interaction."
        )
        continueAfterFailure = false
        let app = makeApp()
        app.launch()

        let firstSource = "Fictional pin target"
        let secondSource = "Fictional active note"
        createRecentNote(in: app, source: firstSource)
        createRecentNote(in: app, source: secondSource)

        showSidebar(app)
        let recents = recentButtons(app)
        let pinTarget = recents.element(boundBy: 1)
        XCTAssertTrue(pinTarget.waitForExistence(timeout: 5))
        pinTarget.swipeLeft(velocity: .slow)
        let pinAction = app.buttons["Pin in Recents"]
        XCTAssertTrue(pinAction.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["notebook-recents-toggle"].isHittable)
        capture(app, name: "Orange pin swipe action in the fictional library")

        pinAction.tap()
        let pinnedRecent = recents.element(boundBy: 0)
        XCTAssertTrue(pinnedRecent.waitForExistence(timeout: 5))
        XCTAssertTrue(pinnedRecent.label.contains(firstSource))
        XCTAssertTrue((pinnedRecent.value as? String)?.contains("Pinned") == true)
        XCTAssertTrue(app.buttons["notebook-recents-toggle"].isHittable)
        capture(app, name: "Pinned recent note in the fictional library")

        pinnedRecent.swipeLeft(velocity: .slow)
        let unpinAction = app.buttons["Unpin from Recents"]
        XCTAssertTrue(unpinAction.waitForExistence(timeout: 5))
        XCTAssertEqual(unpinAction.label, "Unpin from Recents")
        capture(app, name: "Gray unpin swipe action in the fictional library")

        unpinAction.tap()
        let unpinnedRecent = recents.element(boundBy: 1)
        XCTAssertTrue(unpinnedRecent.waitForExistence(timeout: 5))
        XCTAssertTrue(unpinnedRecent.label.contains(firstSource))
        XCTAssertFalse((unpinnedRecent.value as? String)?.contains("Pinned") == true)
        XCTAssertTrue(app.buttons["notebook-recents-toggle"].isHittable)
        Thread.sleep(forTimeInterval: 1)
        capture(app, name: "Recent notes after partial unpin")

        fullSwipeLeft(unpinnedRecent)
        Thread.sleep(forTimeInterval: 1)
        let fullSwipePinned = recents.element(boundBy: 0)
        XCTAssertTrue(fullSwipePinned.waitForExistence(timeout: 5))
        XCTAssertTrue(fullSwipePinned.label.contains(firstSource))
        XCTAssertTrue((fullSwipePinned.value as? String)?.contains("Pinned") == true)
        XCTAssertTrue(recents.element(boundBy: 1).label.contains(secondSource))
        capture(app, name: "Recent notes after full-swipe pin")

        fullSwipeLeft(fullSwipePinned)
        Thread.sleep(forTimeInterval: 1)
        let fullSwipeUnpinned = recents.element(boundBy: 1)
        XCTAssertTrue(fullSwipeUnpinned.waitForExistence(timeout: 5))
        XCTAssertTrue(fullSwipeUnpinned.label.contains(firstSource))
        XCTAssertFalse((fullSwipeUnpinned.value as? String)?.contains("Pinned") == true)
        XCTAssertTrue(recents.element(boundBy: 0).label.contains(secondSource))
        capture(app, name: "Recent notes after full-swipe unpin")

        fullSwipeUnpinned.tap()
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(waitUntilHittable(editor))
        XCTAssertEqual(editor.value as? String, firstSource)
    }

    func testIPadContextMenuPinsWithoutOpeningRecent() throws {
        try XCTSkipIf(
            UIDevice.current.userInterfaceIdiom != .pad,
            "This test verifies the iPad context-menu interaction."
        )
        continueAfterFailure = false
        let app = makeApp()
        app.launch()

        let firstSource = "Fictional iPad pin target"
        let secondSource = "Fictional iPad active note"
        createRecentNote(in: app, source: firstSource)
        createRecentNote(in: app, source: secondSource)

        showSidebar(app)
        let recents = recentButtons(app)
        let pinTarget = recents.element(boundBy: 1)
        XCTAssertTrue(pinTarget.waitForExistence(timeout: 5))
        let pinTargetIdentifier = pinTarget.identifier
        pinTarget.press(forDuration: 1.0)
        let pinAction = app.buttons["Pin in Recents"]
        XCTAssertTrue(pinAction.waitForExistence(timeout: 5))
        XCTAssertEqual(app.textViews["markdown-editor"].value as? String, secondSource)

        pinAction.tap()
        let pinnedRecent = recents.element(boundBy: 0)
        XCTAssertTrue(pinnedRecent.waitForExistence(timeout: 5))
        XCTAssertEqual(pinnedRecent.identifier, pinTargetIdentifier)
        let editor = app.textViews["markdown-editor"]
        XCTAssertEqual(editor.value as? String, secondSource)
        app.typeText(" suffix")
        XCTAssertEqual(editor.value as? String, secondSource + " suffix")
    }

    private func fullSwipeLeft(_ row: XCUIElement) {
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        let end = row.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    func testLeavingNoteRestoresBrowserUntilNoteIsOpenedAgain() throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launch()
        let newNote = app.buttons["notebook-new-item"].firstMatch
        XCTAssertTrue(newNote.waitForExistence(timeout: 15))
        waitUntilEnabled(newNote)
        newNote.tap()
        commitDefaultTitle(in: app)
        let editor = app.textViews["markdown-editor"]
        editor.tap()
        editor.typeText("Fictional moon journal")
        try XCTSkipIf(app.buttons["notebook-recents-toggle"].isHittable,
                      "Requires a compact navigation layout")
        showSidebar(app)
        XCTAssertFalse(editor.isHittable)

        app.terminate()
        app.launch()
        let recentsToggle = app.buttons["notebook-recents-toggle"]
        XCTAssertTrue(recentsToggle.waitForExistence(timeout: 15))
        XCTAssertTrue(recentsToggle.isHittable)
        XCTAssertFalse(editor.isHittable)
        capture(app, name: "Browser after leaving a note and relaunching")

        if recentsToggle.value as? String == "Collapsed" { recentsToggle.tap() }
        let recent = recentButtons(app).firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        recent.tap()
        XCTAssertTrue(waitUntilHittable(editor))
        XCTAssertEqual(editor.value as? String, "Fictional moon journal")
        app.terminate()
        app.launch()
        XCTAssertTrue(waitUntilHittable(editor, timeout: 15))
        XCTAssertEqual(editor.value as? String, "Fictional moon journal")
        capture(app, name: "Explicitly reopened note restored after relaunch")
    }

    func testReadingPositionSurvivesBackgroundAndRelaunch() throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launch()
        let newNote = app.buttons["notebook-new-item"].firstMatch
        XCTAssertTrue(newNote.waitForExistence(timeout: 15))
        waitUntilEnabled(newNote)
        newNote.tap()
        commitDefaultTitle(in: app)
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let source = (1...45).map { "Moon log \($0)" }
            .joined(separator: "\n")
        editor.typeText(source)
        // Dismiss typing, then establish a reading viewport away from the caret.
        editor.swipeDown()
        editor.swipeDown()
        editor.swipeDown()
        editor.swipeUp()
        // XCTest can finish a swipe while the native scroll view decelerates.
        Thread.sleep(forTimeInterval: 1)
        let before = try topVisibleReadingLine(in: app, editor: editor)
        capture(app, name: "Reading viewport before background")
        XCUIDevice.shared.press(.home)
        app.terminate()
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertEqual(editor.value as? String, source)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        let after = try topVisibleReadingLine(in: app, editor: editor)
        XCTAssertEqual(after.text, before.text)
        XCTAssertEqual(after.y, before.y, accuracy: 8)
        capture(app, name: "Restored reading viewport after relaunch")
    }

    private func topVisibleReadingLine(
        in app: XCUIApplication, editor: XCUIElement
    ) throws -> (text: String, y: CGFloat) {
        let screenshot = app.screenshot().image
        let image = try XCTUnwrap(screenshot.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let frame = editor.frame
        let screen = app.frame
        let lines = (request.results ?? []).compactMap { observation
            -> (text: String, y: CGFloat)? in
            guard let text = observation.topCandidates(1).first?.string,
                  text.hasPrefix("Moon log ") else { return nil }
            let box = observation.boundingBox
            let center = CGPoint(
                x: screen.minX + box.midX * screen.width,
                y: screen.minY + (1 - box.midY) * screen.height
            )
            guard frame.contains(center) else { return nil }
            return (text, center.y - frame.minY)
        }
        return try XCTUnwrap(lines.min { $0.y < $1.y })
    }
    #endif

    #if os(macOS)
    func testCaretRestoresAcrossNoteSwitchAndRelaunch() throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launch()
        let newNote = app.buttons["notebook-new-item"].firstMatch
        XCTAssertTrue(newNote.waitForExistence(timeout: 15))
        waitUntilEnabled(newNote)
        newNote.click()
        commitDefaultTitle(in: app)
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.typeText("Moon star")
        let originalTitle = app.buttons["note-title"].label
        for _ in 0..<4 { editor.typeKey(.leftArrow, modifierFlags: []) }
        waitUntilEnabled(newNote)
        newNote.click()
        commitDefaultTitle(in: app)
        editor.typeText("A second fictional note")
        let recentToggle = app.buttons["notebook-recents-toggle"]
        if recentToggle.value as? String == "Collapsed" { recentToggle.click() }
        let firstNote = recentButtons(app).element(boundBy: 1)
        firstNote.click()
        XCTAssertEqual(editor.value as? String, "Moon star")
        app.typeKey(.tab, modifierFlags: [])
        editor.typeText("bright ")
        XCTAssertEqual(editor.value as? String, "Moon bright star")
        // A normal quit captures the current caret without selecting a note.
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons["note-title"].label, originalTitle)
        app.typeKey(.tab, modifierFlags: [])
        editor.typeText("little ")
        XCTAssertEqual(editor.value as? String, "Moon bright little star")
        capture(app, name: "Caret restored in the last fictional note")
    }
    #endif

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "source"]
        return app
    }

    private func recentButtons(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND NOT identifier BEGINSWITH %@",
            "notebook-recent-", "notebook-recent-pin-"
        ))
    }

    private func createRecentNote(in app: XCUIApplication, source: String) {
        let newNote = app.buttons["notebook-new-item"].firstMatch
        XCTAssertTrue(newNote.waitForExistence(timeout: 15))
        waitUntilEnabled(newNote)
        activate(newNote)
        commitDefaultTitle(in: app)
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        activate(editor)
        editor.typeText(source)
        showSidebar(app)
    }

    private func showSidebar(_ app: XCUIApplication) {
        #if os(iOS)
        if !app.buttons["notebook-recents-toggle"].isHittable {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        #endif
        XCTAssertTrue(app.buttons["notebook-recents-toggle"].waitForExistence(timeout: 5))
    }

    private func activate(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    private func waitUntilEnabled(_ element: XCUIElement) {
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed)
    }

    private func waitUntilHittable(
        _ element: XCUIElement, timeout: TimeInterval = 10
    ) -> Bool {
        let visible = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"), object: element
        )
        return XCTWaiter.wait(for: [visible], timeout: timeout) == .completed
    }

    private func commitDefaultTitle(in app: XCUIApplication) {
        let titleField = app.textFields["title-field"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 10))
        activate(titleField)
        #if os(macOS)
        titleField.typeKey(.return, modifierFlags: [])
        #else
        titleField.typeText("\n")
        #endif
        XCTAssertTrue(app.textViews["markdown-editor"].waitForExistence(timeout: 5))
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
