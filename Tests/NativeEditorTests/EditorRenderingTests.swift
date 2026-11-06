import NoteCore
import XCTest

@testable import NativeEditor

/// Live Preview draws bullets, checkboxes, rules, quote and code panels,
/// sums and history marks instead of Markdown's markers. These tests draw
/// the real editor into an image and check that each decoration sits beside
/// its own line, while the note scrolls, changes width and switches modes.
///
/// They draw the way the editor draws itself, so they show where marks are
/// painted, not whether the screen kept an old painting; the UI test
/// `EditorRenderingUITests` covers what reaches the screen.
@MainActor
final class EditorRenderingTests: XCTestCase {
    private func check(
        _ harness: EditorRenderingHarness, _ fixture: EditorRenderingFixture,
        _ name: String, scale: CGFloat = 2,
        file: StaticString = #filePath, line: UInt = #line
    ) -> Int {
        let result = EditorRenderingCheck(harness, fixture, scale: scale)
        result.assertPasses(name, in: self, file: file, line: line)
        return result.checked
    }

    func testDecorationsSitBesideTheirLines() throws {
        let fixture = EditorRenderingFixture.showcase
        for fontFamily in [EditorFontFamily.system, .monospaced] {
            for isDark in [false, true] {
                let harness = try EditorRenderingHarness(
                    source: fixture.source,
                    options: .init(
                        size: CGSize(width: 420, height: 900), fontFamily: fontFamily,
                        isDark: isDark, timeCalculator: true
                    )
                )
                defer { harness.tearDown() }
                for scale: CGFloat in [1, 2, 3] {
                    let name = "showcase \(fontFamily) \(isDark ? "dark" : "light") @\(Int(scale))x"
                    let checked = check(harness, fixture, name, scale: scale)
                    XCTAssertGreaterThanOrEqual(checked, 9, "\(name): too little on screen")
                }
            }
        }
    }

    func testLongNoteKeepsDecorationsAfterTypingAtTheEndAndScrollingBack() throws {
        let fixture = EditorRenderingFixture.long(sections: 40)
        let harness = try EditorRenderingHarness(
            source: fixture.source, options: .init(size: CGSize(width: 420, height: 640))
        )
        defer { harness.tearDown() }
        harness.type(atEnd: " More notes.")
        let extended = fixture.appending(" More notes.")
        var checked = check(harness, extended, "after typing at the end")
        // Uneven steps leave lines cut at the window's edges in many ways.
        let steps: [CGFloat] = [-0.7, -1.3, -0.45, -2.1, -0.9]
        var step = 0
        while harness.visibleRect.minY > 1 {
            let y = harness.visibleRect.minY
            harness.scroll(by: steps[step % steps.count] * harness.visibleRect.height + 0.5)
            step += 1
            checked += check(harness, extended, "scrolling back up, step \(step)")
            XCTAssertLessThan(harness.visibleRect.minY, y, "Scrolling up stopped")
            if harness.visibleRect.minY >= y { break }
        }
        XCTAssertGreaterThan(step, 10, "The note was too short to scroll far")
        XCTAssertGreaterThan(checked, 60, "Too few decorations were on screen")
    }

    func testDecorationsFollowWidthChanges() throws {
        let fixture = EditorRenderingFixture.showcase
        let harness = try EditorRenderingHarness(
            source: fixture.source, options: .init(size: CGSize(width: 520, height: 900))
        )
        defer { harness.tearDown() }
        for width: CGFloat in [360, 640, 420] {
            harness.resize(width: width)
            XCTAssertGreaterThanOrEqual(check(harness, fixture, "width \(Int(width))"), 8)
        }
    }

    func testDecorationsReturnAfterSourceMode() throws {
        let fixture = EditorRenderingFixture.showcase
        let harness = try EditorRenderingHarness(
            source: fixture.source, options: .init(size: CGSize(width: 420, height: 900))
        )
        defer { harness.tearDown() }
        harness.update { $0.mode = .source }
        harness.update { $0.mode = .livePreview }
        XCTAssertGreaterThanOrEqual(check(harness, fixture, "back from source mode"), 8)
    }

    func testHistoryMarksSitBesideChangedLines() throws {
        let fixture = EditorRenderingFixture.history
        let harness = try EditorRenderingHarness(
            source: fixture.source,
            options: .init(
                size: CGSize(width: 420, height: 900),
                historyChanges: NoteHistoryChanges(
                    from: fixture.historicalSource, to: fixture.source
                )
            )
        )
        defer { harness.tearDown() }
        XCTAssertGreaterThanOrEqual(check(harness, fixture, "history marks"), 4)
    }
}
