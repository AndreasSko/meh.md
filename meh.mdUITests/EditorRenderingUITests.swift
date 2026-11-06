import CoreML
import Vision
import XCTest

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Live Preview draws a bullet or checkbox beside each list item in place of
/// its marker. These tests check what reaches the screen: a drawing that
/// was not repainted after its lines moved stays where they used to be.
/// `EditorRenderingTests` checks the drawing itself, much faster.
///
/// Each check finds the items in a screenshot by their text and expects
/// exactly one mark left of each item's first line, and no mark beside a
/// line known not to start an item. It measures in line heights, never
/// against a saved image, so fonts and screen scales may differ.
@MainActor
final class EditorRenderingUITests: XCTestCase {
    func testListMarksStayBesideTheirItemsAfterTypingAtTheEndAndScrollingBack() throws {
        continueAfterFailure = false
        let app = launch()
        let editor = try open("Field journal", prefix: "# Field journal 1\n", in: app)
        var report = Report()
        try check(app, editor, "opened", into: &report)

        let end = try scrollToLastLine(in: app, editor: editor)
        place(at: CGPoint(x: end.maxX + 6, y: end.midY), in: app)
        editor.typeText(" More notes.")
        XCTAssertTrue(
            (editor.value as? String ?? "").contains("End of the journal. More notes."),
            "The text was not typed at the end"
        )
        try check(app, editor, "typed at the end", into: &report)

        // Uneven steps leave lines cut at the window's edges in many ways.
        let steps: [CGFloat] = [0.7, 0.35, 0.9, 0.5, 0.25]
        var previous = try settledShot(app, editor)
        var reachedTop = false
        for step in 1...80 {
            scroll(byScreens: -steps[step % steps.count], in: app, editor: editor)
            let shot = try settledShot(app, editor)
            if shot.matches(previous) {
                reachedTop = true
                break
            }
            previous = shot
            try check(shot, "scrolled back, step \(step)", into: &report)
        }
        XCTAssertTrue(reachedTop, "Scrolling back did not reach the top")
        report.assertCoverage(items: 35, lists: 10)
    }

    func testListMarksStayBesideTheirItemsAfterSwitchingNotes() throws {
        continueAfterFailure = false
        let app = launch()
        var editor = try open("Field journal", prefix: "# Field journal 1\n", in: app)
        var report = Report()
        for _ in 0..<3 { scroll(byScreens: 0.8, in: app, editor: editor) }
        try check(app, editor, "before switching", into: &report)
        for round in 1...3 {
            editor = try open("Harbor log", prefix: "# Harbor log\n", in: app)
            let companion = report.items.count
            try check(app, editor, "companion note, round \(round)", into: &report)
            if round == 1 {
                XCTAssertGreaterThan(report.items.count, companion,
                                     "The companion note's items were not checked")
            }
            editor = try open("Field journal", prefix: "# Field journal 1\n", in: app)
            try check(app, editor, "back, round \(round)", into: &report)
            scroll(byScreens: -0.45, in: app, editor: editor)
            try check(app, editor, "back and scrolled, round \(round)", into: &report)
        }
        report.assertCoverage(items: 5, lists: 6)
    }

    // MARK: App

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW"] = "1"
        app.launchEnvironment["MEH_NOTEBOOK_PREVIEW_RUN"] = UUID().uuidString
        app.launchEnvironment["MEH_NOTEBOOK_TEST_FIXTURE"] = "rendering"
        app.launchEnvironment["MEH_SYNC_AUTOMATIC"] = "0"
        app.launchEnvironment["MEH_SYNC_CLOUDKIT"] = "0"
        app.launchArguments += [
            "-editor.mode", "livePreview",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
#if os(macOS)
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-NSRequiresAquaSystemAppearance", "YES",
        ]
#else
        XCUIDevice.shared.orientation = .portrait
#endif
        app.launch()
#if os(macOS)
        app.activate()
        enlargeWindow(of: app)
#endif
        addTeardownBlock { app.terminate() }
        return app
    }

#if os(macOS)
    /// A new window can be small; give the note room for a few lists. A
    /// window left partly off screen reports only its visible part, so a
    /// drag by its title bar alone can leave it off screen.
    private func enlargeWindow(of app: XCUIApplication) {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 30))
        let fill = app.menuBars.menuItems["Fill"]
        if fill.exists {
            fill.click()
            waitUntilStill(window)
        } else {
            let frame = window.frame
            let titleBar = window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.width / 2, dy: 4))
            titleBar.click(forDuration: 0.2, thenDragTo: titleBar
                .withOffset(CGVector(dx: 40 - frame.minX, dy: 60 - frame.minY)))
        }
        window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -3, dy: -3))
            .click(forDuration: 0.2, thenDragTo: window
                .coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: 1100, dy: 860)))
        waitUntilStill(window)
    }

    private func waitUntilStill(_ window: XCUIElement) {
        var previous = window.frame
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.25)
            let current = window.frame
            if current == previous { return }
            previous = current
        }
    }
#endif

    /// Opens a note from the sidebar and waits until the editor shows it.
    private func open(
        _ title: String, prefix: String, in app: XCUIApplication
    ) throws -> XCUIElement {
        app.revealNotebookSidebar(timeout: 30)
        let files = app.buttons["notebook-tree-toggle"]
        if files.waitForExistence(timeout: 10), files.value as? String == "Collapsed" {
            activate(files)
        }
        // iOS names the row by its label, the Mac by its value.
        let note = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (label == %@ OR value == %@)",
            "notebook-sidebar-title-", title, title
        )).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 30), "No sidebar row for \(title)")
        let editor = app.textViews["markdown-editor"]
        // A click can land while the sidebar still settles; one retry. An
        // expectation can be waited on only once.
        for _ in 0..<2 {
            let opened = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value BEGINSWITH %@", prefix), object: editor
            )
            activate(note)
            if XCTWaiter.wait(for: [opened], timeout: 10) == .completed { return editor }
        }
        throw Failure(message: "\(title) did not open")
    }

    private struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private func activate(_ element: XCUIElement) {
#if os(macOS)
        element.click()
#else
        element.tap()
#endif
    }

    /// A point on screen. On the Mac the app itself has no frame to offset
    /// from, so its window gives the origin.
    private func coordinate(at point: CGPoint, in app: XCUIApplication) -> XCUICoordinate {
#if os(macOS)
        let window = app.windows.firstMatch
        return window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: point.x - window.frame.minX, dy: point.y - window.frame.minY
        ))
#else
        return app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x, dy: point.y))
#endif
    }

    /// Puts the insertion point at a point inside the visible editor.
    private func place(at point: CGPoint, in app: XCUIApplication) {
        let target = coordinate(at: point, in: app)
#if os(macOS)
        target.click()
#else
        target.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
#endif
    }

    /// Scrolls by a share of the visible text. Positive moves further into
    /// the note. Drags hold still before letting go, so nothing coasts.
    private func scroll(byScreens screens: CGFloat, in app: XCUIApplication, editor: XCUIElement) {
        let area = visibleArea(app, editor)
        let distance = screens * area.height
#if os(macOS)
        // At the visible text: the text view's own middle lies far below,
        // as tall as the whole note.
        coordinate(at: CGPoint(x: area.midX, y: area.midY), in: app)
            .scroll(byDeltaX: 0, deltaY: -distance)
#else
        let x = area.maxX - 30
        let start = coordinate(at: CGPoint(x: x, y: area.midY + distance / 2), in: app)
        let end = coordinate(at: CGPoint(x: x, y: area.midY - distance / 2), in: app)
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow,
                    thenHoldForDuration: 0.4)
#endif
    }

    /// Scrolls until the screen stops changing, then returns the last line
    /// of text. Located by position rather than by reading it: the simplest
    /// recognizer, the only one on virtual Macs, misreads some words.
    private func scrollToLastLine(
        in app: XCUIApplication, editor: XCUIElement
    ) throws -> CGRect {
        var previous = try settledShot(app, editor)
        for _ in 0..<80 {
            scroll(byScreens: 0.85, in: app, editor: editor)
            let shot = try settledShot(app, editor)
            if shot.matches(previous) {
                guard let last = try recognizedLines(in: shot).max(by: {
                    $0.box.maxY < $1.box.maxY
                }) else { break }
                return last.box.offsetBy(dx: shot.frame.minX, dy: shot.frame.minY)
            }
            previous = shot
        }
        throw Failure(message: "Never reached the end of the note")
    }

    // MARK: Screenshots

    /// The editor's visible text, without bars that float over it.
    private struct Shot {
        let image: CGImage
        /// Screen points of the image's area.
        let frame: CGRect
        var size: CGSize { frame.size }
        var scale: CGFloat { CGFloat(image.width) / frame.width }
        let bytes: [UInt8]

        /// Whether both show the same screen, apart from changes a few
        /// points wide, such as the blinking caret.
        func matches(_ other: Shot) -> Bool {
            if bytes == other.bytes { return true }
            guard bytes.count == other.bytes.count else { return false }
            let width = image.width
            let limit = Int(4 * scale)
            var minX = width, maxX = -1
            return bytes.withUnsafeBufferPointer { a in
                other.bytes.withUnsafeBufferPointer { b in
                    a.withMemoryRebound(to: UInt32.self) { a in
                        b.withMemoryRebound(to: UInt32.self) { b in
                            for row in 0..<image.height {
                                let start = row * width
                                guard let first = (start..<start + width)
                                    .first(where: { a[$0] != b[$0] }) else { continue }
                                let last = (start..<start + width).last(where: { a[$0] != b[$0] })!
                                minX = min(minX, first - start)
                                maxX = max(maxX, last - start)
                                if maxX - minX >= limit { return false }
                            }
                            return true
                        }
                    }
                }
            }
        }
    }

    private func visibleArea(_ app: XCUIApplication, _ editor: XCUIElement) -> CGRect {
#if os(macOS)
        var area = editor.frame.intersection(app.windows.firstMatch.frame)
#else
        var area = editor.frame.intersection(app.frame)
#endif
        let bars = (app.toolbars.allElementsBoundByIndex
            + app.navigationBars.allElementsBoundByIndex).map { $0.frame }
        // Some bars report the whole screen as their frame; they hold
        // floating buttons, not a band to leave out.
        for bar in bars where bar.intersects(area) && bar.height < area.height / 3 {
            if bar.midY < area.midY {
                area = CGRect(x: area.minX, y: bar.maxY, width: area.width,
                              height: area.maxY - bar.maxY)
            } else {
                area.size.height = bar.minY - area.minY
            }
        }
#if os(iOS)
        // A keyboard is often taller than a third of the area.
        for keyboard in app.keyboards.allElementsBoundByIndex.map({ $0.frame })
        where keyboard.intersects(area) {
            area.size.height = min(area.height, keyboard.minY - area.minY)
        }
#endif
        // Scroll indicators fade in and out at the right edge.
        area.size.width -= 24
        return area
    }

    private func shot(_ app: XCUIApplication, _ editor: XCUIElement) throws -> Shot {
#if os(macOS)
        let window = app.windows.firstMatch
        let screenshot = window.screenshot()
        let source = window.frame
        var rect = NSRect(origin: .zero, size: screenshot.image.size)
        let full = try XCTUnwrap(screenshot.image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
#else
        let screenshot = XCUIScreen.main.screenshot()
        let source = app.frame
        let full = try XCTUnwrap(screenshot.image.cgImage)
#endif
        let area = visibleArea(app, editor)
        let scale = CGFloat(full.width) / source.width
        let crop = CGRect(
            x: (area.minX - source.minX) * scale, y: (area.minY - source.minY) * scale,
            width: area.width * scale, height: area.height * scale
        ).integral
        let image = try XCTUnwrap(full.cropping(to: crop))
        // Redraw into a known pixel layout for reading and comparing. The
        // context owns its pixels; a Swift array's pointer outlives no call.
        let context = try XCTUnwrap(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.clear(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = [UInt8](UnsafeRawBufferPointer(
            start: try XCTUnwrap(context.data), count: image.width * image.height * 4
        ))
        return Shot(
            image: try XCTUnwrap(context.makeImage()),
            frame: CGRect(x: area.minX, y: area.minY, width: crop.width / scale,
                          height: crop.height / scale),
            bytes: bytes
        )
    }

    /// Waits until two screenshots in a row match, then checks once.
    /// A stable but wrong screen fails; nothing waits for marks to heal.
    private func settledShot(_ app: XCUIApplication, _ editor: XCUIElement) throws -> Shot {
        var previous = try shot(app, editor)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
            let current = try shot(app, editor)
            if current.matches(previous) { return current }
            previous = current
        }
        attach(previous, name: "Editor kept changing", marks: [])
        XCTFail("The editor kept changing for 10 seconds")
        return previous
    }

    // MARK: Reading

    private struct Line {
        let text: String
        /// Points from the shot's top left corner.
        let box: CGRect
        /// The item's name and number, such as “Map 17”, for lines that
        /// start an item.
        let item: String?
        let isTask: Bool
    }

    private static let item = try! NSRegularExpression(
        pattern: #"(Amber lantern|Blue compass|Cedar basket|Map|Route) \d+"#
    )

    private func recognizedLines(in shot: Shot) throws -> [Line] {
        func request(onCPU: Bool, simplest: Bool = false) -> VNRecognizeTextRequest {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = simplest ? .fast : .accurate
            if simplest { request.revision = VNRecognizeTextRequestRevision1 }
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            guard onCPU, let stages = try? request.supportedComputeStageDevices else {
                return request
            }
            for (stage, devices) in stages {
                if let cpu = devices.first(where: {
                    if case .cpu = $0 { return true } else { return false }
                }) {
                    request.setComputeDevice(cpu, for: stage)
                }
            }
            return request
        }
        // The Neural Engine model failed to load on some Macs, so try the
        // CPU first. Virtual Macs, as in CI, may offer no device for the
        // newer models; the first, simplest recognizer is the last resort.
        var results: [VNRecognizedTextObservation]?
        var errors: [String] = []
        for attempt in [request(onCPU: true), request(onCPU: false),
                        request(onCPU: false, simplest: true)] {
            do {
                try VNImageRequestHandler(cgImage: shot.image).perform([attempt])
                results = attempt.results ?? []
                break
            } catch {
                errors.append("\(error)")
            }
        }
        guard let results else {
            throw Failure(message: "Text recognition failed: " + errors.joined(separator: ", "))
        }
        let size = shot.size
        return results.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string
            let box = observation.boundingBox
            var item: String?
            var isTask = false
            // Only a name at the line's start, perhaps after a read bullet.
            if let match = Self.item.firstMatch(
                in: text, range: NSRange(text.startIndex..., in: text)
            ), let range = Range(match.range, in: text),
               text[..<range.lowerBound].allSatisfy({ !$0.isLetter && !$0.isNumber }) {
                item = (text as NSString).substring(with: match.range)
                isTask = ["Map", "Route"].contains(
                    (text as NSString).substring(with: match.range(at: 1))
                )
            }
            return Line(
                text: text,
                box: CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                            width: box.width * size.width, height: box.height * size.height),
                item: item, isTask: isTask
            )
        }
    }

    // MARK: Checking

    private struct Mark {
        let bounds: CGRect
        var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    }

    private struct Report {
        /// Each item checked at least once, by name and number.
        var items = Set<String>()
        var lists = 0

        func assertCoverage(items: Int, lists: Int, file: StaticString = #filePath,
                            line: UInt = #line) {
            XCTAssertGreaterThanOrEqual(self.items.count, items,
                                        "Too few different items were checked",
                                        file: file, line: line)
            XCTAssertGreaterThanOrEqual(self.lists, lists, "Too few screens had items",
                                        file: file, line: line)
        }
    }

    private func check(
        _ app: XCUIApplication, _ editor: XCUIElement, _ name: String,
        into report: inout Report
    ) throws {
        try check(try settledShot(app, editor), name, into: &report)
    }

    /// The note's lists are all at the top level, so their marks sit in one
    /// column at the start of the text, where prose lines start. Recognition
    /// finds that start reliably on prose; on a list line it may count the
    /// mark as text, so the column never comes from list lines.
    private func check(_ shot: Shot, _ name: String, into report: inout Report) throws {
        let lines = try recognizedLines(in: shot)
        let heights = lines.map(\.box.height).sorted()
        guard !heights.isEmpty else { return }
        let height = heights[heights.count / 2]
        let prose = lines.filter { $0.item == nil && $0.box.width > 6 * height }
        guard let textStart = prose.map(\.box.minX).min() else { return }
        // Only lines fully inside the shot, away from cut edges.
        let items = lines.filter {
            $0.item != nil && $0.box.minY > height && $0.box.maxY < shot.size.height - height
        }
        guard !items.isEmpty else { return }
        report.items.formUnion(items.compactMap(\.item))
        report.lists += 1
        let paper = paperColor(of: shot)
        var marks: [Mark] = []
        var failures: [(String, CGRect)] = []
        for item in items {
            // Checkboxes reach further right than bullets; neither reaches
            // the item's first letter.
            let area = CGRect(
                x: textStart - 0.5 * height, y: item.box.midY - 1.6 * height,
                width: (item.isTask ? 2.1 : 1.1) * height, height: 3.2 * height
            )
            for mark in merged(components(in: area, of: shot, paper: paper))
            where !marks.contains(where: { $0.bounds.intersects(mark.bounds) }) {
                let size: ClosedRange<CGFloat> = item.isTask ? 10...30 : 1.5...9
                // Prose that starts in the column is not a mark.
                guard size.contains(mark.bounds.width), size.contains(mark.bounds.height),
                      !prose.contains(where: { $0.box.intersects(mark.bounds) })
                else { continue }
                marks.append(mark)
            }
        }
        let tolerance = 0.45 * height
        for item in items {
            let beside = marks.filter { abs($0.center.y - item.box.midY) <= tolerance }
            if beside.count != 1 {
                failures.append(("\(beside.count) marks beside “\(item.text)”", item.box))
            }
        }
        // A mark level with a line that starts no item, or with no line at
        // all, belongs to no item. Lines cut at the edges stay unjudged.
        for mark in marks
        where mark.center.y > 1.5 * height && mark.center.y < shot.size.height - 1.5 * height {
            let level = lines.filter { abs(mark.center.y - $0.box.midY) <= tolerance }
            if level.contains(where: { $0.item != nil }) { continue }
            // Recognition may read the mark itself as a letter, such as “J”.
            if let line = level.first(where: { !$0.box.intersects(mark.bounds) }) {
                failures.append(("A mark beside “\(line.text)”, which starts no item",
                                 mark.bounds))
            } else {
                failures.append(("A mark beside no line at y \(Int(mark.center.y))",
                                 mark.bounds))
            }
        }
        guard !failures.isEmpty else { return }
        attach(shot, name: name, marks: failures.map(\.1))
        // What recognition read and which marks it found, to tell a drawing
        // bug from a misreading.
        let details = ["text starts at \(Int(textStart)), line height \(Int(height))"]
            + lines.map { "line \($0.box.integral) “\($0.text)”" }
            + marks.map { "mark \($0.bounds.integral)" }
        let diagnostics = XCTAttachment(string: details.joined(separator: "\n"))
        diagnostics.name = name + " details"
        diagnostics.lifetime = .keepAlways
        add(diagnostics)
        XCTFail("\(name): " + failures.map(\.0).joined(separator: "\n"))
    }

    /// A faint outline, such as an empty checkbox, can break into pieces
    /// where it crosses pixels; pieces close together are one mark.
    private func merged(_ pieces: [Mark]) -> [Mark] {
        var marks: [Mark] = []
        for piece in pieces {
            var bounds = piece.bounds
            while let index = marks.firstIndex(where: {
                $0.bounds.insetBy(dx: -1.5, dy: -1.5).intersects(bounds)
            }) {
                bounds = bounds.union(marks.remove(at: index).bounds)
            }
            marks.append(Mark(bounds: bounds))
        }
        return marks
    }

    private func paperColor(of shot: Shot) -> [Int] {
        // The editor's left margin, below any cut line.
        let x = 4 * Int(shot.scale)
        let colors = stride(from: 0, to: shot.image.height, by: 7).map { y in
            pixel(x, y, of: shot)
        }
        return (0..<3).map { channel in colors.map { $0[channel] }.sorted()[colors.count / 2] }
    }

    private func pixel(_ x: Int, _ y: Int, of shot: Shot) -> [Int] {
        let index = (y * shot.image.width + x) * 4
        return [Int(shot.bytes[index]), Int(shot.bytes[index + 1]), Int(shot.bytes[index + 2])]
    }

    /// Touching pixels clearly darker or lighter than the paper.
    private func components(in rect: CGRect, of shot: Shot, paper: [Int]) -> [Mark] {
        let scale = shot.scale
        let xs = max(0, Int(rect.minX * scale))..<min(shot.image.width, Int(rect.maxX * scale))
        let ys = max(0, Int(rect.minY * scale))..<min(shot.image.height, Int(rect.maxY * scale))
        guard !xs.isEmpty, !ys.isEmpty else { return [] }
        func ink(_ x: Int, _ y: Int) -> Bool {
            zip(pixel(x, y, of: shot), paper).map { abs($0 - $1) }.max()! >= 40
        }
        var seen = Set<Int>()
        var result: [Mark] = []
        for y in ys {
            for x in xs where !seen.contains(y * shot.image.width + x) && ink(x, y) {
                var stack = [(x, y)]
                seen.insert(y * shot.image.width + x)
                var minX = x, maxX = x, minY = y, maxY = y
                while let (px, py) = stack.popLast() {
                    minX = min(minX, px); maxX = max(maxX, px)
                    minY = min(minY, py); maxY = max(maxY, py)
                    for (nx, ny) in [(px + 1, py), (px - 1, py), (px, py + 1), (px, py - 1)]
                    where xs.contains(nx) && ys.contains(ny)
                        && !seen.contains(ny * shot.image.width + nx) && ink(nx, ny) {
                        seen.insert(ny * shot.image.width + nx)
                        stack.append((nx, ny))
                    }
                }
                result.append(Mark(bounds: CGRect(
                    x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                    width: CGFloat(maxX - minX + 1) / scale,
                    height: CGFloat(maxY - minY + 1) / scale
                )))
            }
        }
        return result
    }

    private func attach(_ shot: Shot, name: String, marks: [CGRect]) {
        let scale = shot.scale
        guard let context = CGContext(
            data: nil, width: shot.image.width, height: shot.image.height,
            bitsPerComponent: 8, bytesPerRow: shot.image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        let height = CGFloat(shot.image.height)
        context.draw(shot.image, in: CGRect(x: 0, y: 0, width: shot.image.width,
                                            height: shot.image.height))
        context.setStrokeColor(red: 1, green: 0, blue: 0.3, alpha: 0.9)
        context.setLineWidth(scale)
        for mark in marks {
            context.stroke(CGRect(
                x: mark.minX * scale, y: height - mark.maxY * scale,
                width: mark.width * scale, height: mark.height * scale
            ).insetBy(dx: -3, dy: -3))
        }
        guard let image = context.makeImage() else { return }
#if os(macOS)
        let attachment = XCTAttachment(image: NSImage(cgImage: image, size: .zero))
#else
        let attachment = XCTAttachment(image: UIImage(cgImage: image))
#endif
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
