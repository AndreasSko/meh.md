import XCTest

@testable import NativeEditor

#if os(macOS)
import AppKit
#endif

/// Live Preview shows front matter as rows of properties, or as one
/// "3 Properties" line once collapsed, and the YAML as written while the
/// caret is inside it.
@MainActor
final class MarkdownFrontMatterPreviewTests: XCTestCase {
    private let source = """
    ---
    author: Mira Holt
    url: "https://example.com/garden"
    tags: [habit, nature]
    ---
    Body text
    """

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: MarkdownLivePreview.propertiesCollapsedKey)
        super.tearDown()
    }

    private func ranges(
        _ text: String, caretAt target: String, collapsed: Bool = false
    ) -> (collapsed: [String], transparent: [String]) {
        let selection = NSRange(location: (text as NSString).range(of: target).location, length: 0)
        let ranges = MarkdownLivePreview.ranges(
            in: text, result: MarkdownSyntax.parse(text),
            snapshot: MarkdownLivePreviewSnapshot(
                mode: .livePreview, selection: selection, propertiesCollapsed: collapsed)
        )
        let source = text as NSString
        return (ranges.collapsed.map(source.substring(with:)),
                ranges.transparent.map(source.substring(with:)))
    }

    func testRowsHideTheFencesKeysAndListSyntax() {
        let (collapsed, transparent) = ranges(source, caretAt: "Body")
        XCTAssertEqual(collapsed, ["---\n", "\"", "\"", "[", "]", "---\n"])
        XCTAssertEqual(transparent, ["author: ", "url: ", "tags: ", ", "])
    }

    func testTheCaretInsideShowsTheYAMLAsWritten() {
        let (collapsed, transparent) = ranges(source, caretAt: "Mira")
        XCTAssertEqual(collapsed, [])
        XCTAssertEqual(transparent, [])
    }

    func testCollapsedKeepsOnlyTheOpeningLine() {
        let (collapsed, transparent) = ranges(source, caretAt: "Body", collapsed: true)
        XCTAssertEqual(transparent, ["---"])
        XCTAssertEqual(collapsed, [
            "author: Mira Holt\nurl: \"https://example.com/garden\"\ntags: [habit, nature]\n---\n",
        ])
    }

    func testTwoPropertiesStayRowsEvenWhenCollapsed() {
        let two = "---\nauthor: Mira\nstatus: draft\n---\nBody"
        let (collapsed, transparent) = ranges(two, caretAt: "Body", collapsed: true)
        XCTAssertEqual(collapsed, ["---\n", "---\n"])
        XCTAssertEqual(transparent, ["author: ", "status: "])
    }

    func testYAMLItCannotShowAsRowsStaysAsWritten() {
        let nested = "---\nauthor:\n  name: Mira\n---\nBody"
        let (collapsed, transparent) = ranges(nested, caretAt: "Body")
        XCTAssertEqual(collapsed, [])
        XCTAssertEqual(transparent, [])
    }

    func testTheChevronCollapsesAndTheSummaryExpands() throws {
        let harness = try EditorRenderingHarness(source: source)
        defer { harness.tearDown() }
        let text = source as NSString
        let body = text.range(of: "Body").location
        harness.textView.setSelectedRange(NSRange(location: body, length: 0))
        harness.settle()
        let rowsBody = try XCTUnwrap(harness.lineRect(at: body))
        let firstRow = try XCTUnwrap(harness.lineRect(at: text.range(of: "author").location))

        let label = CGPoint(x: firstRow.minX + 4, y: firstRow.midY)
        XCTAssertFalse(MarkdownPresentation.hitsFrontMatterToggle(at: label, in: harness.textView))
        let chevron = CGPoint(x: harness.textView.bounds.width - 30, y: firstRow.midY)
        XCTAssertTrue(MarkdownPresentation.hitsFrontMatterToggle(at: chevron, in: harness.textView))
        MarkdownPresentation.toggleFrontMatterCollapsed(in: harness.textView)
        harness.settle()
        XCTAssertTrue(UserDefaults.standard.bool(forKey: MarkdownLivePreview.propertiesCollapsedKey))
        let collapsedBody = try XCTUnwrap(harness.lineRect(at: body))
        XCTAssertLessThan(collapsedBody.minY, rowsBody.minY - 20)

        let summary = try XCTUnwrap(harness.lineRect(at: 0))
        let tap = CGPoint(x: summary.minX + 10, y: summary.midY)
        XCTAssertTrue(MarkdownPresentation.hitsFrontMatterToggle(at: tap, in: harness.textView))
        MarkdownPresentation.toggleFrontMatterCollapsed(in: harness.textView)
        harness.settle()
        XCTAssertEqual(try XCTUnwrap(harness.lineRect(at: body)).minY, rowsBody.minY, accuracy: 1)
    }

    func testAListFirstKeepsTheChevronAndAnAction() throws {
        let list = "---\ntags:\n  - garden\n  - habit\nauthor: Mira\nstatus: draft\n---\nBody text"
        let harness = try EditorRenderingHarness(source: list)
        defer { harness.tearDown() }
        let text = list as NSString
        harness.textView.setSelectedRange(NSRange(location: text.range(of: "Body").location, length: 0))
        harness.settle()
        let firstItem = try XCTUnwrap(harness.lineRect(at: text.range(of: "garden").location))
        let chevron = CGPoint(x: harness.textView.bounds.width - 30, y: firstItem.midY)
        XCTAssertTrue(MarkdownPresentation.hitsFrontMatterToggle(at: chevron, in: harness.textView))
        XCTAssertEqual(MarkdownPresentation.frontMatterToggleName(in: harness.textView),
                       "Collapse Properties")
        MarkdownPresentation.toggleFrontMatterCollapsed(in: harness.textView)
        harness.settle()
        XCTAssertEqual(MarkdownPresentation.frontMatterToggleName(in: harness.textView),
                       "Expand Properties")
    }
}
