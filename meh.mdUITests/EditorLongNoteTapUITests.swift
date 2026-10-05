import XCTest
import Vision

#if os(iOS)
import UIKit

final class EditorLongNoteTapUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        XCUIDevice.shared.orientation = .portrait
    }

    func testTapNearEndReplacesPreviousEOFSelection() throws {
        try runGesture()
    }
    private func runGesture() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = "long-note-tap-" + UUID().uuidString
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchArguments += ["-editor.mode", "livePreview", "-editor.fontFamily", "monospaced", "-editor.fontSize", "15"]
        app.launch()
        let newItem = app.buttons["notebook-new-item"]
        XCTAssertTrue(newItem.waitForExistence(timeout: 20))
        newItem.tap()
        let title = app.textFields["title-field"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        title.typeText("Fictional Cedar workshop\n")
        let editor = app.textViews["markdown-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let original = Self.fictionalNote()
        UIPasteboard.general.string = original
        editor.typeText("Test")
        let seed = try XCTUnwrap(marker(app, needle: "Test"))
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: seed.x, dy: seed.y)).doubleTap()
        let paste = app.menuItems.matching(NSPredicate(format: "label IN %@", ["Paste", "Einsetzen"])).firstMatch
        let pasteButton = app.buttons.matching(NSPredicate(format: "label IN %@", ["Paste", "Einsetzen"])).firstMatch
        if paste.waitForExistence(timeout: 2) {
            UIPasteboard.general.string = original
            paste.tap()
        } else {
            XCTAssertTrue(pasteButton.waitForExistence(timeout: 3))
            UIPasteboard.general.string = original
            pasteButton.tap()
        }
        let allow = app.alerts.buttons["Allow Paste"].firstMatch
        if allow.waitForExistence(timeout: 1) { allow.tap() }
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(editor.value as? String, original)
        snap(app, "01-pasted-long-note")
        // Keep native EOF selection from paste, then dismiss and manually scroll.
        let dragStart = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.maxX - 6, dy: app.frame.height * 0.52))
        let dragEnd = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.maxX - 6, dy: app.frame.maxY - 65))
        dragStart.press(forDuration: 0.01, thenDragTo: dragEnd, withVelocity: XCUIGestureVelocity(rawValue: 800), thenHoldForDuration: 0.1)
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        var header = try marker(app, needle: "01.10")
        for _ in 0..<8 {
            if header != nil { break }
            if try marker(app, needle: "03.10") != nil { editor.swipeDown() }
            else { editor.swipeUp() }
            header = try marker(app, needle: "01.10")
        }
        XCTAssertNotNil(header)
        for _ in 0..<4 {
            guard let current = header else { break }
            if (261...271).contains(current.y) { break }
            let requested = 266 - current.y
            let displacement = min(260, max(-260, requested + (requested < 0 ? -10 : 10)))
            let from = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 370, dy: 380))
            let to = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 370, dy: 380 + displacement))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: XCUIGestureVelocity(rawValue: 100), thenHoldForDuration: 0.7)
            header = try marker(app, needle: "01.10")
        }
        XCTAssertTrue((261...271).contains(try XCTUnwrap(header).y))
        let target = try XCTUnwrap(marker(app, needle: "TARGET Cedar Curls"))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        snap(app, "before-tap-closed-keyboard")
        print("LONG_NOTE_TAP t=\(Date().timeIntervalSince1970) target=\(target) intendedLine=750")
        // Tap the numeric suffix to avoid selecting a spellchecked word.
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 280, dy: target.y)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        snap(app, "after-tap-keyboard-open")
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width * 0.5 + 2, dy: app.frame.height - 221)).tap()
        snap(app, "first-character")
        let finalText = editor.value as? String ?? ""
        let oldUnits = Array(original.utf16), newUnits = Array(finalText.utf16)
        var insertedLines: [Int] = []
        var removedCount = 0
        for change in newUnits.difference(from: oldUnits) {
            switch change {
            case .insert(let offset, let value, _):
                let line = newUnits.prefix(offset).filter { $0 == 10 }.count + 1
                insertedLines.append(line)
                print("LONG_NOTE_INSERT offset=\(offset) UTF16value=\(value) line=\(line)")
            case .remove(let offset, let value, _):
                removedCount += 1
                print("LONG_NOTE_REMOVE offset=\(offset) UTF16value=\(value)")
            }
        }
        XCTAssertEqual(removedCount, 0)
        XCTAssertEqual(insertedLines, [750], "Tap must insert into the intended Cedar Curls paragraph")
    }

    private static func fictionalNote() -> String {
        var lines = ["", "Fictional Cedar workshop log.  "]
        let names = ["Cedar", "Wren", "Maple", "Elm", "Birch", "Pine"]
        for line in 3...744 {
            let slot = (line - 3) % 14
            if slot == 0 { lines.append("") }
            else if slot == 1 {
                lines.append("Session \((line - 3) / 14 + 1) – Fictional plans  ")
            } else if slot == 2 {
                lines.append("- \(names[line % 6]) review: a longer fictional discussion with sample values 4, 6, 8  ")
            } else {
                lines.append("- \(names[line % 6]) sample \(slot): 10, 12, 14  ")
            }
        }
        lines += [
            "01.10 – Fictional session  ",
            "- Cedar introduction: 4, 6, 8  ",
            "- Cedar Rows: 20  ",
            "- Wren followup: 6, 6, 6  ",
            "- TARGET Wren Flys: 12, 10, 8  ",
            "- TARGET Cedar Curls: 10, 12, 14  ",
            "- Cedar cooldown: 30s, 45s  ",
            "- Wren room check: 3, 5  ",
            "- Elm sample: 12, 14  ",
            "- Pine sample: 6, 8  ", "",
            "03.10 – Fictional wrapup  ",
        ]
        while lines.count < 774 {
            let n = lines.count + 1
            lines.append("- Final \(names[n % 6]) check \(n): 9, 12  ")
        }
        return lines.joined(separator: "\n") + "\n"
    }


    private func marker(_ app: XCUIApplication, needle: String) throws -> CGPoint? {
        let screenshot = app.screenshot()
        let image = UIImage(data: screenshot.pngRepresentation)!.cgImage!
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image).perform([request])
        func normalized(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let entries = request.results ?? []
        let requiresLastBlock = needle != "Test" && needle != "01.10" && needle != "03.10"
        let header = entries.first { normalized($0.topCandidates(1).first?.string ?? "").contains("0110fictionalsession") }
        if requiresLastBlock && header == nil { return nil }
        let result = entries.first { candidate in
            guard normalized(candidate.topCandidates(1).first?.string ?? "").contains(normalized(needle)) else { return false }
            guard requiresLastBlock, let header else { return true }
            return candidate.boundingBox.midY < header.boundingBox.midY && candidate.boundingBox.midY > header.boundingBox.midY - 0.35
        }
        if let result {
            let b = result.boundingBox
            let point = CGPoint(x: b.midX * app.frame.width, y: (1 - b.midY) * app.frame.height)
            print("GESTURE_MARKER point=\(point) text=\(result.topCandidates(1).first!.string)")
            return point
        }
        return nil
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        print("GESTURE_SNAP \(name) state=\(app.state.rawValue)")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
#endif
