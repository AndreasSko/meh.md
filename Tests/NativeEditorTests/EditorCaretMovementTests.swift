import XCTest

@testable import NativeEditor

@MainActor
final class EditorCaretMovementTests: XCTestCase {
    /// Text pasted from a Bible app breaks its lines with U+2028. Below a
    /// short line like a quote's markers, the indented next line starts
    /// further right than that line ends.
    func testUpFromLineAfterLineSeparatorMovesToLineAbove() throws {
        for separator in ["\u{2028}", "\u{0085}"] {
            let source = (1...20).map { "* Fictional line \($0)" }.joined(separator: "\n")
                + "\n* Fictional argument:\n\t* > \(separator)**Fictional quote**: It starts"
                + " on the line after the separator and wraps.\(separator)Then another line.\n"
                + "* After the quote"
            for mode in [MarkdownEditorMode.livePreview, .source] {
                let harness = try EditorRenderingHarness(
                    source: source,
                    options: .init(size: CGSize(width: 820, height: 900), mode: mode)
                )
                defer { harness.tearDown() }
                let navigation = Navigation(harness: harness)
                let text = source as NSString
                let quote = text.range(of: "**Fictional quote**").location
                let label = "\(mode), U+\(String(separator.unicodeScalars.first!.value, radix: 16))"

                // Up twice: to the end of the markers' line, then above it.
                let first = try navigation.move(navigation.caret(at: quote), .up)
                XCTAssertEqual(try navigation.range(of: first), NSRange(location: quote - 1, length: 0), label)
                let second = try navigation.move(first, .up)
                XCTAssertLessThan(try navigation.range(of: second).location, quote - 1, label)
                // A later line's start keeps its line above.
                let another = text.range(of: "Then another").location
                let above = try navigation.range(of: navigation.move(navigation.caret(at: another), .up))
                XCTAssertGreaterThanOrEqual(above.location, quote, label)
                XCTAssertLessThan(above.location, another - 1, label)
                // Shift-Up selects up to the end of the markers' line.
                let extended = try navigation.move(navigation.caret(at: quote), .up, extending: true)
                XCTAssertEqual(try navigation.range(of: extended),
                               NSRange(location: quote - 1, length: 1), label)
                // Moving to the line's start stays on the quote's line.
                let lineStart = try navigation.move(navigation.caret(at: quote + 5), .up,
                                                    destination: .line)
                XCTAssertEqual(try navigation.range(of: lineStart), NSRange(location: quote, length: 0),
                               label)
            }
        }
    }

    @MainActor
    private struct Navigation {
        let harness: EditorRenderingHarness

        func caret(at offset: Int) throws -> NSTextSelection {
            let content = try XCTUnwrap(harness.layoutManager.textContentManager)
            let location = try XCTUnwrap(content.location(
                content.documentRange.location, offsetBy: offset
            ))
            return NSTextSelection(
                range: NSTextRange(location: location), affinity: .downstream,
                granularity: .character
            )
        }

        func move(
            _ selection: NSTextSelection, _ direction: NSTextSelectionNavigation.Direction,
            destination: NSTextSelectionNavigation.Destination = .character,
            extending: Bool = false
        ) throws -> NSTextSelection {
            try XCTUnwrap(harness.layoutManager.textSelectionNavigation.destinationSelection(
                for: selection, direction: direction, destination: destination,
                extending: extending, confined: false
            ))
        }

        func range(of selection: NSTextSelection) throws -> NSRange {
            let content = try XCTUnwrap(harness.layoutManager.textContentManager)
            let range = try XCTUnwrap(selection.textRanges.first)
            let start = content.offset(from: content.documentRange.location, to: range.location)
            return NSRange(location: start,
                           length: content.offset(from: range.location, to: range.endLocation))
        }
    }
}
