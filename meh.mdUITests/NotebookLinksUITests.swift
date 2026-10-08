import XCTest
import Vision
#if os(iOS)
import UIKit
#endif

final class NotebookLinksUITests: XCTestCase {
    func testWikiNavigationBacklinksAndCompletion() throws {
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
        capture(app, name: "Fictional wiki link in a meeting note")

        // Reopen from Files to establish passive reading rather than depending
        // on the swipe distance needed to dismiss a short note's keyboard.
        let actions = app.descendants(matching: .any)
            .matching(identifier: "notebook-note-actions").firstMatch
        activate(actions)
        activate(app.descendants(matching: .any)
            .matching(identifier: "notebook-show-in-files").firstMatch)
        #if os(macOS)
        let fileTitles = app.notebookVisibleMacSidebar.staticTexts
        #else
        let fileTitles = app.staticTexts
        #endif
        let meetingRow = fileTitles.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (label == %@ OR value == %@)",
            "notebook-sidebar-title-", "Fictional Meeting", "Fictional Meeting"
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
        capture(app, name: "Fictional meeting in passive reading mode")
        try followFixtureLink(in: app)
        assertTitle("Fictional Project", in: app)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        capture(app, name: "Rendered wiki link opened without editing focus")

        XCTAssertFalse(app.buttons["note-link-forward"].exists)
        goBack(from: app, returningTo: "Fictional Meeting")
        assertTitle("Fictional Meeting", in: app)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        try followFixtureLink(in: app)
        assertTitle("Fictional Project", in: app)

        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        activate(actions)
        let backlinksAction = app.descendants(matching: .any)
            .matching(identifier: "notebook-backlinks").firstMatch
        XCTAssertTrue(backlinksAction.waitForExistence(timeout: 5))
        activate(backlinksAction)
        let backlink = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "backlink-")
        ).firstMatch
        XCTAssertTrue(backlink.waitForExistence(timeout: 10))
        XCTAssertTrue(backlink.label.contains("the project"))
        capture(app, name: "Backlink excerpt from a fictional meeting")
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
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(
            format: "label CONTAINS %@", "the project"
        )).firstMatch.exists)
        capture(app, name: "No linked notes for a fictional meeting")
        activate(app.buttons["Done"])

        // Typing a partial wiki link should offer the existing project. Taking
        // the suggestion must replace the partial token with a complete link.
        let meetingTitle = "Fictional Link Draft"
        createNote(in: app, title: meetingTitle, body: "See [[Fictional")
        let suggestion = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "link-suggestion-", "Fictional Project"
            )
        ).firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 10))
        XCTAssertTrue(suggestion.label.contains("Fictional Project"))
        #if os(macOS)
        let focusedEditor = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: editor
        )
        XCTAssertEqual(XCTWaiter.wait(for: [focusedEditor], timeout: 5), .completed)
        #else
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        #endif
        XCTAssertTrue(suggestion.isHittable)
        XCTAssertGreaterThanOrEqual(
            suggestion.frame.height, 44,
            "A completion row should remain comfortably tappable"
        )
        capture(app, name: "Suggestions for fictional notes")
        activate(suggestion)
        let draft = app.textViews["markdown-editor"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        XCTAssertTrue(
            (draft.value as? String ?? "").contains("[[Fictional Project]]"),
            "Selecting a completion should insert a complete wiki link; "
                + "draft was: \(draft.value as? String ?? "<unavailable>")"
        )
        capture(app, name: "Completed wiki link in a fictional draft")
    }

#if os(iOS)
    func testCompactBackTransitionKeepsNoteContent() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone,
                          "Requires iPhone compact navigation")
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
        capture(app, name: "Meeting position before following a link")

        try followFixtureLink(in: app)
        assertTitle("Fictional Project", in: app)
        goBack(from: app, returningTo: "Fictional Meeting")
        assertTitle("Fictional Meeting", in: app)
        capture(app, name: "Meeting after native Back")

        try followFixtureLink(in: app)
        assertTitle("Fictional Project", in: app)
        swipeBackFromLeadingEdge(in: app, slowly: true)
        assertTitle("Fictional Meeting", in: app)
        capture(app, name: "Meeting after edge swipe")
        XCTAssertEqual(app.buttons["note-title"].frame.minY, originalTitleY, accuracy: 1,
                       "Returning should preserve the note's vertical position")
        XCTAssertFalse(app.searchFields.firstMatch.exists,
                       "Back through a link should remain in the note detail")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
    }

    func testCompactBackAfterBacklinkKeepsScrolledAnchor() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone,
                          "Requires iPhone compact navigation")
        continueAfterFailure = false
        let app = makeApp()
        app.launch()

        let longBody = (0..<30).map { index in
            if index == 0 { return "TOP POSITION MARKER" }
            if index == 15 { return "MID POSITION MARKER" }
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
        let source = fileRow("Fictional Long Source", in: app)
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        activate(source)
        app.terminate()
        app.launch()

        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        assertTitle("Fictional Long Source", in: app)
        XCTAssertEqual(editor.value as? String, longBody)
        let keyboardHidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.keyboards.firstMatch
        )
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardHidden], timeout: 5), .completed)

        // Place the middle of the long fictional note in view before opening
        // its incoming-link sheet, so Back must restore a scrolled note.
        editor.swipeDown()
        editor.swipeDown()
        editor.swipeDown()
        editor.swipeUp()
        let sourceTitle = app.buttons["note-title"]
        var previousTitleY = sourceTitle.frame.minY
        var stableSamples = 0
        let settlingDeadline = Date().addingTimeInterval(5)
        while Date() < settlingDeadline && stableSamples < 5 {
            Thread.sleep(forTimeInterval: 0.1)
            let currentTitleY = sourceTitle.frame.minY
            if abs(currentTitleY - previousTitleY) <= 0.5 {
                stableSamples += 1
            } else {
                stableSamples = 0
            }
            previousTitleY = currentTitleY
        }
        XCTAssertGreaterThanOrEqual(
            stableSamples, 5, "Wait for source-note scroll inertia to settle"
        )
        capture(app, name: "Long fictional source before opening backlinks")
        let sourceTitleY = sourceTitle.frame.minY

        activate(app.buttons["notebook-note-actions"])
        activate(app.buttons["notebook-backlinks"])
        let backlink = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "backlink-")
        ).firstMatch
        XCTAssertTrue(backlink.waitForExistence(timeout: 10))
        XCTAssertTrue(backlink.label.contains("return to observations"))
        capture(app, name: "Fictional backlink to the long source")
        activate(backlink)

        assertTitle("Fictional Project", in: app)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        capture(app, name: "Fictional project opened from backlinks")

        goBack(from: app, returningTo: "Fictional Long Source")
        assertTitle("Fictional Long Source", in: app)
        XCTAssertEqual(sourceTitle.frame.minY, sourceTitleY, accuracy: 1)
        XCTAssertEqual(editor.value as? String, longBody)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        capture(app, name: "Long source after Back from backlink navigation")
    }

    func testCompactScrolledLinkOpeningKeepsVisitPosition() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone,
                          "Requires iPhone compact navigation")
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
            body: "A fictional project note for the midpoint link."
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
            "A fictional project note for the midpoint link."
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
        capture(app, name: "Fictional midpoint backlink from the project")
        activate(backlink)

        assertTitle("Fictional Long Source", in: app)
        XCTAssertEqual(editor.value as? String, longBody)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        let sourceTitle = app.buttons["note-title"]
        var previousTitleY = sourceTitle.frame.minY
        var stableSamples = 0
        let settlingDeadline = Date().addingTimeInterval(5)
        while Date() < settlingDeadline && stableSamples < 5 {
            Thread.sleep(forTimeInterval: 0.1)
            let currentTitleY = sourceTitle.frame.minY
            if abs(currentTitleY - previousTitleY) <= 0.5 {
                stableSamples += 1
            } else {
                stableSamples = 0
            }
            previousTitleY = currentTitleY
        }
        XCTAssertGreaterThanOrEqual(
            stableSamples, 5, "Wait for source-note scroll inertia to settle"
        )
        capture(app, name: "Long source at midpoint backlink destination")
        let sourceTitleY = sourceTitle.frame.minY

        let midpointLink = app.links["OPEN PROJECT FROM MIDPOINT"]
        if midpointLink.exists && midpointLink.isHittable {
            midpointLink.tap()
        } else {
            // Native text views sometimes omit link accessibility leaves.
            // Locate the visible alias in the actual viewport on this device.
            let image = try XCTUnwrap(app.screenshot().image.cgImage)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: image).perform([request])
            let matches = (request.results ?? []).filter {
                $0.topCandidates(1).first?.string == "OPEN PROJECT FROM MIDPOINT"
            }
            XCTAssertEqual(matches.count, 1, "Expected one visible midpoint link")
            let box = try XCTUnwrap(matches.first).boundingBox
            app.coordinate(withNormalizedOffset: CGVector(
                dx: box.midX, dy: 1 - box.midY
            )).tap()
        }
        assertTitle("Fictional Project", in: app)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        capture(app, name: "Project opened from the scrolled source link")

        goBack(from: app, returningTo: "Fictional Long Source")
        assertTitle("Fictional Long Source", in: app)
        XCTAssertEqual(sourceTitle.frame.minY, sourceTitleY, accuracy: 1)
        XCTAssertEqual(editor.value as? String, longBody)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        capture(app, name: "Long source after Back from midpoint link")
    }

    func testCompactBackReturnsToFilesAndManualSelectionResetsLinkChain() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone,
                          "Requires iPhone compact navigation")
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

        try followFixtureLink(in: app)
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
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone,
                          "Requires iPhone compact navigation")
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

        try followFixtureLink(in: app)
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
        let newNote = app.notebookNewItemButton
        XCTAssertTrue(newNote.waitForExistence(timeout: 15))
        activate(newNote)
        let titleField = app.notebookTitleField
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
        titleField.click()
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
        app.returnFromNotebookLink(to: expectedTitle)
    }

    private func followFixtureLink(in app: XCUIApplication) throws {
        let link = app.links["the project"]
        if link.exists && link.isHittable {
            activate(link)
            return
        }
        // Locate the rendered alias rather than assuming a font or viewport.
#if os(macOS)
        // macOS applications have no finite screen frame. Use the same window
        // for both the capture and the recognized text's coordinate space.
        let captureElement = app.windows.firstMatch
#else
        let captureElement = app
#endif
        #if os(macOS)
        let screenshot = captureElement.screenshot().image
#else
        // App captures can contain a full-screen letterbox while app.frame
        // describes only the shorter iPad window. Keep OCR and coordinates
        // in the display's space, then offset from the actual app origin.
        let screenshot = XCUIScreen.main.screenshot().image
#endif
#if os(macOS)
        let image = try XCTUnwrap(screenshot.cgImage(
            forProposedRect: nil, context: nil, hints: nil
        ))
#else
        let image = try XCTUnwrap(screenshot.cgImage)
#endif
        let request = VNRecognizeTextRequest()
#if os(macOS)
        // Revision 3's detector still requests ANE models on virtual Macs,
        // even after assigning CPU stages. The legacy engine supports this
        // English fixture and recognizes its actual on-screen alias.
        request.revision = VNRecognizeTextRequestRevision2
        request.recognitionLevel = .fast
#else
        request.recognitionLevel = .accurate
#endif
        request.recognitionLanguages = ["en-US"]
#if os(macOS)
        // The deprecated usesCPUOnly flag does not constrain every stage
        // on hosted Macs. Explicitly choose a supported CPU for each stage.
        for (stage, devices) in try request.supportedComputeStageDevices {
            let cpu = try XCTUnwrap(devices.first { device in
                if case .cpu = device { return true }
                return false
            }, "Expected a CPU backend for text recognition stage \(stage)")
            request.setComputeDevice(cpu, for: stage)
        }
#endif
        try VNImageRequestHandler(cgImage: image).perform([request])
        let editorFrame = app.textViews["markdown-editor"].frame
        #if os(macOS)
        let screen = captureElement.frame
#else
        let screen = UIScreen.main.bounds
        XCTAssertEqual(Double(image.width) / Double(image.height),
                       Double(screen.width) / Double(screen.height),
                       accuracy: 0.001,
                       "OCR capture must use the full display coordinate space")
#endif
        let matches = try (request.results ?? []).compactMap { observation -> CGRect? in
            guard let candidate = observation.topCandidates(1).first,
                  let range = candidate.string.range(of: "the project"),
                  let rectangle = try candidate.boundingBox(for: range)
            else { return nil }
            let box = rectangle.boundingBox
            let center = CGPoint(x: screen.minX + box.midX * screen.width,
                                 y: screen.minY + (1 - box.midY) * screen.height)
            return editorFrame.contains(center) ? box : nil
        }
        XCTAssertEqual(matches.count, 1, "Expected one visible project alias in the editor")
        let box = try XCTUnwrap(matches.first)
#if os(macOS)
        captureElement.coordinate(withNormalizedOffset: CGVector(
            dx: box.midX, dy: 1 - box.midY
        )).click()
#else
        let position = CGPoint(x: screen.minX + box.midX * screen.width,
                               y: screen.minY + (1 - box.midY) * screen.height)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: position.x - app.frame.minX, dy: position.y - app.frame.minY
        )).tap()
#endif
    }

#if os(iOS)
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

    private func capture(_ app: XCUIApplication, name: String) {
#if os(macOS)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
#else
        let attachment = XCTAttachment(screenshot: app.screenshot())
#endif
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
#if os(iOS)
        let directory = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask)[0]
        let filename = name.replacingOccurrences(of: " ", with: "-") + ".png"
        try? app.screenshot().pngRepresentation.write(
            to: directory.appendingPathComponent(filename))
#endif
    }
}
