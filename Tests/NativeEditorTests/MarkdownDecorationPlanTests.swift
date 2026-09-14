import XCTest
@testable import NativeEditor

@MainActor
final class MarkdownDecorationPlanTests: XCTestCase {
    func testMixedQuoteAndCodeGroupsAreFoundInSourceOrder() throws {
        let text = "> before\n```\ncode\n```\n> after"
        let plan = MarkdownSyntaxCache().decorationPlan(for: text)
        XCTAssertEqual(plan.groups.map(\.kind), [.blockquote, .codeBlock, .blockquote])
        for (word, expected) in [
            ("before", MarkdownPresentation.BlockDecoration.Kind.blockquote),
            ("code", .codeBlock), ("after", .blockquote)
        ] {
            let range = (text as NSString).range(of: word)
            let groups = plan.groups(intersecting: range)
            XCTAssertEqual(groups.count, 1)
            XCTAssertEqual(try XCTUnwrap(groups.first).kind, expected)
        }
    }

    func testContinuationJoinsButDeeperQuoteStartsAnotherGroup() {
        let text = "* > first\n  > continuation\n    * > deeper\n"
        let plan = MarkdownSyntaxCache().decorationPlan(for: text)
        XCTAssertEqual(plan.groups.count, 2)
        XCTAssertEqual(plan.groups.map { $0.runs.count }, [2, 1])
        let continuation = (text as NSString).range(of: "continuation")
        XCTAssertEqual(plan.groups[0].runIndices(intersecting: continuation), [1])
    }

    func testCanonicalByteChangeInvalidatesDecorationRanges() {
        let cache = MarkdownSyntaxCache()
        let composed = "> \u{00E9}\n> tail"
        let decomposed = "> e\u{0301}\n> tail"
        let before = cache.decorationPlan(for: composed)
        let after = cache.decorationPlan(for: decomposed)
        XCTAssertEqual(cache.parseCount, 2)
        XCTAssertEqual(after.groups[0].range.length, before.groups[0].range.length + 1)
        XCTAssertEqual(after.groups[0].runs[1].paragraph.range.location, 5)
    }

    func testGroupGeometryReusesAndInvalidatesWithSourceAndFont() {
        let cache = MarkdownSyntaxCache()
        var calculations = 0
        func left(fontSize: CGFloat = 17) -> CGFloat? {
            cache.cachedGroupLeft(
                range: NSRange(location: 0, length: 4),
                fontSize: fontSize,
                lineFragmentPadding: 5
            ) {
                calculations += 1
                return CGFloat(calculations)
            }
        }
        _ = cache.decorationPlan(for: "> é")
        XCTAssertEqual(left(), 1)
        XCTAssertEqual(left(), 1)
        XCTAssertEqual(left(fontSize: 22), 2)
        _ = cache.decorationPlan(for: "> e\u{0301}")
        XCTAssertEqual(left(), 3)
        XCTAssertEqual(calculations, 3)
    }

}
