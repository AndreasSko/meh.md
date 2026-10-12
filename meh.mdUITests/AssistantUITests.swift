#if CHATGPT_POC && os(iOS)
import XCTest
import UIKit
import Vision

@MainActor
final class AssistantUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func test00CaptureSettings() {
        let app = makeApp(signedIn: false)
        defer { app.terminate() }
        app.launch()
        app.openNotebookSettings()
        capture(app, "Settings")
    }

    func testConnectionIsOptionalAndExplainsPrivatePreview() {
        let app = makeApp(signedIn: false)
        defer { app.terminate() }
        app.launch()
        XCTAssertFalse(app.buttons["assistant-open-chat"].exists)
        app.openNotebookSettings()
        let settings = app.buttons["assistant-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()
        XCTAssertTrue(app.buttons["assistant-connect"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Private preview"].exists)
        XCTAssertFalse(app.buttons["assistant-disconnect"].exists)
        capture(app, "ChatGPT connection — signed out fixture")
    }

    func testNotebookChatButtonStaysClearOfSidebarControls() {
        let app = makeApp()
        defer { app.terminate() }
        app.launch()

        let chat = app.buttons["assistant-open-chat"]
        let newNote = app.buttons["notebook-new-item"].firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 15))
        XCTAssertTrue(newNote.waitForExistence(timeout: 10))
        XCTAssertFalse(
            chat.frame.intersects(newNote.frame),
            "The chat button must not cover the native New Note control"
        )

        let searchField = app.searchFields.matching(
            NSPredicate(
                format: "placeholderValue == %@ OR label == %@",
                "Search all notes", "Search all notes"
            )
        ).firstMatch
        let searchButton = app.buttons["Search"]
        XCTAssertTrue(
            searchField.exists || searchButton.exists,
            "Expected the native global Search control"
        )
        if searchField.exists {
            XCTAssertFalse(
                chat.frame.intersects(searchField.frame),
                "The chat button must not cover the native search field"
            )
        }
        if searchButton.exists {
            XCTAssertFalse(
                chat.frame.intersects(searchButton.frame),
                "The chat button must not cover the native Search toolbar item"
            )
        }

        for identifier in ["notebook-settings", "notebook-trash-toggle"] {
            let control = app.buttons[identifier]
            if control.exists {
                XCTAssertFalse(
                    chat.frame.intersects(control.frame),
                    "The chat button must not cover sidebar control "
                        + identifier
                )
            }
        }

        capture(app, "Notebook chat button")
        guard app.frame.width < 600 else { return }

        newNote.tap()
        let title = app.textFields["title-field"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        let existingTitle = title.value as? String ?? ""
        title.typeText(
            String(
                repeating: XCUIKeyboardKey.delete.rawValue,
                count: existingTitle.count
            ) + "Fictional Assistant Button Note"
        )
        title.typeText("\n")
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        // Focusing the body explicitly ensures the software keyboard is
        // visible; submitting the title can leave only the accessory toolbar.
        editor.tap()
        editor.typeText("Fictional assistant button body")
        let keyboard = app.keyboards.firstMatch
        let keyboardVisible = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                keyboard.exists && keyboard.frame.intersects(app.frame)
            },
            object: app
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [keyboardVisible], timeout: 5), .completed,
            "Typing in the note body should show the software keyboard"
        )
        XCTAssertFalse(app.buttons["assistant-open-chat"].exists)
        let dragStart = editor.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        let dragEnd = keyboard.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)
        )
        dragStart.press(forDuration: 0.05, thenDragTo: dragEnd)
        let keyboardOffscreen = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                !keyboard.exists || !keyboard.frame.intersects(app.frame)
            },
            object: keyboard
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [keyboardOffscreen], timeout: 5), .completed,
            "The keyboard should no longer occupy visible screen space"
        )

        let detailChat = app.buttons.matching(
            identifier: "assistant-open-chat"
        ).firstMatch
        XCTAssertTrue(
            detailChat.waitForExistence(timeout: 10),
            "The chat button must remain available on phone note detail"
        )
        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: detailChat
        )
        XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 10), .completed)
        let detailNewNote = app.buttons["notebook-new-item"].firstMatch
        XCTAssertTrue(detailNewNote.waitForExistence(timeout: 5))
        XCTAssertFalse(
            detailChat.frame.intersects(detailNewNote.frame),
            "The chat button must stay clear of the detail toolbar"
        )
        // The portrait iPhone simulator has a bottom home-indicator region.
        // Catch a detail overlay accidentally placed inside its expanded
        // edge-to-edge editor instead of navigation's safe-area container.
        XCTAssertGreaterThan(
            app.frame.maxY - detailChat.frame.maxY, 30,
            "The chat button must clear the phone's bottom safe area"
        )
        capture(app, "Notebook chat button — phone note detail")

        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let landscape = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in app.frame.width > app.frame.height },
            object: app
        )
        XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 10), .completed)
        XCTAssertTrue(detailChat.waitForExistence(timeout: 10))
        let landscapeHittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: detailChat
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [landscapeHittable], timeout: 10), .completed
        )
        XCTAssertEqual(app.buttons.matching(identifier: "assistant-open-chat").count, 1)
        XCTAssertFalse(detailChat.frame.intersects(detailNewNote.frame))
        capture(app, "Notebook chat button — phone landscape")
    }

    func testLongNotebookListEndsClearOfFloatingChatButton() {
        let app = makeApp()
        app.launchEnvironment["MEH_NOTEBOOK_TEST_FIXTURE"] = "drag-long-list"
        defer { app.terminate() }
        app.launch()
        let chat = app.buttons["assistant-open-chat"]
        XCTAssertTrue(chat.waitForExistence(timeout: 15))
        let lastTitle = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@",
            "notebook-sidebar-title-", "48 Field observation"
        )).firstMatch
        for _ in 0..<12 {
            if lastTitle.exists && lastTitle.isHittable
                && lastTitle.frame.maxY < chat.frame.minY { break }
            app.swipeUp()
        }
        XCTAssertTrue(lastTitle.exists)
        let lastRow = app.descendants(matching: .any)[
            lastTitle.identifier.replacingOccurrences(
                of: "notebook-sidebar-title-", with: "notebook-sidebar-note-"
            )
        ]
        XCTAssertTrue(lastRow.exists)
        XCTAssertTrue(lastRow.isHittable)
        XCTAssertLessThan(
            lastRow.frame.maxY, chat.frame.minY,
            "The final note row must scroll fully above the floating button"
        )
        capture(app, "Long notebook list — final note clear of chat button")
    }

    func testLongNoteFinalLineScrollsClearOfFloatingChatButton() throws {
        let app = makeApp()
        app.launchArguments += ["-editor.mode", "source"]
        defer { app.terminate() }
        app.launch()
        let newNote = app.buttons["notebook-new-item"].firstMatch
        XCTAssertTrue(newNote.waitForExistence(timeout: 15))
        newNote.tap()
        let title = app.textFields["title-field"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.typeText("Fictional long journal\n")
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        let source = (1...40).map { "Fictional journal line \($0)." }
            .joined(separator: "\n") + "\nFINAL CEDAR JOURNAL LINE"
        editor.typeText(source)
        XCTAssertEqual(editor.value as? String, source)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: keyboard.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)
            ))
        let hidden = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                !keyboard.exists || !keyboard.frame.intersects(app.frame)
            }, object: keyboard
        )
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        let chat = app.buttons["assistant-open-chat"]
        XCTAssertTrue(chat.waitForExistence(timeout: 10))
        for _ in 0..<4 { editor.swipeUp() }
        let image = try XCTUnwrap(UIImage(data: app.screenshot().pngRepresentation))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage))
            .perform([request])
        let observation = try XCTUnwrap((request.results ?? []).first {
            $0.topCandidates(1).first?.string.contains("FINAL CEDAR") == true
        }, "The final line must actually be visible in the screenshot")
        let box = observation.boundingBox
        let line = CGRect(
            x: box.minX * app.frame.width,
            y: (1 - box.maxY) * app.frame.height,
            width: box.width * app.frame.width,
            height: box.height * app.frame.height
        )
        XCTAssertTrue(editor.frame.contains(line))
        XCTAssertLessThan(line.maxY, chat.frame.minY)
        capture(app, "Long note — final line clear of chat button")
    }

    func testBackAndForthNewThreadHistoryAndRelaunch() {
        let app = makeApp()
        defer { app.terminate() }
        app.launch()
        openChat(app)
        XCTAssertFalse(app.buttons["assistant-send"].isEnabled)
        send("Fictional Orion meeting", in: app)
        expectText("Preview reply: Fictional Orion meeting", in: app)
        send("What did I just mention?", in: app)
        expectText("Earlier messages: 1", in: app)
        capture(app, "Native chat — two fixture turns")
        dismissChatKeyboard(in: app)
        capture(app, "Native chat — two fixture turns keyboard hidden")

        app.buttons["assistant-new-chat"].tap()
        XCTAssertTrue(app.staticTexts["Start a chat"].waitForExistence(timeout: 5))
        let composer = app.textFields["assistant-message-draft"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("Fictional draft")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["assistant-chat-history"].tap()
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 10))
        capture(app, "Chat history opened from focused composer")
        let previous = app.buttons["Fictional Orion meeting"]
        XCTAssertTrue(previous.waitForExistence(timeout: 5))
        previous.tap()
        expectText("Earlier messages: 1", in: app)

        app.buttons["assistant-chat-close"].tap()
        XCTAssertTrue(app.buttons["assistant-open-chat"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        openChat(app)
        app.buttons["assistant-chat-history"].tap()
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 10))
        let restored = app.buttons["Fictional Orion meeting"]
        XCTAssertTrue(restored.waitForExistence(timeout: 5))
        restored.tap()
        expectText("Preview reply: Fictional Orion meeting", in: app)
        expectText("Earlier messages: 1", in: app)
    }

    func testDefaultModelSettingAppliesToNewChatsAndSurvivesRelaunch() {
        let runID = "assistant-default-model-\(UUID().uuidString)"
        let app = makeApp(runID: runID)
        defer { app.terminate() }
        app.launch()

        openAssistantSettings(app)
        chooseModel(
            "Preview model Plus",
            from: app.descendants(matching: .any).matching(
                identifier: "assistant-default-model-picker"
            ).firstMatch,
            in: app
        )
        let defaultModelPicker = app.descendants(matching: .any).matching(
            identifier: "assistant-default-model-picker"
        ).firstMatch
        expectValue("Preview model Plus", on: defaultModelPicker)
        capture(app, "ChatGPT default model — Preview model Plus")
        app.navigationBars.buttons["Settings"].tap()
        app.buttons["Done"].tap()

        openChat(app)
        let modelPicker = app.buttons["assistant-model-picker"]
        expectExactLabel("Model: Preview model Plus", on: modelPicker)
        chooseModel(
            "Preview model", from: app.buttons["assistant-model-picker"], in: app
        )
        expectExactLabel("Model: Preview model", on: modelPicker)
        app.buttons["assistant-new-chat"].tap()
        expectExactLabel(
            "Model: Preview model Plus",
            on: modelPicker,
            message: "A new chat should use the saved default, not the prior chat override"
        )

        app.buttons["assistant-chat-close"].tap()
        XCTAssertTrue(
            app.buttons["assistant-open-chat"].waitForExistence(timeout: 5)
        )
        app.terminate()
        app.launch()

        openAssistantSettings(app)
        expectValue(
            "Preview model Plus",
            on: app.descendants(matching: .any).matching(
                identifier: "assistant-default-model-picker"
            ).firstMatch
        )
        app.navigationBars.buttons["Settings"].tap()
        app.buttons["Done"].tap()
        openChat(app)
        expectExactLabel(
            "Model: Preview model Plus",
            on: app.buttons["assistant-model-picker"],
            message: "The chosen default should still initialize chats after relaunch"
        )
    }

    func testStopAndFailedReplyRemainVisibleAndAllowNewTurn() {
        let app = makeApp()
        defer { app.terminate() }
        app.launch()
        openChat(app)
        send("fixture slow", in: app)
        let stop = app.buttons["assistant-stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()
        expectText("Stopped", in: app)
        send("fixture failure", in: app)
        expectText("This reply could not be completed.", in: app)
        XCTAssertTrue(app.buttons["assistant-send"].waitForExistence(timeout: 5))
        capture(app, "Interrupted and failed fixture replies")
        app.buttons["assistant-new-chat"].tap()
        XCTAssertTrue(app.staticTexts["Start a chat"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["assistant-send"].isEnabled)
    }

    func testFixtureCreatesUpdatesAndOpensSavedNote() {
        let runID = "assistant-tools-\(UUID().uuidString)"
        let app = makeApp(runID: runID)
        defer { app.terminate() }
        app.launch()
        openChat(app)

        send("fixture create note", in: app)
        expectText("Created Assistant Fixture Note.", in: app)
        let firstReference = noteReferenceButton(
            title: "Assistant Fixture Note", in: app
        )
        XCTAssertTrue(firstReference.waitForExistence(timeout: 10))
        XCTAssertTrue(firstReference.isHittable)
        firstReference.tap()
        waitForDisappearance(app.buttons["assistant-chat-close"])

        let originalBody = app.textViews["markdown-editor"]
        XCTAssertTrue(originalBody.waitForExistence(timeout: 10))
        XCTAssertTrue(
            (originalBody.value as? String ?? "").contains(
                "Created by the notebook assistant fixture."
            )
        )
        capture(app, "Notebook assistant created a saved note")

        openChat(app)
        send("fixture update note", in: app)
        expectText("Updated Assistant Fixture Note.", in: app)
        let references = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "assistant-note-reference-"
        ))
        let uniqueLinks = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in references.count == 2 },
            object: app
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [uniqueLinks], timeout: 10), .completed,
            "Create and update replies should each show one link to the note"
        )
        capture(app, "Notebook assistant tool results")
        dismissChatKeyboard(in: app)
        capture(app, "Notebook assistant tool results keyboard hidden")
        let updatedReference = noteReferenceButton(
            title: "Assistant Fixture Note", in: app
        )
        XCTAssertTrue(updatedReference.waitForExistence(timeout: 10))
        XCTAssertTrue(updatedReference.isHittable)
        updatedReference.tap()
        waitForDisappearance(app.buttons["assistant-chat-close"])
        XCTAssertTrue(originalBody.waitForExistence(timeout: 10))
        XCTAssertTrue(
            (originalBody.value as? String ?? "").contains(
                "Updated by the notebook assistant fixture."
            )
        )
        capture(app, "Notebook assistant updated saved note")

        app.terminate()
        app.launch()
        openChat(app)
        expectText("Updated Assistant Fixture Note.", in: app)
        let durableReference = noteReferenceButton(
            title: "Assistant Fixture Note", in: app
        )
        XCTAssertTrue(durableReference.waitForExistence(timeout: 10))
        XCTAssertTrue(durableReference.isHittable)
        durableReference.tap()
        waitForDisappearance(app.buttons["assistant-chat-close"])
        let durableBody = app.textViews["markdown-editor"]
        XCTAssertTrue(durableBody.waitForExistence(timeout: 10))
        XCTAssertTrue(
            (durableBody.value as? String ?? "").contains(
                "Updated by the notebook assistant fixture."
            )
        )
    }

    func testCommittedToolResultSurvivesStopAndRelaunch() {
        let runID = "assistant-stop-tool-\(UUID().uuidString)"
        let app = makeApp(runID: runID)
        defer { app.terminate() }
        app.launch()
        openChat(app)

        send("fixture create note then stop", in: app)
        let stop = app.buttons["assistant-stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        expectText("Creating note…", in: app)
        let committedWrite = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value == %@", "Fixture write committed"
            ),
            object: stop
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [committedWrite], timeout: 10), .completed
        )
        stop.tap()
        expectText("Stopped", in: app)
        let field = app.textFields["assistant-message-draft"]
        let composer: XCUIElement = field.waitForExistence(timeout: 1)
            ? field : app.textViews["assistant-message-draft"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("x")
        XCTAssertFalse(app.buttons["assistant-send"].isEnabled)
        expectText("Finishing note operation…", in: app)
        let finishFixture = app.buttons["assistant-fixture-finish-operation"]
        XCTAssertTrue(finishFixture.waitForExistence(timeout: 10))
        finishFixture.tap()
        expectText("Created Assistant Stop Fixture Note.", in: app)
        XCTAssertTrue(app.buttons["assistant-send"].isEnabled)
        let reference = noteReferenceButton(
            title: "Assistant Stop Fixture Note", in: app
        )
        XCTAssertTrue(reference.waitForExistence(timeout: 10))
        XCTAssertTrue(reference.isHittable)
        reference.tap()
        waitForDisappearance(app.buttons["assistant-chat-close"])
        let body = app.textViews["markdown-editor"]
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        XCTAssertTrue(
            (body.value as? String ?? "").contains(
                "Created by the notebook assistant fixture."
            )
        )

        app.terminate()
        app.launch()
        openChat(app)
        expectText("Created Assistant Stop Fixture Note.", in: app)
        let durableReference = noteReferenceButton(
            title: "Assistant Stop Fixture Note", in: app
        )
        XCTAssertTrue(durableReference.waitForExistence(timeout: 10))
        XCTAssertTrue(durableReference.isHittable)
        durableReference.tap()
        waitForDisappearance(app.buttons["assistant-chat-close"])
        let durableBody = app.textViews["markdown-editor"]
        XCTAssertTrue(durableBody.waitForExistence(timeout: 10))
        XCTAssertTrue(
            (durableBody.value as? String ?? "").contains(
                "Created by the notebook assistant fixture."
            )
        )
    }

    private func makeApp(
        signedIn: Bool = true,
        runID: String = "assistant-ui-\(UUID().uuidString)"
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = runID
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchEnvironment["MEH_ASSISTANT_FIXTURE"] = "1"
        app.launchEnvironment["MEH_ASSISTANT_FIXTURE_ACCOUNT"] = signedIn ? "1" : "0"
        return app
    }

    private func openChat(_ app: XCUIApplication) {
        let button = app.buttons["assistant-open-chat"]
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        button.tap()
        XCTAssertTrue(app.buttons["assistant-new-chat"].waitForExistence(timeout: 10))
    }

    private func openAssistantSettings(_ app: XCUIApplication) {
        app.openNotebookSettings()
        let settings = app.buttons["assistant-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let picker = app.descendants(matching: .any).matching(
            identifier: "assistant-default-model-picker"
        ).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"), object: picker
        )
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed)
    }

    private func chooseModel(
        _ modelName: String, from picker: XCUIElement, in app: XCUIApplication
    ) {
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertTrue(picker.isEnabled)
        picker.tap()
        let option = app.buttons[modelName]
        XCTAssertTrue(option.waitForExistence(timeout: 10), modelName)
        option.tap()
    }

    private func expectValue(
        _ text: String, on element: XCUIElement,
        message: String? = nil
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", text),
            object: element
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 10), .completed,
            message ?? "Expected value to contain \(text)"
        )
    }

    private func expectExactLabel(
        _ text: String, on element: XCUIElement,
        message: String? = nil
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", text),
            object: element
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 10), .completed,
            message ?? "Expected label to equal \(text)"
        )
    }

    private func send(_ text: String, in app: XCUIApplication) {
        let field = app.textFields["assistant-message-draft"]
        let editor: XCUIElement = field.waitForExistence(timeout: 1)
            ? field : app.textViews["assistant-message-draft"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText(text)
        let send = app.buttons["assistant-send"]
        XCTAssertTrue(send.isEnabled)
        send.tap()
    }

    private func dismissChatKeyboard(in app: XCUIApplication) {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists && keyboard.frame.intersects(app.frame) else {
            return
        }
        let transcript = app.scrollViews["assistant-message-list"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        XCTAssertTrue(transcript.frame.intersects(app.frame))
        XCTAssertLessThan(transcript.frame.maxY, keyboard.frame.minY)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(
            dx: transcript.frame.midX, dy: transcript.frame.midY
        ))
        let end = origin.withOffset(CGVector(
            dx: transcript.frame.midX, dy: transcript.frame.midY - 70
        ))
        start.press(forDuration: 0.05, thenDragTo: end)
        let hidden = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                !keyboard.exists || !keyboard.frame.intersects(app.frame)
            }, object: keyboard
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [hidden], timeout: 5), .completed,
            "Native scrolling should dismiss the chat keyboard"
        )
        XCTAssertTrue(
            app.buttons["assistant-chat-close"].exists,
            "Scrolling should keep the chat open"
        )
    }

    private func noteReferenceButton(
        title: String, in app: XCUIApplication
    ) -> XCUIElement {
        let matches = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label == %@",
                "assistant-note-reference-", title
            )
        )
        guard matches.count > 0 else { return matches.firstMatch }
        return matches.element(boundBy: matches.count - 1)
    }

    private func waitForDisappearance(_ element: XCUIElement) {
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed)
    }

    private func expectText(_ text: String, in app: XCUIApplication) {
        let result = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", text)
        ).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10), text)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name) — hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
#endif
