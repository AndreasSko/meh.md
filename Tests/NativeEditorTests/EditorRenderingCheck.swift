import CoreGraphics
import Foundation
import XCTest

/// Checks a rendered editor against where the fixture's decorations belong.
/// Expected places come from the lines TextKit laid out for the note's own
/// text (an item's first word, a quote's first and last character), never
/// from the decoration code under test. Only decorations whose lines are
/// laid out and fully on screen are checked; the rest wait for a scroll.
@MainActor
struct EditorRenderingCheck {
    struct Failure {
        let message: String
        let rect: CGRect
    }

    let harness: EditorRenderingHarness
    let fixture: EditorRenderingFixture
    let image: EditorRenderingImage
    private(set) var failures: [Failure] = []
    /// How many decorations were on screen and checked.
    private(set) var checked = 0

    init(_ harness: EditorRenderingHarness, _ fixture: EditorRenderingFixture, scale: CGFloat) {
        self.harness = harness
        self.fixture = fixture
        image = harness.render(scale: scale)
        if harness.plainLines > 0 {
            fail("\(harness.plainLines) lines drew without the editor's line fragment",
                 harness.visibleRect)
        }
        checkLists()
        checkPanels()
        checkRules()
        checkTotals()
        checkHistoryMarks()
    }

    private var visible: CGRect { harness.visibleRect.insetBy(dx: 0, dy: 2) }

    /// The first and last line of a range, when both are laid out on screen.
    private func lines(of range: NSRange) -> (first: CGRect, last: CGRect)? {
        guard range.length > 0,
              let first = harness.lineRect(at: range.location),
              let last = harness.lineRect(at: NSMaxRange(range) - 1),
              visible.contains(CGPoint(x: first.midX, y: first.minY)),
              visible.contains(CGPoint(x: last.midX, y: last.maxY)) else { return nil }
        return (first, last)
    }

    private mutating func fail(_ message: String, _ rect: CGRect) {
        failures.append(Failure(message: message, rect: rect))
    }

    // MARK: Bullets and checkboxes

    /// Each item has exactly one mark left of its first line, and the
    /// column holds nothing else: no mark beside a wrapped line, none
    /// between items.
    private mutating func checkLists() {
        for list in fixture.lists {
            let items = list.items.map { lines(of: $0) }
            guard let firstItem = items.first, let first = firstItem,
                  let lastItem = items.last, let last = lastItem,
                  !items.contains(where: { $0 == nil }) else { continue }
            let lineHeight = first.first.height
            let textStart = items.map { $0!.first.minX }.min()!
            let width = (list.isTaskList ? 2.4 : 1.6) * lineHeight
            let gutter = CGRect(
                x: textStart - width, y: first.first.minY,
                width: width - 1, height: last.last.maxY - first.first.minY
            )
            let size: ClosedRange<CGFloat> = list.isTaskList ? 12...28 : 1.5...8
            var marks = image.components(in: gutter, threshold: 40)
            let kind = list.isTaskList ? "checkbox" : "bullet"
            for (index, item) in items.enumerated() {
                let line = item!.first
                let label = (fixture.source as NSString).substring(with: list.items[index])
                let beside = marks.indices.filter {
                    abs(marks[$0].center.y - line.midY) <= 0.3 * lineHeight
                }
                checked += 1
                guard beside.count == 1 else {
                    fail("\(beside.count) \(kind)s beside “\(label)”, expected 1",
                         CGRect(x: gutter.minX, y: line.minY, width: gutter.width,
                                height: line.height))
                    continue
                }
                let mark = marks.remove(at: beside[0])
                if !size.contains(mark.bounds.width) || !size.contains(mark.bounds.height) {
                    fail("The \(kind) beside “\(label)” is \(mark.bounds.size), expected "
                         + "\(size) points", mark.bounds)
                }
            }
            for mark in marks where mark.pixelCount > 1 {
                fail("A stray mark in the \(kind) column at y \(mark.center.y)", mark.bounds)
            }
        }
    }

    // MARK: Quote and code panels

    /// A panel covers its lines from the first to the last in one even
    /// color: no gap and no darker band where two lines' drawings overlap.
    private mutating func checkPanels() {
        let column = harness.textColumn
        for panel in fixture.panels {
            guard let lines = lines(of: panel.range) else { continue }
            checked += 1
            let rows = image.pixelY(lines.first.midY)..<image.pixelY(lines.last.midY)
            // Right of the panel's short lines, where only the panel draws.
            for x in [column.upperBound - 6, column.lowerBound + 0.85 * (column.upperBound
                - column.lowerBound)] {
                let pixelX = image.pixelX(x)
                let colors = rows.map { image.color(x: pixelX, y: $0) }
                let median = EditorRenderingImage.Color(
                    red: colors.map(\.red).sorted()[colors.count / 2],
                    green: colors.map(\.green).sorted()[colors.count / 2],
                    blue: colors.map(\.blue).sorted()[colors.count / 2]
                )
                let rect = CGRect(x: x - 2, y: lines.first.midY, width: 4,
                                  height: lines.last.midY - lines.first.midY)
                guard median.distance(to: image.paper) >= 3 else {
                    fail("No \(panel.kind) panel behind its lines", rect)
                    continue
                }
                if let row = rows.first(where: {
                    image.color(x: pixelX, y: $0).distance(to: median) > 6
                }) {
                    let y = image.pointY(row)
                    fail("The \(panel.kind) panel changes color at y \(y)",
                         CGRect(x: x - 4, y: y - 1, width: 8, height: 2))
                }
            }
        }
    }

    // MARK: Rules

    /// One thin line across the text column, centered on the rule's own
    /// line, and none of the hidden `---` showing.
    private mutating func checkRules() {
        let column = harness.textColumn
        for rule in fixture.rules {
            guard let line = lines(of: NSRange(location: rule, length: 3))?.first
            else { continue }
            checked += 1
            let area = image.pixels(in: CGRect(
                x: column.lowerBound + 4, y: line.minY,
                width: column.upperBound - column.lowerBound - 8, height: line.height
            ))
            var full: [Int] = []
            for y in area.y {
                let ink = area.x.filter { image.isInk(x: $0, y: y, threshold: 15) }.count
                let coverage = Double(ink) / Double(area.x.count)
                if coverage >= 0.9 {
                    full.append(y)
                } else if coverage > 0.03 {
                    fail("Something besides the rule's line shows at y \(image.pointY(y))",
                         CGRect(x: column.lowerBound, y: image.pointY(y),
                                width: column.upperBound - column.lowerBound, height: 1))
                    break
                }
            }
            guard let top = full.first, let bottom = full.last else {
                fail("No rule line", line)
                continue
            }
            let center = (image.pointY(top) + image.pointY(bottom + 1)) / 2
            if CGFloat(bottom - top + 1) / image.scale > 2.5
                || abs(center - line.midY) > 0.3 * line.height {
                fail("The rule's line spans y \(image.pointY(top))–\(image.pointY(bottom + 1)), "
                     + "expected a thin line around \(line.midY)", line)
            }
        }
    }

    // MARK: Time calculator

    /// The sum appears right after `Total =`, on the same line.
    private mutating func checkTotals() {
        guard harness.options.timeCalculator else { return }
        for total in fixture.totals {
            guard let line = lines(of: NSRange(location: total, length: 1))?.first
            else { continue }
            checked += 1
            // Only its own line: a sum a line off leaves this band empty.
            let area = CGRect(
                x: line.maxX + 1, y: line.minY,
                width: min(6 * line.height, harness.textColumn.upperBound - line.maxX - 1),
                height: line.height
            )
            let ink = image.components(in: area, threshold: 40)
            guard !ink.isEmpty else {
                fail("No sum after “Total =”", area)
                continue
            }
            let bounds = ink.map(\.bounds).reduce(CGRect.null) { $0.union($1) }
            if abs(bounds.midY - line.midY) > 0.3 * line.height {
                fail("The sum is centered at y \(bounds.midY), its line at \(line.midY)",
                     bounds)
            }
        }
    }

    // MARK: History marks

    /// A bar left of the text beside every line of a changed paragraph,
    /// and nothing beside unchanged lines.
    private mutating func checkHistoryMarks() {
        guard !harness.options.historyChanges.isEmpty else { return }
        let x = harness.containerOrigin.x - 7
        let columnRect = { (top: CGFloat, bottom: CGFloat) in
            CGRect(x: x - 2, y: top, width: 4, height: bottom - top)
        }
        var changedRows = IndexSet()
        for range in fixture.changedRanges {
            guard let lines = lines(of: range) else { continue }
            checked += 1
            let rect = columnRect(lines.first.minY + 2, lines.last.maxY - 2)
            let area = image.pixels(in: rect)
            let marked = area.y.filter { y in
                area.x.contains { image.isInk(x: $0, y: y, threshold: 30) }
            }.count
            if Double(marked) < 0.9 * Double(area.y.count) {
                fail("The history bar covers \(marked) of \(area.y.count) rows beside a "
                     + "changed paragraph", rect)
            }
            changedRows.insert(integersIn: image.pixels(in: columnRect(
                lines.first.minY - lines.first.height / 2,
                lines.last.maxY + lines.last.height / 2
            )).y)
        }
        let all = image.pixels(in: columnRect(visible.minY, visible.maxY))
        if let stray = all.y.first(where: { y in
            !changedRows.contains(y)
                && all.x.contains { image.isInk(x: $0, y: y, threshold: 30) }
        }) {
            fail("A history mark beside an unchanged line at y \(image.pointY(stray))",
                 columnRect(image.pointY(stray) - 2, image.pointY(stray) + 2))
        }
    }

    // MARK: Reporting

    /// Fails the test with every finding and attaches the marked image.
    func assertPasses(
        _ name: String, in test: XCTestCase,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let environment = ProcessInfo.processInfo.environment
        let directory = environment["EDITOR_RENDERING_ARTIFACTS"]
        if failures.isEmpty, directory != nil, environment["EDITOR_RENDERING_ALL"] == "1" {
            save(image.png(marking: []), name: name, in: directory!)
        }
        guard !failures.isEmpty else { return }
        let png = image.png(marking: failures.map(\.rect))
        if let png {
            let attachment = XCTAttachment(
                data: png, uniformTypeIdentifier: "public.png"
            )
            attachment.name = name
            attachment.lifetime = .keepAlways
            test.add(attachment)
            if let directory { save(png, name: name, in: directory) }
        }
        XCTFail(
            "\(name): " + failures.map(\.message).joined(separator: "\n"),
            file: file, line: line
        )
    }

    /// Keeps the image outside the test results, for CI artifacts or a look.
    private func save(_ png: Data?, name: String, in directory: String) {
        let file = name.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        try? png?.write(to: URL(fileURLWithPath: directory)
            .appending(path: String(file) + ".png"))
    }
}
