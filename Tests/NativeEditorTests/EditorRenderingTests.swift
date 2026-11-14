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

    /// A sum follows its `=`, so near the right edge it reaches past the
    /// text into the margin, and its line must draw that far.
    func testSumsAreNotCutAtTheRightEdge() throws {
        let fixture = EditorRenderingFixture.sums
        let harness = try EditorRenderingHarness(
            source: fixture.source,
            options: .init(size: CGSize(width: 1100, height: 700), timeCalculator: true)
        )
        defer { harness.tearDown() }
        // Page through the note: a window taller than the screen would not fit.
        var sums: [(total: Int, width: CGFloat, room: CGFloat, start: CGFloat)] = []
        var page = 0
        while true {
            let check = EditorRenderingCheck(harness, fixture, scale: 2)
            check.assertPasses("sums near the right edge, page \(page)", in: self)
            sums += check.sums
            let top = harness.visibleRect.minY
            harness.scroll(by: 0.8 * harness.visibleRect.height)
            page += 1
            if harness.visibleRect.minY <= top + 1 || page > 20 { break }
        }
        XCTAssertEqual(Set(sums.map(\.total)), Set(fixture.totals), "Not every sum was on screen")
        // The first sum, after a short line, shows the full width.
        let reference = try XCTUnwrap(sums.first).width
        var reachedMargin = false
        for (index, sum) in sums.enumerated() where sum.room > reference + 4 {
            reachedMargin = reachedMargin || sum.start + reference > 0
            XCTAssertEqual(sum.width, reference, accuracy: 1.5, "Sum \(index) is cut short")
        }
        XCTAssertTrue(reachedMargin, "No sum reached past the text into the margin")
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

    /// Each line draws its slice of a code or quote panel in a layer of
    /// its own. An edge partway through a pixel row leaves a thin light line
    /// on screen, which this harness can't see because it draws every line
    /// into one image. So check that slice edges land on whole pixels, and
    /// that two slices sharing an edge still share it, wherever the line is.
    func testPanelSlicesEndOnWholePixels() throws {
        for scale: CGFloat in [1, 2, 3] {
            for offset: CGFloat in [0, 0.17, 0.5, 0.83, 1.4] {
                let context = try XCTUnwrap(CGContext(
                    data: nil, width: 400, height: 400, bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ))
                context.scaleBy(x: scale, y: scale)
                context.translateBy(x: 0, y: offset)
                let upper = MarkdownPresentation.pixelRows(
                    of: CGRect(x: 0, y: 10.3, width: 100, height: 20.45), in: context)
                let lower = MarkdownPresentation.pixelRows(
                    of: CGRect(x: 0, y: 30.75, width: 100, height: 18.2), in: context)
                XCTAssertEqual(upper.maxY, lower.minY, accuracy: 0.0001,
                               "@\(scale)x, offset \(offset): slices must meet")
                for y in [upper.minY, upper.maxY, lower.maxY] {
                    let device = context.convertToDeviceSpace(CGPoint(x: 0, y: y)).y
                    XCTAssertEqual(device, device.rounded(), accuracy: 0.0001,
                                   "@\(scale)x, offset \(offset): edge between pixels")
                }
                XCTAssertEqual(upper.height, 20.45, accuracy: 1 / scale)
                // A quote's accent bar keeps the moved panel's edges.
                let quote = MarkdownPresentation.BlockDecoration(
                    kind: .blockquote, rect: CGRect(x: 20, y: 10.3, width: 80, height: 20.45))
                let accent = try XCTUnwrap(MarkdownPresentation.accentRect(of: quote, in: upper))
                XCTAssertEqual(accent.minY, upper.minY, accuracy: 0.0001)
                XCTAssertEqual(accent.maxY, upper.maxY, accuracy: 0.0001)
            }
        }
    }

    func testEachLineCoversWholePixelRowsOfItsPanel() throws {
        let fixture = EditorRenderingFixture.showcase
        let harness = try EditorRenderingHarness(
            source: fixture.source, options: .init(size: CGSize(width: 420, height: 400))
        )
        defer { harness.tearDown() }
        // An uneven scroll puts the lines' edges between pixels.
        harness.scroll(toY: 200.37)
        let text = harness.text as NSString
        for start in ["Patient", "continues", "let lantern", "print("] {
            let location = text.range(of: start).location
            let line = try XCTUnwrap(harness.lineRect(at: location))
            // Right of the text, where the panel shows nothing else.
            let x = harness.textColumn.upperBound - 2
            for scale: CGFloat in [2, 3] {
                let image = try harness.renderLine(at: location, scale: scale)
                let column = image.pixelX(x)
                let rows = image.pixels(in: line.insetBy(dx: 0, dy: -12)).y
                let covered = rows.map { image.alpha(x: column, y: $0) }.filter { $0 > 0 }
                XCTAssertFalse(covered.isEmpty, "\(start) @\(scale)x: no panel")
                // A partly covered row shows as a seam once lines are composited.
                XCTAssertLessThanOrEqual(
                    (covered.max() ?? 0) - (covered.min() ?? 0), 1,
                    "\(start) @\(scale)x: panel edge between pixels: \(covered)"
                )
            }
        }
    }

    func testPaletteChangesRedrawEveryVisibleLine() throws {
        let fixture = EditorRenderingFixture.showcase
        let harness = try EditorRenderingHarness(
            source: fixture.source,
            options: .init(size: CGSize(width: 420, height: 900), timeCalculator: true)
        )
        defer {
            harness.tearDown()
            MehStyle.palette = MehPalette()
        }
        // A new palette changes no text, so nothing else redraws these lines.
        let drawn = harness.linesDrawn {
            harness.update { $0.palette = MehPalette(ink: .blue, highlighter: .pink) }
        }
        XCTAssertGreaterThanOrEqual(harness.visibleLines.count, 9)
        XCTAssertEqual(
            harness.visibleLines.subtracting(drawn).count, 0, "Lines kept the old palette's colors"
        )
        XCTAssertGreaterThanOrEqual(check(harness, fixture, "after a palette change"), 9)
    }

    func testPaletteChangesReachLinesOutOfView() throws {
        let fixture = EditorRenderingFixture.long(sections: 40)
        let harness = try EditorRenderingHarness(
            source: fixture.source, options: .init(size: CGSize(width: 420, height: 640))
        )
        defer {
            harness.tearDown()
            MehStyle.palette = MehPalette()
        }
        harness.scroll(toY: harness.visibleRect.height * 3)
        let drawn = harness.linesDrawn {
            harness.update { $0.palette = MehPalette(ink: .green, highlighter: .blue) }
            harness.scroll(toY: 0)
        }
        XCTAssertGreaterThanOrEqual(harness.visibleLines.count, 9)
        XCTAssertEqual(
            harness.visibleLines.subtracting(drawn).count, 0, "Lines kept the old palette's colors"
        )
    }

    func testSumRedrawsWhenATimeAboveChanges() throws {
        let source = "Ferry 1h 20m\nWalk 45m\nTotal =\n\nThe end.\n"
        let harness = try EditorRenderingHarness(
            source: source, options: .init(timeCalculator: true)
        )
        defer { harness.tearDown() }
        let total = (source as NSString).range(of: "Total =").location
        let minutes = (source as NSString).range(of: "45m")
        // Only the walk's line changes text; the total's line shows the new sum.
        let drawn = harness.linesDrawn { harness.replace(minutes, with: "55m") }
        XCTAssertTrue(
            try drawn.contains(XCTUnwrap(harness.line(at: total))), "The total kept the old sum"
        )
    }

    func testTableScrolledSidewaysRedrawsItsRows() throws {
        let header = (1...12).map { "Column \($0)" }
        let source = "Before.\n\n| " + header.joined(separator: " | ") + " |\n|"
            + String(repeating: " --- |", count: 12) + "\n| "
            + (1...12).map { "Cell \($0)" }.joined(separator: " | ") + " |\n\nAfter.\n"
        let harness = try EditorRenderingHarness(source: source)
        defer { harness.tearDown() }
        let textView = harness.textView
        let table = try XCTUnwrap(textView.markdownSyntaxCache.tableLayout?.rows.first?.tableRange)
        let drawn = harness.linesDrawn {
            XCTAssertTrue(textView.setMarkdownTableHorizontalOffset(200, for: table))
        }
        let rows = (source as NSString).substring(with: table).components(separatedBy: "\n")
        var location = table.location
        for row in rows where !row.isEmpty {
            XCTAssertTrue(
                try drawn.contains(XCTUnwrap(harness.line(at: location))),
                "A row kept its old columns: \(row.prefix(20))"
            )
            location += (row as NSString).length + 1
        }
    }

    func testHistoryMarksRedrawWhenTheComparedVersionChanges() throws {
        let fixture = EditorRenderingFixture.history
        let harness = try EditorRenderingHarness(
            source: fixture.source, options: .init(size: CGSize(width: 420, height: 900))
        )
        defer { harness.tearDown() }
        let drawn = harness.linesDrawn {
            harness.update {
                $0.historyChanges = NoteHistoryChanges(
                    from: fixture.historicalSource, to: fixture.source
                )
            }
        }
        XCTAssertEqual(harness.visibleLines.subtracting(drawn).count, 0, "Lines kept no marks")
        XCTAssertGreaterThanOrEqual(check(harness, fixture, "history marks after a change"), 4)
    }
}
