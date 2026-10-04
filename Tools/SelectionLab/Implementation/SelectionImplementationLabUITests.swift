import XCTest

#if os(iOS)
@MainActor
final class SelectionImplementationLabUITests: XCTestCase {
    func testNativeFindRevealsDistantMatch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let mode = ProcessInfo.processInfo.environment["LAB_EDITOR"] ?? "livePreview"
        let label = ProcessInfo.processInfo.environment["LAB_CAPTURE"] ?? "after"
        app.launchEnvironment["MEH_SELECTION_IMPLEMENTATION"] = "1"
        app.launchEnvironment["MEH_SELECTION_EDITOR"] = mode
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launch()
        defer { app.terminate() }
        let editor = app.textViews["implementation-editor"]
        let metrics = app.staticTexts["implementation-metrics"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        app.buttons["implementation-find"].tap()
        let field = app.searchFields["find.searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("ORBITAL LANTERN")
        XCTAssertTrue(app.staticTexts["1 of 1"].waitForExistence(timeout: 5))
        capture(app, metrics, "\(label)-\(mode)-find-before-visibility-check")
        _ = try waitFindSelection(app, editor, field, metrics)
        capture(app, metrics, "\(label)-\(mode)-find-visible")
    }

    func testNativeSelectionScrollingAndEditing() throws {
        continueAfterFailure = false
        let mode = ProcessInfo.processInfo.environment["LAB_EDITOR"] ?? "livePreview"
        let label = ProcessInfo.processInfo.environment["LAB_CAPTURE"] ?? "after"
        let app = XCUIApplication()
        app.launchEnvironment["MEH_SELECTION_IMPLEMENTATION"] = "1"
        app.launchEnvironment["MEH_SELECTION_EDITOR"] = mode
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launch()
        defer { app.terminate() }
        let editor = app.textViews["implementation-editor"]
        let metrics = app.staticTexts["implementation-metrics"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertTrue(metrics.waitForExistence(timeout: 5))
        let root = app.coordinate(withNormalizedOffset: .zero)
        editor.swipeUp(velocity: .slow)
        editor.swipeUp(velocity: .slow)
        let scrolled = try read(metrics)
        XCTAssertGreaterThan(number(scrolled, "y"), 100)
        let word = try XCTUnwrap(scrolled["word"] as? [String: Any])
        XCTAssertFalse(word.isEmpty, "A native selectable word must be located")
        capture(app, metrics, "\(label)-\(mode)-midnote-before-selection")
        root.withOffset(CGVector(dx: number(word, "x"), dy: number(word, "y")))
            .doubleTap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let selected = try waitSelection(metrics)
        XCTAssertGreaterThan(integer(selected, "length"), 0)
        XCTAssertFalse((selected["selectedText"] as? String ?? "").isEmpty)
        capture(app, metrics, "\(label)-\(mode)-native-selected")
        app.buttons["implementation-reset"].tap()
        let prepared = try read(metrics)
        let initialY = number(prepared, "y")
        let initialLocation = integer(prepared, "location")
        let initialLength = integer(prepared, "length")
        let endpoint = try XCTUnwrap(prepared["end"] as? [String: Any])
        let target = root.withOffset(CGVector(
            dx: number(endpoint, "x"), dy: visibleBottom(app, editor) + 20))
        root.withOffset(CGVector(dx: number(endpoint, "x"),
                                 dy: number(endpoint, "y") + 5))
            .press(forDuration: 0.15, thenDragTo: target,
                   withVelocity: .slow, thenHoldForDuration: 3)
        let extended = try read(metrics)
        capture(app, metrics, "\(label)-\(mode)-edge-selection")
        XCTAssertGreaterThan(integer(extended, "length"), initialLength,
                             "The gesture must adjust a native selection handle")
        if label != "before" {
            XCTAssertEqual(integer(extended, "location"), initialLocation,
                           "Native selection must retain its starting anchor")
            XCTAssertLessThanOrEqual(abs(number(extended, "y") - initialY), 5,
                                     "Native edge selection must not scroll the viewport")
            XCTAssertLessThanOrEqual(number(extended, "maxY") - number(extended, "minY"), 5)
        }
        if label == "before" {
            app.buttons["implementation-find"].tap()
            let field = app.searchFields["find.searchField"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.typeText("ORBITAL LANTERN")
            XCTAssertTrue(app.staticTexts["1 of 1"].waitForExistence(timeout: 5))
            _ = try waitFindSelection(app, editor, field, metrics)
            capture(app, metrics, "\(label)-\(mode)-native-find")
            return
        }
        let oldRange = NSRange(location: integer(extended, "location"),
                               length: integer(extended, "length"))
        let selectionStart = try XCTUnwrap(extended["start"] as? [String: Any])
        let manualStart = root.withOffset(CGVector(dx: editor.frame.maxX - 30,
            dy: min(visibleBottom(app, editor) - 25,
                    max(editor.frame.minY + 70, number(selectionStart, "top") - 40))))
        let manualEnd = root.withOffset(CGVector(dx: editor.frame.maxX - 30,
                                                 dy: editor.frame.minY + 20))
        manualStart.press(forDuration: 0.05, thenDragTo: manualEnd)
        let manuallyScrolled = try read(metrics)
        capture(app, metrics, "\(label)-\(mode)-manual-scroll")
        XCTAssertEqual(integer(manuallyScrolled, "location"), oldRange.location)
        XCTAssertEqual(integer(manuallyScrolled, "length"), oldRange.length)
        XCTAssertGreaterThan(number(manuallyScrolled, "y"), number(extended, "y") + 30)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        root.withOffset(CGVector(dx: editor.frame.maxX - 30,
                                 dy: visibleBottom(app, editor) - 180))
            .press(forDuration: 0.05, thenDragTo:
                root.withOffset(CGVector(dx: editor.frame.maxX - 30,
                                         dy: visibleBottom(app, editor) - 25)))
        let returned = try read(metrics)
        capture(app, metrics, "\(label)-\(mode)-manual-return")
        XCTAssertEqual(integer(returned, "location"), oldRange.location)
        XCTAssertEqual(integer(returned, "length"), oldRange.length)
        let continuedEnd = try XCTUnwrap(returned["nativeEnd"] as? [String: Any])
        let visibleY = number(continuedEnd, "y")
        XCTAssertGreaterThan(visibleY, editor.frame.minY)
        XCTAssertLessThan(visibleY, visibleBottom(app, editor))
        let continuedStart = try XCTUnwrap(returned["start"] as? [String: Any])
        let anchorY = number(continuedStart, "top")
        let continuationY = max(visibleY - 60, anchorY + 16)
        XCTAssertLessThan(continuationY, visibleY,
                          "A visible endpoint must leave room above it and below its anchor")
        root.withOffset(CGVector(dx: number(continuedEnd, "x"), dy: visibleY + 5))
            .press(forDuration: 0.15, thenDragTo:
                root.withOffset(CGVector(dx: number(continuedEnd, "x"),
                                         dy: continuationY)),
                   withVelocity: .slow, thenHoldForDuration: 0.2)
        let continued = try read(metrics)
        capture(app, metrics, "\(label)-\(mode)-continued-selection")
        XCTAssertEqual(integer(continued, "location"), oldRange.location)
        XCTAssertNotEqual(integer(continued, "length"), oldRange.length)
        XCTAssertGreaterThan(integer(continued, "length"), 0)
        let textBefore = try XCTUnwrap(continued["text"] as? String)
        let replacementRange = NSRange(location: integer(continued, "location"),
                                        length: integer(continued, "length"))
        let replacement = "Replaced fictional passage"
        let expected = (textBefore as NSString).replacingCharacters(
            in: replacementRange, with: replacement)
        app.typeText(replacement)
        let replaced = try read(metrics)
        XCTAssertEqual(replaced["text"] as? String, expected)
        XCTAssertEqual(integer(replaced, "length"), 0)
        capture(app, metrics, "\(label)-\(mode)-typing-replacement")
        app.buttons["implementation-find"].tap()
        let field = app.searchFields["find.searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("ORBITAL LANTERN")
        XCTAssertTrue(app.staticTexts["1 of 1"].waitForExistence(timeout: 5))
        let found = try waitFindSelection(app, editor, field, metrics)
        XCTAssertGreaterThan(number(found, "y"), number(replaced, "y") + 100)
        capture(app, metrics, "\(label)-\(mode)-native-find")
        app.buttons["find.doneButton"].tap()
        let rotationText = try XCTUnwrap(try read(metrics)["text"] as? String)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        capture(app, metrics, "\(label)-\(mode)-landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertEqual(try read(metrics)["text"] as? String, rotationText)
        capture(app, metrics, "\(label)-\(mode)-portrait")
    }

    private func visibleBottom(_ app: XCUIApplication, _ editor: XCUIElement) -> Double {
        let keyboard = app.keyboards.firstMatch
        return keyboard.exists
            ? min(editor.frame.maxY, keyboard.frame.minY - 58)
            : editor.frame.maxY
    }

    private func waitFindSelection(
        _ app: XCUIApplication, _ editor: XCUIElement,
        _ field: XCUIElement, _ metrics: XCUIElement
    ) throws -> [String: Any] {
        let found = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let state = try? self.read(metrics),
                  state["selectedText"] as? String == "ORBITAL LANTERN" else {
                return false
            }
            let native = state["nativeEnd"] as? [String: Any] ?? [:]
            let endpoint = native.isEmpty
                ? (state["end"] as? [String: Any] ?? [:]) : native
            let bottom = min(self.visibleBottom(app, editor), field.frame.minY)
            return self.number(endpoint, "top") >= editor.frame.minY
                && self.number(endpoint, "y") <= bottom
        }, object: metrics)
        XCTAssertEqual(XCTWaiter.wait(for: [found], timeout: 5), .completed,
                       "Native Find must expose the match through the public selection "
                       + "and place its endpoint above the Find field. A highlight without "
                       + "a matching public range does not establish this visibility check.")
        return try read(metrics)
    }

    private func waitSelection(_ metrics: XCUIElement) throws -> [String: Any] {
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let d = try? self.read(metrics) else { return false }
            return self.integer(d, "length") > 0 && d["firstResponder"] as? Bool == true
        }, object: metrics)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
        return try read(metrics)
    }
    private func read(_ metrics: XCUIElement) throws -> [String: Any] {
        let raw = try XCTUnwrap(metrics.value as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }
    private func number(_ d: [String: Any], _ key: String) -> Double {
        (d[key] as? NSNumber)?.doubleValue ?? -1
    }
    private func integer(_ d: [String: Any], _ key: String) -> Int {
        (d[key] as? NSNumber)?.intValue ?? -1
    }
    private func capture(_ app: XCUIApplication, _ metrics: XCUIElement, _ name: String) {
        let screen = XCTAttachment(screenshot: app.screenshot())
        screen.name = name
        screen.lifetime = .keepAlways
        add(screen)
        let detail = XCTAttachment(string: "\(metrics.value ?? "")\n\(app.debugDescription)")
        detail.name = name + "-telemetry"
        detail.lifetime = .keepAlways
        add(detail)
        if let state = try? read(metrics) {
            let reduced = state.filter { $0.key != "text" && $0.key != "trace" }
            if let data = try? JSONSerialization.data(withJSONObject: reduced, options: .sortedKeys) {
                print("IMPLEMENTATION_LAB \(name) \(String(decoding: data, as: UTF8.self))")
            }
        }
    }
}
#endif
