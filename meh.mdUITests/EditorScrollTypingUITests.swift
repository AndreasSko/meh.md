import XCTest

#if os(iOS)
import UIKit
import Vision

final class EditorScrollTypingUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        XCUIDevice.shared.orientation = .portrait
    }

    func testSourceColdFocusAndReturnKeepInsertionVisible() throws {
        try checkReopeningKeyboardNearEnd(mode: "source", checkEndReturn: true)
    }

    func testPreviewColdFocusTypesIntoTappedParagraph() throws {
        try checkReopeningKeyboardNearEnd(mode: "livePreview")
    }

    func testPreviewTypingAndListReturnKeepInsertionVisible() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        continueAfterFailure = false
        let app = makeApp(mode: "livePreview")
        defer { app.terminate() }
        app.launch()
        let editor = try createEditor(in: app)
        let fixture = (1...40).map {
            "Fictional prose line \($0) for Cedar journal."
        }.joined(separator: "\n") + "\n- TARGET 12345"
        try paste(fixture, into: editor, in: app)
        try alignEndMarker(in: app, editor: editor)
        var expected = fixture
        for letter in "test" { expected += tapLetter(String(letter), in: app) }
        try assertVisibleInsertion(expected, in: app, editor: editor, marker: "TARGET")
        let completedListSource = expected
        tapReturn(in: app)
        expected += "\n- "
        XCTAssertEqual(editor.value as? String, expected)
        try requireVisibleInsertionParagraph("TARGET", in: app, editor: editor)
        // Empty-item Return exits the list; typing then remains literal prose.
        tapReturn(in: app)
        expected = completedListSource + "\n"
        XCTAssertEqual(editor.value as? String, expected)
        for letter in "clear" { expected += tapLetter(String(letter), in: app) }
        try assertVisibleInsertion(expected, in: app, editor: editor, marker: "clear")
        tapReturn(in: app)
        expected += "\n"
        for letter in "next" { expected += tapLetter(String(letter), in: app) }
        try assertVisibleInsertion(expected, in: app, editor: editor, marker: "next")
        capture(app, name: "Preview writing stays visible after list and plain Return")
    }

    private func makeApp(mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchEnvironment["MEH_SYNC_CLOUDKIT"] = "0"
        app.launchArguments += ["-editor.mode", mode]
        return app
    }

    private func createEditor(in app: XCUIApplication) throws -> XCUIElement {
        let newItem = app.buttons["notebook-new-item"]
        XCTAssertTrue(newItem.waitForExistence(timeout: 20))
        newItem.tap()
        let title = app.textFields["title-field"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.typeText("\n")
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        return editor
    }

    private func tapReturn(in app: XCUIApplication) {
        let key = app.buttons.matching(NSPredicate(
            format: "label IN %@", ["Return", "return"]
        )).firstMatch
        XCTAssertTrue(key.exists)
        key.tap()
    }

    private func assertVisibleInsertion(
        _ expected: String, in app: XCUIApplication,
        editor: XCUIElement, marker: String
    ) throws {
        XCTAssertEqual(editor.value as? String, expected)
        let line = try requireText(marker, in: app, editor: editor, last: true)
        let visible = unobscuredEditor(editor, in: app, keyboard: app.keyboards.firstMatch)
        XCTAssertTrue(visible.contains(CGPoint(x: line.midX, y: line.midY)),
                      "The insertion line must remain visible above the keyboard")
    }

    private func checkReopeningKeyboardNearEnd(
        mode: String, checkEndReturn: Bool = false
    ) throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        continueAfterFailure = false
        let app = makeApp(mode: mode)
        defer { app.terminate() }
        app.launch()
        let editor = try createEditor(in: app)
        let keyboard = app.keyboards.firstMatch

        var lines = ["# Fictional Cedar journal", ""]
        for week in 1...100 {
            lines += [
                "## Week \(week) — Cedar workshop", "",
                "- Review the fictional agenda with Morgan and prepare the room.",
                "- Check the sample notes before the next community meeting.", "",
            ]
        }
        lines += [
            "## Final discussion", "", "- TARGET Cedar meeting 12345 67890",
            "- Follow up with Morgan.", "- Review the draft agenda.", "",
            "## Remaining items", "", "- Pack the sample folders.",
            "- Check the room booking.", "Close the fictional journal.",
        ]
        let fixture = lines.joined(separator: "\n")
        try paste(fixture, into: editor, in: app)
        let start = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let end = keyboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        start.press(forDuration: 0.05, thenDragTo: end)
        let hidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: keyboard
        )
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)

        // Real scrolling leaves TextKit estimating offscreen paragraphs.
        // Do not query caret geometry or materialize document layout here.
        for _ in 0..<20 { editor.swipeDown() }
        let closedViewport = editor.frame.intersection(app.frame)
        let minimumY = closedViewport.minY + closedViewport.height * 0.65
        let maximumY = closedViewport.minY + closedViewport.height * 0.9
        let lowerBand = minimumY...maximumY
        let preferredY = closedViewport.minY + closedViewport.height * 0.8
        let dragX = closedViewport.maxX - closedViewport.width * 0.08
        let dragY = closedViewport.midY
        var target: CGRect?
        for _ in 0..<25 {
            target = try textRects("TARGET", in: app, editor: editor).first
            if target != nil { break }
            editor.swipeUp()
        }
        for _ in 0..<4 {
            guard let current = target else { break }
            if lowerBand.contains(current.midY) { break }
            let displacement = min(260, max(-260, preferredY - current.midY))
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: dragX, dy: dragY)).press(
                forDuration: 0.05,
                thenDragTo: origin.withOffset(CGVector(dx: dragX, dy: dragY + displacement)),
                withVelocity: XCUIGestureVelocity(rawValue: 100),
                thenHoldForDuration: 0.7
            )
            target = try textRects("TARGET", in: app, editor: editor).first
        }
        let closedTarget = try XCTUnwrap(target)
        XCTAssertTrue(lowerBand.contains(closedTarget.midY))
        XCTAssertFalse(keyboard.exists)
        capture(app, name: "\(mode)-cold-focus-before-tap")
        // Use the numeric suffix: tapping a spellchecked word can select it
        // legitimately, which does not produce an insertion caret.
        app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: closedTarget.maxX - closedTarget.width * 0.08,
                     dy: closedTarget.midY)
        ).tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        try requireVisibleInsertionParagraph("TARGET", in: app, editor: editor)
        capture(app, name: "\(mode)-cold-focus-keyboard-open")

        let inserted = tapLetter("q", in: app)
        capture(app, name: "\(mode)-cold-focus-first-character")
        // Exact bytes identify the insertion position; the tapped paragraph
        // must remain visible above the keyboard after the first character.
        try requireVisibleInsertionParagraph("TARGET", in: app, editor: editor)
        let changed = try XCTUnwrap(editor.value as? String)
        let before = Array(fixture.utf16), after = Array(changed.utf16)
        let location = zip(before, after).prefix { $0.0 == $0.1 }.count
        let tappedParagraph = (fixture as NSString).paragraphRange(for:
            (fixture as NSString).range(of: "- TARGET Cedar meeting")
        )
        XCTAssertTrue(
            NSLocationInRange(location, tappedParagraph),
            "Typing must start in the tapped paragraph, not a nearby line"
        )
        let expected = (fixture as NSString).replacingCharacters(
            in: NSRange(location: location, length: 0), with: inserted
        )
        XCTAssertEqual(changed, expected)
        let insertionLine = (fixture as NSString).substring(to: location)
            .components(separatedBy: "\n").count
        print("Cold focus \(mode): inserted \(inserted) on source line \(insertionLine)")
        if checkEndReturn {
            editor.typeKey(.downArrow, modifierFlags: .command)
            tapReturn(in: app)
            var suffix = "\n"
            for letter in "finish" { suffix += tapLetter(String(letter), in: app) }
            try assertVisibleInsertion(expected + suffix, in: app,
                                       editor: editor, marker: "finish")
        }
    }

    private func requireVisibleInsertionParagraph(
        _ marker: String, in app: XCUIApplication, editor: XCUIElement
    ) throws {
        _ = try requireText(marker, in: app, editor: editor, last: true)
    }

    private func paste(
        _ text: String, into editor: XCUIElement, in app: XCUIApplication
    ) throws {
        UIPasteboard.general.string = text
        defer { UIPasteboard.general.string = nil }
        // A word valid in German and English avoids the spelling-correction
        // popup when selecting it; native Paste must replace the whole word.
        editor.typeText("Test")
        let placeholder = try requireText("Test", in: app, editor: editor)
        app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: placeholder.midX, dy: placeholder.midY)
        ).doubleTap()
        capture(app, name: "Native Paste placeholder selection")
        let labels = ["Paste", "Einsetzen"]
        let menuItem = app.menuItems.matching(
            NSPredicate(format: "label IN %@", labels)
        ).firstMatch
        if menuItem.waitForExistence(timeout: 2) {
            UIPasteboard.general.string = text
            menuItem.tap()
        } else {
            let button = app.buttons.matching(
                NSPredicate(format: "label IN %@", labels)
            ).firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 3))
            UIPasteboard.general.string = text
            button.tap()
        }
        let allow = app.alerts.buttons["Allow Paste"].firstMatch
        if allow.waitForExistence(timeout: 1) { allow.tap() }
        let pasted = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", text),
            object: editor
        )
        XCTAssertEqual(XCTWaiter.wait(for: [pasted], timeout: 5), .completed)
    }

    private func alignEndMarker(
        in app: XCUIApplication, editor: XCUIElement
    ) throws {
        let keyboard = app.keyboards.firstMatch
        for _ in 0..<5 {
            let visible = unobscuredEditor(editor, in: app, keyboard: keyboard)
            let marker = try textRects("TARGET", in: app, editor: editor).last
            let delta = marker.map { visible.midY - $0.midY }
                ?? -visible.height * 0.5
            if let marker,
               visible.contains(CGPoint(x: marker.midX, y: marker.midY)) {
                return
            }
            let movement = max(-visible.height * 0.5,
                               min(visible.height * 0.35, delta))
            let startY = movement < 0
                ? visible.minY + visible.height * 0.8
                : visible.minY + visible.height * 0.3
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(
                dx: visible.maxX - 30, dy: startY
            ))
            let end = origin.withOffset(CGVector(
                dx: visible.maxX - 30, dy: startY + movement
            ))
            start.press(forDuration: 0.05, thenDragTo: end,
                        withVelocity: .slow, thenHoldForDuration: 0)
            XCTAssertTrue(keyboard.exists)
        }
        XCTFail("Could not reveal the final paragraph above the keyboard")
    }

    private func tapLetter(_ letter: String, in app: XCUIApplication) -> String {
        let key = app.keys.matching(NSPredicate(
            format: "label == %@ OR label == %@", letter, letter.uppercased()
        )).firstMatch
        XCTAssertTrue(key.exists)
        let inserted = key.label
        key.tap()
        return inserted
    }

    private func unobscuredEditor(
        _ editor: XCUIElement, in app: XCUIApplication, keyboard: XCUIElement
    ) -> CGRect {
        let frame = editor.frame
        let keyboardTop = keyboard.exists ? keyboard.frame.minY : frame.maxY
        let toolbar = app.otherElements["editor-keyboard-toolbar"]
        let bold = app.buttons["editor-command-bold"]
        let accessoryTop = toolbar.exists ? toolbar.frame.minY
            : bold.exists ? bold.frame.minY : keyboardTop
        let bottom = min(frame.maxY, min(keyboardTop, accessoryTop))
        return CGRect(x: frame.minX, y: frame.minY, width: frame.width,
                      height: max(0, bottom - frame.minY))
    }

    private func requireText(
        _ text: String, in app: XCUIApplication, editor: XCUIElement,
        last: Bool = false
    ) throws -> CGRect {
        var observed: CGRect?
        var observationError: Error?
        let visibleText = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                do {
                    let visible = self.unobscuredEditor(
                        editor, in: app, keyboard: app.keyboards.firstMatch
                    )
                    let matches = try self.textRects(text, in: app, editor: editor)
                        .filter { visible.contains(CGPoint(x: $0.midX, y: $0.midY)) }
                    observed = last ? matches.last : matches.first
                    return observed != nil
                } catch {
                    observationError = error
                    return false
                }
            }, object: editor
        )
        let result = XCTWaiter.wait(for: [visibleText], timeout: 15)
        if result != .completed {
            capture(app, name: "Missing visible text: \(text)")
        }
        XCTAssertEqual(result, .completed,
                       "Expected the paragraph above the keyboard: \(text)")
        if let observationError, observed == nil { throw observationError }
        return try XCTUnwrap(observed, "Visible text missing: \(text)")
    }

    private func textRects(
        _ text: String, in app: XCUIApplication, editor: XCUIElement
    ) throws -> [CGRect] {
        let screenshot = app.screenshot()
        let image = try XCTUnwrap(UIImage(data: screenshot.pngRepresentation))
        let cgImage = try XCTUnwrap(image.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        return (request.results ?? []).compactMap { result in
            guard result.topCandidates(1).first?.string
                .localizedCaseInsensitiveContains(text) == true else { return nil }
            let box = result.boundingBox
            let frame = CGRect(
                x: box.minX * app.frame.width,
                y: (1 - box.maxY) * app.frame.height,
                width: box.width * app.frame.width,
                height: box.height * app.frame.height
            )
            return editor.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
                ? frame : nil
        }.sorted { $0.midY < $1.midY }
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
#endif
