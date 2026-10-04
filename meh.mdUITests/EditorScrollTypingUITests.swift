import XCTest

#if os(iOS)
import UIKit
import Vision

final class EditorScrollTypingUITests: XCTestCase {
    func testSourceReopeningKeyboardNearEndRevealsCaret() throws {
        try checkReopeningKeyboardNearEnd(mode: "source")
    }

    func testLivePreviewReopeningKeyboardNearEndRevealsCaret() throws {
        try checkReopeningKeyboardNearEnd(mode: "livePreview")
    }

    func testSourceTypingAtEndKeepsCaretStable() throws {
        try checkTypingAtEnd(mode: "source")
    }

    func testLivePreviewTypingAtEndKeepsCaretStable() throws {
        try checkTypingAtEnd(mode: "livePreview")
    }

    func testLivePreviewListReturnAtEndKeepsCaretStable() throws {
        try checkTypingAtEnd(
            mode: "livePreview", lastLine: "- TARGET 12345", continuation: "- "
        )
    }

    func testLivePreviewTypingOnEmptyEndLineKeepsCaretStable() throws {
        try checkTypingAtEnd(
            mode: "livePreview", lastLine: "TARGET 12345\n", firstWord: "test"
        )
    }

    private func checkTypingAtEnd(
        mode: String, lastLine: String = "TARGET 12345", continuation: String = "",
        firstWord: String = "a"
    ) throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .phone,
            "Regression recorded with the iPhone software keyboard"
        )
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += [
            "-editor.mode", mode,
            "-editor.fontFamily", "monospaced",
            "-editor.fontSize", "13",
        ]
        app.launch()
        let newItem = app.buttons["notebook-new-item"]
        XCTAssertTrue(newItem.waitForExistence(timeout: 20))
        newItem.tap()
        let title = app.textFields["title-field"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        title.typeText("\n")

        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        // The numeric ending and the later word "test" avoid autocorrection
        // on both German and English keyboards when Return commits a word.
        let fixture = (1...40).map {
            "Fictional prose line \($0) for Cedar journal."
        }.joined(separator: "\n") + "\n" + lastLine
        try paste(fixture, into: editor, in: app)
        XCTAssertEqual(editor.value as? String, fixture)
        XCTAssertEqual(
            fixture.components(separatedBy: "\n").count,
            40 + lastLine.components(separatedBy: "\n").count
        )
        try alignEndMarker(in: app, editor: editor)

        let initialAnchor = try requireText("TARGET", in: app, editor: editor)
        var previousAnchor = initialAnchor
        let keyboardFrame = keyboard.frame
        let visibleEditor = unobscuredEditor(editor, keyboard: keyboard)
        XCTAssertEqual(
            initialAnchor.midY, visibleEditor.midY,
            accuracy: visibleEditor.height * 0.2,
            "The end caret starts near the middle with whitespace below"
        )
        capture(app, name: "\(mode)-end-before-typing")

        var expected = fixture
        expected += tapLetter(String(firstWord.prefix(1)), in: app)
        previousAnchor = try assertStable(
            app, editor: editor, expected: expected, anchor: previousAnchor,
            keyboardFrame: keyboardFrame, stage: "\(mode)-first-letter"
        )
        if firstWord.count > 1 {
            for letter in firstWord.dropFirst() {
                expected += tapLetter(String(letter), in: app)
            }
            previousAnchor = try assertStable(
                app, editor: editor, expected: expected, anchor: previousAnchor,
                keyboardFrame: keyboardFrame, stage: "\(mode)-first-word"
            )
        }
        for cycle in 1...4 {
            let returnKey = app.buttons.matching(
                NSPredicate(format: "label IN %@", ["Return", "return"])
            ).firstMatch
            XCTAssertTrue(returnKey.exists)
            returnKey.tap()
            expected += "\n" + continuation
            previousAnchor = try assertStable(
                app, editor: editor, expected: expected, anchor: previousAnchor,
                keyboardFrame: keyboardFrame,
                stage: "\(mode)-cycle-\(cycle)-return",
                returnMayAdvance: true
            )
            XCTAssertGreaterThanOrEqual(
                previousAnchor.midY, initialAnchor.midY - CGFloat(32 * cycle) - 8,
                "Repeated Return must move by at most one paragraph per line"
            )
            // Measure the first letter separately: the original failure
            // reverses the Return jump as soon as the next letter arrives.
            expected += tapLetter("t", in: app)
            previousAnchor = try assertStable(
                app, editor: editor, expected: expected, anchor: previousAnchor,
                keyboardFrame: keyboardFrame,
                stage: "\(mode)-cycle-\(cycle)-first-letter"
            )
            for letter in ["e", "s", "t"] {
                expected += tapLetter(letter, in: app)
            }
            previousAnchor = try assertStable(
                app, editor: editor, expected: expected, anchor: previousAnchor,
                keyboardFrame: keyboardFrame,
                stage: "\(mode)-cycle-\(cycle)-word"
            )
            let lastLine = try requireText(
                "test", in: app, editor: editor, last: true
            )
            let visible = unobscuredEditor(editor, keyboard: keyboard)
            XCTAssertGreaterThanOrEqual(lastLine.minY, visible.minY)
            XCTAssertGreaterThanOrEqual(
                lastLine.minY, initialAnchor.minY - 8,
                "The insertion line must stay in place or advance downward"
            )
            XCTAssertLessThan(lastLine.maxY, visible.maxY - 8)
        }
        // Exact suffix readback proves typing stayed at EOF. OCR verifies
        // the final insertion line remains above the software keyboard.
        XCTAssertEqual(editor.value as? String, expected)
    }

    private func checkReopeningKeyboardNearEnd(mode: String) throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += [
            "-editor.mode", mode, "-editor.fontFamily", "monospaced",
            "-editor.fontSize", "13",
        ]
        app.launch()
        let newItem = app.buttons["notebook-new-item"]
        XCTAssertTrue(newItem.waitForExistence(timeout: 20))
        newItem.tap()
        let title = app.textFields["title-field"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        title.typeText("\n")
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))

        var lines = ["# Fictional Cedar journal", ""]
        for week in 1...100 {
            lines += [
                "## Week \(week) — Cedar workshop", "",
                "- Review the fictional agenda with Morgan and prepare the room.",
                "- Check the sample notes before the next community meeting.", "",
            ]
        }
        lines += [
            "## Final discussion", "", "- TARGET Cedar meeting",
            "- Follow up with Morgan.", "- Review the draft agenda.", "",
            "## Remaining items", "", "- Pack the sample folders.",
            "- Check the room booking.", "- Close the fictional journal.",
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
        let lowerBand = app.frame.height * 0.744...app.frame.height * 0.915
        let preferredY = app.frame.height * 0.824
        let dragX = app.frame.maxX - 32
        let dragY = app.frame.height * 0.435
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
        app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: 205, dy: closedTarget.midY)
        ).tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        try requireVisibleCaret(in: app, editor: editor)
        capture(app, name: "\(mode)-cold-focus-keyboard-open")

        let inserted = tapLetter("q", in: app)
        capture(app, name: "\(mode)-cold-focus-first-character")
        // A single Q can be recognized as O at this size. Check the actual
        // insertion caret and exact source bytes after the first key.
        try requireVisibleCaret(in: app, editor: editor)
        let changed = try XCTUnwrap(editor.value as? String)
        let before = Array(fixture.utf16), after = Array(changed.utf16)
        let location = zip(before, after).prefix { $0.0 == $0.1 }.count
        XCTAssertGreaterThanOrEqual(location, before.count - 400)
        let expected = (fixture as NSString).replacingCharacters(
            in: NSRange(location: location, length: 0), with: inserted
        )
        XCTAssertEqual(changed, expected)
        let insertionLine = (fixture as NSString).substring(to: location)
            .components(separatedBy: "\n").count
        print("Cold focus \(mode): inserted \(inserted) on source line \(insertionLine)")
        if try textRects(inserted, in: app, editor: editor).isEmpty {
            capture(app, name: "\(mode)-single-character-OCR-unrecognized")
        }
    }

    private func requireVisibleCaret(
        in app: XCUIApplication, editor: XCUIElement
    ) throws {
        // This fictional note has no links or other blue content. Detect
        // UIKit's blinking caret in actual pixels, without layout queries.
        for _ in 0..<4 {
            let screenshot = app.screenshot()
            let image = try XCTUnwrap(UIImage(data: screenshot.pngRepresentation)?.cgImage)
            let width = image.width, height = image.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            pixels.withUnsafeMutableBytes { bytes in
                let context = CGContext(
                    data: bytes.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                )!
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            let scale = CGFloat(height) / app.frame.height
            let top = Int(max(116, editor.frame.minY) * scale)
            let bottom = Int(min(app.frame.maxY, editor.frame.maxY - 8) * scale)
            var firstRow = height, lastRow = -1
            for y in top..<bottom {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    let red = Int(pixels[offset]), green = Int(pixels[offset + 1])
                    let blue = Int(pixels[offset + 2])
                    if blue > 180, blue > red + 70, blue > green + 50 {
                        firstRow = min(firstRow, y)
                        lastRow = max(lastRow, y)
                    }
                }
            }
            if CGFloat(lastRow - firstRow) >= scale * 6 { return }
            Thread.sleep(forTimeInterval: 0.3)
        }
        capture(app, name: "Focused caret missing above keyboard")
        XCTFail("The caret must be visible when the keyboard opens and typing begins")
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
            menuItem.tap()
        } else {
            let button = app.buttons.matching(
                NSPredicate(format: "label IN %@", labels)
            ).firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 3))
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
            let visible = unobscuredEditor(editor, keyboard: keyboard)
            let marker = try textRects("TARGET", in: app, editor: editor).last
            let delta = marker.map { visible.midY - $0.midY }
                ?? -visible.height * 0.5
            if let marker,
               abs(marker.midY - visible.midY) <= visible.height * 0.15 {
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
            Thread.sleep(forTimeInterval: 0.3)
            XCTAssertTrue(keyboard.exists)
        }
        XCTFail("Could not align the final line near the editor midpoint")
    }

    private func assertStable(
        _ app: XCUIApplication, editor: XCUIElement, expected: String,
        anchor: CGRect, keyboardFrame: CGRect, stage: String,
        returnMayAdvance: Bool = false
    ) throws -> CGRect {
        capture(app, name: stage)
        XCTAssertEqual(editor.value as? String, expected)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.exists)
        XCTAssertEqual(keyboard.frame.minY, keyboardFrame.minY, accuracy: 1)
        XCTAssertEqual(keyboard.frame.height, keyboardFrame.height, accuracy: 1)
        let current = try requireText("TARGET", in: app, editor: editor)
        if returnMayAdvance {
            // At the fixed 13-point monospaced size, native caret following
            // can scroll one new paragraph upward (observed around 23 pt).
            // Allow 32 pt for that advance, while rejecting the original
            // large Return jump and any downward reversal on the next key.
            let movement = current.midY - anchor.midY
            XCTAssertGreaterThanOrEqual(movement, -32)
            XCTAssertLessThanOrEqual(movement, 8)
        } else {
            XCTAssertEqual(
                current.midY, anchor.midY, accuracy: 8,
                "Letters must preserve the position reached after Return"
            )
        }
        return current
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
        _ editor: XCUIElement, keyboard: XCUIElement
    ) -> CGRect {
        let frame = editor.frame
        return CGRect(x: frame.minX, y: frame.minY, width: frame.width,
                      height: min(frame.maxY, keyboard.frame.minY) - frame.minY)
    }

    private func requireText(
        _ text: String, in app: XCUIApplication, editor: XCUIElement,
        last: Bool = false
    ) throws -> CGRect {
        for attempt in 0..<2 {
            let matches = try textRects(text, in: app, editor: editor)
            if let match = last ? matches.last : matches.first { return match }
            if attempt == 0 { Thread.sleep(forTimeInterval: 0.3) }
        }
        capture(app, name: "Missing OCR text: \(text)")
        return try XCTUnwrap(nil as CGRect?, "Visible text missing: \(text)")
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
