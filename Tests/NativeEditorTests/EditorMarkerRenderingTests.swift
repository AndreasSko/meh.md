import XCTest

@testable import NativeEditor

/// Live Preview hides list and quote markers with rendering attributes,
/// which TextKit asks for only when it lays a line out.
@MainActor
final class EditorMarkerRenderingTests: XCTestCase {
    /// Scrolling keeps lines laid out away from the screen. An edit that
    /// changes the whole note's rendering attributes must still hide the
    /// markers on those lines when they scroll back into view.
    func testMarkersStayHiddenOnLinesLaidOutBeforeAnEdit() throws {
        var lines: [String] = []
        for section in 1...12 {
            lines += ["## Fictional section \(section)", ""]
            for item in 1...6 {
                lines += [
                    "* Point \(item) about **something**",
                    "    * A nested thought that wraps onto a second line in the editor",
                    "        * Detail \(section)-\(item)",
                    "        * > A quoted line from a fictional book",
                ]
            }
            lines.append("")
        }
        let harness = try EditorRenderingHarness(
            source: lines.joined(separator: "\n"),
            options: .init(size: CGSize(width: 820, height: 1100))
        )
        defer { harness.tearDown() }
#if os(iOS)
        XCTAssertTrue(harness.textView.becomeFirstResponder())
#endif
        let height = documentHeight(of: harness)
        for y in stride(from: 0, to: height, by: 700) { harness.scroll(toY: y) }
        harness.scroll(toY: 0)

        let edits: [(name: String, edit: (NSString) -> (NSRange, String))] = [
            ("new item", { text in
                (NSRange(location: NSMaxRange(text.range(of: "Detail 1-3")), length: 0),
                 "\n        * ")
            }),
            ("deleted line", { text in
                (text.lineRange(for: text.range(of: "Detail 1-5")), "")
            }),
        ]
        for (name, edit) in edits {
            let before = harness.text
            let (range, replacement) = edit(before as NSString)
            harness.replace(range, with: replacement)
            XCTAssertEqual(harness.text, (before as NSString)
                .replacingCharacters(in: range, with: replacement), name)
            // The edit lands near the top; the lines from earlier scrolls
            // are far below it.
            let farLine = (harness.text as NSString).range(of: "Detail 6-1").location
            XCTAssertNil(harness.lineRect(at: farLine), name)
            var checked = 0
            for y in stride(from: 0, to: documentHeight(of: harness), by: 450) {
                harness.scroll(toY: y)
                let markers = try concealedMarkers(in: harness)
                checked += markers.checked
                XCTAssertEqual(markers.shown, [], "After the \(name), at \(Int(y))")
            }
            XCTAssertGreaterThan(checked, 200, name)
            harness.scroll(toY: 0)
        }
    }

    /// How many concealed list and quote markers are on screen, and the
    /// lines of those TextKit draws in a visible color.
    private func concealedMarkers(in harness: EditorRenderingHarness) throws
        -> (checked: Int, shown: [String]) {
        let manager = harness.layoutManager
        let viewport = try XCTUnwrap(harness.viewportRange)
        let text = harness.text as NSString
        let snapshot = MarkdownLivePreview.snapshot(for: harness.textView)
        let screen = harness.visibleRect.insetBy(dx: 0, dy: 1)
        var checked = 0
        var shown: [String] = []
        for span in MarkdownSyntax.parse(harness.text).spans
        where span.role == .listMarker || span.role == .blockquoteMarker {
            guard NSIntersectionRange(span.range, viewport).length > 0,
                  let line = harness.lineRect(at: span.range.location),
                  screen.contains(CGPoint(x: line.midX, y: line.midY)),
                  MarkdownLivePreview.conceals(span.range, in: text, snapshot: snapshot)
            else { continue }
            checked += 1
            if try attribute(.foregroundColor, at: span.range.location, in: manager)
                as? PlatformColor != .clear {
                shown.append(text.substring(with: text.lineRange(for: span.range))
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return (checked, shown)
    }

    private func documentHeight(of harness: EditorRenderingHarness) -> CGFloat {
#if os(macOS)
        harness.textView.frame.height
#else
        harness.textView.contentSize.height
#endif
    }

    private func attribute(_ key: NSAttributedString.Key, at offset: Int,
                           in manager: NSTextLayoutManager) throws -> Any? {
        let content = try XCTUnwrap(manager.textContentManager)
        let location = try XCTUnwrap(content.location(
            content.documentRange.location, offsetBy: offset
        ))
        var value: Any?
        manager.enumerateRenderingAttributes(from: location, reverse: false) {
            _, attributes, range in
            // A run that starts later means none at this offset.
            if range.location.compare(location) != .orderedDescending {
                value = attributes[key]
            }
            return false
        }
        return value
    }
}
