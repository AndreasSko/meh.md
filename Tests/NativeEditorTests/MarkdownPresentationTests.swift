import XCTest

@testable import NativeEditor

#if os(macOS)
import AppKit
#endif

@MainActor
final class MarkdownPresentationTests: XCTestCase {
    func testAgreedSyntaxProducesLiteralUnicodeSafeSpans() {
        let source = """
        # Héllo 👩🏽‍💻
        ## Second

        **bold and _naïve_**
        - unordered
        12. ordered
        [guide](https://example.com/a_(b))
        `let value = "**raw**"`
        ```swift
        # not a heading
        * not emphasis
        [not a link](inside-code)
        ```
        """
        let original = source
        let result = MarkdownSyntax.parse(source)

        XCTAssertEqual(source, original)
        XCTAssertEqual(result.spans.count { $0.role == .listMarker }, 2)
        XCTAssertEqual(result.spans.count { span in
            if case .heading = span.role { return true }
            return false
        }, 2)
        XCTAssertTrue(result.spans.contains { $0.role == .strong })
        XCTAssertTrue(result.spans.contains { $0.role == .emphasis })
        XCTAssertTrue(result.spans.contains { $0.role == .link })
        XCTAssertEqual(result.spans.count { $0.role == .code }, 2)

        assertRole(.code, covers: "**raw**", in: source, result: result)
        assertNoRole(.strong, covers: "raw", in: source, result: result)
        assertRole(
            .code,
            covers: "# not a heading",
            in: source,
            result: result
        )
        assertNoRole(
            .link,
            covers: "not a link",
            in: source,
            result: result
        )
        for span in result.spans {
            XCTAssertNotNil(Range(span.range, in: source))
        }
    }

    func testIncompleteSyntaxHasBoundedTypingStyles() {
        let source = """
        #
        [draft](https://example.com/path
        `unfinished **literal**
        **open strong
        -
        """
        let result = MarkdownSyntax.parse(source)

        XCTAssertTrue(result.spans.contains { $0.role == .heading(level: 1) })
        assertRole(.link, covers: "draft", in: source, result: result)
        assertRole(.code, covers: "literal", in: source, result: result)
        assertNoRole(.strong, covers: "literal", in: source, result: result)
        XCTAssertFalse(result.spans.contains { $0.role == .strong })
        XCTAssertTrue(result.spans.contains { $0.role == .listMarker })
    }

    func testOpenFenceOwnsMarkdownLookingTextThroughEndOfFile() {
        let source = """
        before
        ```swift
        # heading
        **strong**
        - list
        """
        let result = MarkdownSyntax.parse(source)

        XCTAssertEqual(result.spans.count, 1)
        assertRole(.code, covers: "strong", in: source, result: result)
    }

    func testEscapesNestingAndIntrawordUnderscores() {
        let source = #"\*literal* **bold and _café 👋🏽_** file_name"#
        let result = MarkdownSyntax.parse(source)

        XCTAssertEqual(result.spans.count { $0.role == .strong }, 1)
        XCTAssertEqual(result.spans.count { $0.role == .emphasis }, 1)
        assertNoRole(.emphasis, covers: "literal", in: source, result: result)
        assertNoRole(.emphasis, covers: "name", in: source, result: result)
        XCTAssertEqual(
            fontTraits(at: "café", in: source, result: result),
            [.bold, .italic]
        )
    }

    func testHeadingLevelsComposeWithNestedStyles() throws {
        let source = "# **Bold _and italic_**\nBody"
        let result = MarkdownSyntax.parse(source)

        let nestedRun = try XCTUnwrap(
            fontRun(at: "italic", in: source, result: result)
        )
        XCTAssertEqual(nestedRun.headingLevel, 1)
        XCTAssertEqual(nestedRun.traits, [.bold, .italic])
        XCTAssertNil(fontRun(at: "Body", in: source, result: result))
    }

    func testStrongAroundCodeComposesButCodeContentsDoNotParse() {
        let source = "**`[link](url) and _emphasis_`**"
        let result = MarkdownSyntax.parse(source)

        XCTAssertEqual(
            fontTraits(at: "link", in: source, result: result),
            [.bold, .monospaced]
        )
        assertNoRole(.link, covers: "link", in: source, result: result)
        assertNoRole(.emphasis, covers: "emphasis", in: source, result: result)
    }

    func testRepresentativeLongNoteParsesWithoutIncrementalState() {
        let section = """
        ## Section 👩🏽‍💻
        A **strong** paragraph with _Unicode café_ and [link](https://example.com).
        - item with `inline code`
        ```swift
        let literal = "**not strong**"
        ```

        """
        let source = String(repeating: section, count: 100)
        let original = source
        let result = MarkdownSyntax.parse(source)

        XCTAssertEqual(source, original)
        XCTAssertEqual(result.spans.count { $0.role == .code }, 200)
        XCTAssertEqual(result.spans.count { $0.role == .strong }, 100)
        XCTAssertEqual(result.spans.count { $0.role == .emphasis }, 100)
        XCTAssertEqual(result.spans.count { $0.role == .link }, 100)
    }

#if os(macOS)
    func testPaintAttributesUseAppearanceAwareSystemColors() throws {
        let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]

        for name in appearances {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                let code = MarkdownPresentation.renderingAttributes(for: .code)
                let link = MarkdownPresentation.renderingAttributes(for: .link)
                let marker = MarkdownPresentation.renderingAttributes(
                    for: .listMarker
                )

                XCTAssertEqual(
                    code[.foregroundColor] as? NSColor,
                    NSColor.textColor
                )
                XCTAssertEqual(
                    code[.backgroundColor] as? NSColor,
                    NSColor.secondarySystemFill
                )
                XCTAssertEqual(
                    link[.foregroundColor] as? NSColor,
                    NSColor.systemBlue
                )
                XCTAssertEqual(
                    marker[.foregroundColor] as? NSColor,
                    NSColor.systemOrange
                )
            }
        }
    }

    func testNativeRefreshUsesLargerHeadingsAndResetsFollowingText() throws {
        let source = "# Heading\nBody\n`code` plain"
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.allowsUndo = true
        textView.string = source
        MarkdownPresentation.configure(textView)

        let heading = try font(at: "Heading", in: source, textView: textView)
        let body = try font(at: "Body", in: source, textView: textView)
        let code = try font(at: "code", in: source, textView: textView)
        let trailing = try font(at: "plain", in: source, textView: textView)

        XCTAssertGreaterThan(heading.pointSize, body.pointSize)
        XCTAssertEqual(trailing.pointSize, body.pointSize, accuracy: 0.01)
        XCTAssertTrue(
            code.fontDescriptor.symbolicTraits.contains(.monoSpace)
        )
        XCTAssertFalse(
            trailing.fontDescriptor.symbolicTraits.contains(.monoSpace)
        )
        XCTAssertEqual(textView.string, source)
    }

    func testTypingAfterHeadingAndFenceReturnsToStableBodyFont() throws {
        let headingView = NSTextView(usingTextLayoutManager: true)
        headingView.string = "# Heading"
        MarkdownPresentation.configure(headingView)
        let originalHeading = try font(
            at: "Heading",
            in: headingView.string,
            textView: headingView
        )

        headingView.setSelectedRange(
            NSRange(location: (headingView.string as NSString).length, length: 0)
        )
        headingView.insertText(
            "\nBody",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        MarkdownPresentation.refresh(headingView)
        MarkdownPresentation.refresh(headingView)

        let headingBody = try font(
            at: "Body",
            in: headingView.string,
            textView: headingView
        )
        let refreshedHeading = try font(
            at: "Heading",
            in: headingView.string,
            textView: headingView
        )
        XCTAssertEqual(
            headingBody.pointSize,
            NSFont.preferredFont(forTextStyle: .body).pointSize,
            accuracy: 0.01
        )
        XCTAssertEqual(
            refreshedHeading.pointSize,
            originalHeading.pointSize,
            accuracy: 0.01
        )

        let codeView = NSTextView(usingTextLayoutManager: true)
        codeView.string = "```\ncode\n```"
        MarkdownPresentation.configure(codeView)
        codeView.setSelectedRange(
            NSRange(location: (codeView.string as NSString).length, length: 0)
        )
        codeView.insertText(
            "\nBody",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        MarkdownPresentation.refresh(codeView)
        let codeBody = try font(
            at: "Body",
            in: codeView.string,
            textView: codeView
        )
        XCTAssertFalse(
            codeBody.fontDescriptor.symbolicTraits.contains(.monoSpace)
        )
    }

    func testNativeRefreshPreservesSelectionAndAddsNoUndoAction() {
        let source = "# Héllo 👩🏽‍💻\nBody"
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.allowsUndo = true
        textView.string = source
        MarkdownPresentation.configure(textView)
        textView.undoManager?.removeAllActions()
        let selection = (source as NSString).range(of: "👩🏽‍💻")
        textView.setSelectedRange(selection)

        MarkdownPresentation.refresh(textView)

        XCTAssertEqual(textView.selectedRange(), selection)
        XCTAssertFalse(textView.undoManager?.canUndo == true)
        XCTAssertEqual(textView.string, source)
    }
#endif

    private func assertRole(
        _ role: MarkdownStyleRole,
        covers substring: String,
        in source: String,
        result: MarkdownSyntaxResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let range = (source as NSString).range(of: substring)
        XCTAssertTrue(
            result.spans.contains {
                $0.role == role && $0.range.contains(range)
            },
            "Expected \(role) to cover \(substring)",
            file: file,
            line: line
        )
    }

    private func assertNoRole(
        _ role: MarkdownStyleRole,
        covers substring: String,
        in source: String,
        result: MarkdownSyntaxResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let range = (source as NSString).range(of: substring)
        XCTAssertFalse(
            result.spans.contains {
                $0.role == role && $0.range.contains(range)
            },
            "Did not expect \(role) to cover \(substring)",
            file: file,
            line: line
        )
    }

    private func fontTraits(
        at substring: String,
        in source: String,
        result: MarkdownSyntaxResult
    ) -> MarkdownFontTraits? {
        fontRun(at: substring, in: source, result: result)?.traits
    }

    private func fontRun(
        at substring: String,
        in source: String,
        result: MarkdownSyntaxResult
    ) -> MarkdownFontRun? {
        let location = (source as NSString).range(of: substring).location
        return result.fontRuns.first {
            NSLocationInRange(location, $0.range)
        }
    }

#if os(macOS)
    private func font(
        at substring: String,
        in source: String,
        textView: NSTextView
    ) throws -> NSFont {
        let location = (source as NSString).range(of: substring).location
        return try XCTUnwrap(
            textView.textStorage?.attribute(
                .font,
                at: location,
                effectiveRange: nil
            ) as? NSFont
        )
    }
#endif
}

private extension NSRange {
    func contains(_ other: NSRange) -> Bool {
        location <= other.location && NSMaxRange(self) >= NSMaxRange(other)
    }
}
