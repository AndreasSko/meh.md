import XCTest

@testable import NativeEditor

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class MarkdownPresentationTests: XCTestCase {
    func testBatchedEditsReuseSyntaxAndMatchFullParse() throws {
        let initial = "# Heading\nOrdinary café 🪐 paragraph.\n**Later**"
        let batches: [[(String, String)]] = [
            [("Ordinary", "Ordinary bright"), ("bright", "brighter")],
            [("paragraph", "words"), ("Ordinary", "Plain")],
            [("café", "e\u{0301}"), ("🪐", "moon"), (" moon", "")],
            [("café", "temporary"), ("temporary", "café")],
            [("café 🪐", "x"), ("x paragraph", "new words")],
        ]
        for batch in batches {
            let storage = NSTextStorage(string: initial)
            let cache = MarkdownSyntaxCache()
            cache.prepare(in: storage)
            for (target, replacement) in batch {
                storage.replaceCharacters(
                    in: (storage.string as NSString).range(of: target),
                    with: replacement
                )
                // The commit path may ask for snapshots between edits, but
                // presentation is intentionally held until the whole batch.
                XCTAssertEqual(cache.textSnapshot(in: storage), storage.string)
            }
            let snapshots = cache.snapshotCount
            let text = cache.prepare(in: storage)
            XCTAssertEqual(cache.result(for: text), MarkdownSyntax.parse(text))
            XCTAssertEqual(cache.parseCount, 1)
            XCTAssertEqual(cache.incrementalParseCount, 1)
            XCTAssertEqual(cache.snapshotCount, snapshots)
        }
    }

    func testStorageRevisionReusesSnapshotAndInvalidatesExternalReplacement() {
        let storage = NSTextStorage(string: "# café")
        let cache = MarkdownSyntaxCache()
        cache.prepare(in: storage)
        let original = cache.textSnapshot(in: storage)
        storage.addAttribute(.kern, value: 1,
                             range: NSRange(location: 0, length: storage.length))
        cache.prepare(in: storage)
        XCTAssertEqual(cache.snapshotCount, 1)
        XCTAssertEqual(cache.parseCount, 1)

        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length),
                                  with: "# moon")
        let updated = cache.prepare(in: storage)
        XCTAssertEqual(original, "# café")
        XCTAssertEqual(updated, "# moon")
        XCTAssertEqual(cache.snapshotCount, 2)
        XCTAssertEqual(cache.result(for: updated), MarkdownSyntax.parse(updated))
    }

    func testCacheCannotReuseRevisionAcrossStorageOrUnrelatedString() {
        let cache = MarkdownSyntaxCache()
        let first = NSTextStorage(string: "first plain line")
        let second = NSTextStorage(string: "**second** line")
        cache.prepare(in: first)
        cache.prepare(in: second)
        XCTAssertEqual(cache.result(for: second.string), MarkdownSyntax.parse(second.string))
        _ = cache.result(for: "# Unrelated")
        second.replaceCharacters(in: NSRange(location: second.length, length: 0),
                                 with: "!")
        cache.prepare(in: second)
        XCTAssertEqual(cache.result(for: second.string), MarkdownSyntax.parse(second.string))
        first.replaceCharacters(in: NSRange(location: 0, length: 5), with: "other")
        cache.prepare(in: first)
        XCTAssertEqual(cache.result(for: first.string), MarkdownSyntax.parse(first.string))
    }

    func testBatchContainingNewlineUsesIncrementalParse() {
        let storage = NSTextStorage(string: "ordinary words\n**Later**")
        let cache = MarkdownSyntaxCache()
        cache.prepare(in: storage)
        storage.replaceCharacters(in: NSRange(location: 8, length: 0), with: "new ")
        storage.replaceCharacters(in: NSRange(location: 8, length: 0), with: "\n")
        let text = cache.prepare(in: storage)
        XCTAssertEqual(cache.result(for: text), MarkdownSyntax.parse(text))
        XCTAssertEqual(cache.parseCount, 1)
        XCTAssertEqual(cache.incrementalParseCount, 1)
    }

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

    func testHighlightAndStrikethroughRespectEscapesCodeAndUnicode() {
        let source = #"==café 👩🏽‍💻== \==plain== ~~finished~~ \~~kept~~ `==verbatim== ~~literal~~`"#
        let result = MarkdownSyntax.parse(source)

        assertRole(.highlight, covers: "café 👩🏽‍💻", in: source, result: result)
        assertRole(.strikethrough, covers: "finished", in: source, result: result)
        assertNoRole(.highlight, covers: "plain", in: source, result: result)
        assertNoRole(.strikethrough, covers: "kept", in: source, result: result)
        assertRole(.code, covers: "verbatim", in: source, result: result)
        assertNoRole(.highlight, covers: "verbatim", in: source, result: result)
        assertNoRole(.strikethrough, covers: "literal", in: source, result: result)
    }

    func testPairedStylesStayOnOneLineAndNeedVisibleContent() {
        let source = "== open\nclose ==\n== padded ==\n~~ ~~\n===word===\nx ~~~word~~~"
        let result = MarkdownSyntax.parse(source)

        XCTAssertFalse(result.spans.contains { $0.role == .highlight })
        XCTAssertFalse(result.spans.contains { $0.role == .strikethrough })
    }

    func testPairedStylesDoNotCloseInsideInlineCode() {
        let highlighted = "==outside `==code` rest=="
        let struck = "~~before `~~code` after~~"
        let unmatched = "==outside `==code`"

        let highlightResult = MarkdownSyntax.parse(highlighted)
        let strikeResult = MarkdownSyntax.parse(struck)
        let unmatchedResult = MarkdownSyntax.parse(unmatched)

        assertRole(
            .highlight,
            covers: "rest",
            in: highlighted,
            result: highlightResult
        )
        assertRole(
            .strikethrough,
            covers: "after",
            in: struck,
            result: strikeResult
        )
        XCTAssertFalse(
            unmatchedResult.spans.contains { $0.role == .highlight }
        )
    }

    func testNestedListBlockquotesAcceptTabsAndArbitraryIndentation() {
        let source = "\t  * > Nested café\n      > continuation\n\t1. > ordered"
        let result = MarkdownSyntax.parse(source)
        let quotes = result.paragraphRuns.filter { $0.kind == .blockquote }

        XCTAssertEqual(result.spans.count { $0.role == .listMarker }, 2)
        XCTAssertEqual(result.spans.count { $0.role == .blockquote }, 3)
        XCTAssertEqual(
            result.spans.count { $0.role == .blockquoteMarker },
            3
        )
        XCTAssertEqual(quotes.map(\.contentColumn), [10, 8, 9])
        assertRole(.blockquote, covers: "Nested café", in: source, result: result)
        assertRole(
            .blockquote,
            covers: "continuation",
            in: source,
            result: result
        )
        for span in result.spans {
            XCTAssertNotNil(Range(span.range, in: source))
        }
    }

    func testAlternatingQuoteAndListContainersHaveExactPrefixes() {
        let source = "> * child\n* > * nested\n1. 2025. report"
        let result = MarkdownSyntax.parse(source)
        let sourceString = source as NSString
        let quotes = result.paragraphRuns.filter { $0.kind == .blockquote }
        let lists = result.paragraphRuns.filter { $0.kind == .list }

        XCTAssertEqual(result.spans.count { $0.role == .listMarker }, 4)
        XCTAssertEqual(
            result.spans.count { $0.role == .blockquoteMarker },
            2
        )
        XCTAssertEqual(quotes.count, 2)
        XCTAssertEqual(lists.count, 1)
        XCTAssertEqual(
            sourceString.substring(with: quotes[0].contentPrefixRange),
            "> * "
        )
        XCTAssertEqual(
            sourceString.substring(with: quotes[1].contentPrefixRange),
            "* > * "
        )
        XCTAssertEqual(
            sourceString.substring(with: lists[0].contentPrefixRange),
            "1. "
        )
    }

    func testExtendedSyntaxIsExcludedFromFencedCode() {
        let source = """
        ~~~text
        ==not highlighted==
        ~~not struck~~
        > not quoted
        ~~~
        """
        let result = MarkdownSyntax.parse(source)

        XCTAssertEqual(result.spans.count, 1)
        assertRole(.code, covers: "not highlighted", in: source, result: result)
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

    func testManyCodeRangesKeepLaterSyntaxAndFontCompositionExact() {
        let sections = (0..<256).map { index in
            "`**raw \(index)**` and **visible \(index)**"
        }
        let source = sections.joined(separator: "\n")
        let result = MarkdownSyntax.parse(source)
        let codeRanges = result.spans.compactMap { span -> NSRange? in
            span.role == .code ? span.range : nil
        }

        XCTAssertEqual(codeRanges.count, 256)
        for (left, right) in zip(codeRanges, codeRanges.dropFirst()) {
            XCTAssertLessThanOrEqual(NSMaxRange(left), right.location)
        }
        XCTAssertEqual(result.spans.count { $0.role == .strong }, 256)
        for index in [0, 127, 255] {
            XCTAssertEqual(
                fontTraits(
                    at: "raw \(index)",
                    in: source,
                    result: result
                ),
                [.monospaced]
            )
            XCTAssertEqual(
                fontTraits(
                    at: "visible \(index)",
                    in: source,
                    result: result
                ),
                [.bold]
            )
        }
    }

    func testCrossingFontSpansAndCodeCompositionRemainExact() {
        let crossing = "**bold _both** italic_"
        let crossingResult = MarkdownSyntax.parse(crossing)

        XCTAssertEqual(
            fontTraits(at: "bold", in: crossing, result: crossingResult),
            [.bold]
        )
        XCTAssertEqual(
            fontTraits(at: "both", in: crossing, result: crossingResult),
            [.bold, .italic]
        )
        XCTAssertEqual(
            fontTraits(at: "italic", in: crossing, result: crossingResult),
            [.italic]
        )

        let withCode = "**before `code` after**"
        let codeResult = MarkdownSyntax.parse(withCode)
        XCTAssertEqual(
            fontTraits(at: "before", in: withCode, result: codeResult),
            [.bold]
        )
        XCTAssertEqual(
            fontTraits(at: "code", in: withCode, result: codeResult),
            [.bold, .monospaced]
        )
        XCTAssertEqual(
            fontTraits(at: "after", in: withCode, result: codeResult),
            [.bold]
        )
    }

    func testManyFencedBlocksKeepEveryFenceParagraphAndExcludeContents() {
        let sections = (0..<128).map { index in
            "```swift\n**raw \(index)**\n```\n**visible \(index)**"
        }
        let source = sections.joined(separator: "\n")
        let result = MarkdownSyntax.parse(source)

        XCTAssertEqual(result.spans.count { $0.role == .code }, 128)
        XCTAssertEqual(result.spans.count { $0.role == .strong }, 128)
        XCTAssertEqual(
            result.paragraphRuns.count { $0.kind == .codeBlock },
            384
        )
        XCTAssertEqual(
            fontTraits(at: "raw 127", in: source, result: result),
            [.monospaced]
        )
        XCTAssertEqual(
            fontTraits(at: "visible 127", in: source, result: result),
            [.bold]
        )
    }

#if os(macOS)
    func testPlainTextViewKeepsFallbackSyntaxCacheAcrossRefreshes() {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.string = "# First\n**Second**"
        let initialCache = MarkdownPresentation.syntaxCache(for: textView)

        MarkdownPresentation.configure(textView, mode: .livePreview)

        XCTAssertTrue(
            initialCache === MarkdownPresentation.syntaxCache(for: textView)
        )
        XCTAssertNotNil(initialCache.currentPresentation)
        XCTAssertEqual(initialCache.parseCount, 1)

        textView.textStorage?.replaceCharacters(
            in: NSRange(location: 0, length: 1),
            with: "X"
        )
        XCTAssertNil(initialCache.currentPresentation)

        MarkdownPresentation.refresh(textView, mode: .livePreview)

        XCTAssertTrue(
            initialCache === MarkdownPresentation.syntaxCache(for: textView)
        )
        XCTAssertNotNil(initialCache.currentPresentation)
        XCTAssertEqual(initialCache.parseCount, 1)
        XCTAssertEqual(initialCache.incrementalParseCount, 1)
    }

    func testRenderingCacheInvalidatesOnlyForCharacterEdits() throws {
        let source = "**First**\n**Second**"
        let textStorage = NSTextStorage(string: source)
        let cache = MarkdownSyntaxCache()
        let snapshot = MarkdownLivePreviewSnapshot(
            mode: .livePreview,
            selection: NSRange(location: 0, length: 0)
        )
        cache.observeCharacterEdits(in: textStorage)

        let initial = cache.presentation(for: source, snapshot: snapshot)
        XCTAssertNotNil(cache.currentPresentation)
        XCTAssertEqual(cache.parseCount, 1)

        textStorage.addAttribute(
            .kern,
            value: 0,
            range: NSRange(location: 0, length: 1)
        )
        XCTAssertNotNil(cache.currentPresentation)

        textStorage.replaceCharacters(
            in: NSRange(location: 0, length: 1),
            with: "X"
        )
        XCTAssertNil(cache.currentPresentation)

        let updatedText = textStorage.string
        let updated = cache.presentation(
            for: updatedText,
            snapshot: snapshot
        )
        XCTAssertNotEqual(initial.result, updated.result)
        XCTAssertNotNil(cache.currentPresentation)
        XCTAssertEqual(cache.parseCount, 2)
    }

    func testRenderingIndexMatchesFullIntersectionScan() {
        let source = """
        **bold _both** italic_ and [label](https://fictional.test/long/path)
        > ==marked== and ~~removed~~ with `code`
        """
        let result = MarkdownSyntax.parse(source)
        let presentation = MarkdownRenderingPresentation(
            result: result,
            previewRanges: MarkdownLivePreview.ranges(
                in: source,
                result: result,
                snapshot: MarkdownLivePreviewSnapshot(
                    mode: .livePreview,
                    selection: NSRange(location: 0, length: 0),
                    isEditing: false
                )
            )
        )
        let targets = [
            NSRange(location: 0, length: 7),
            (source as NSString).range(of: "label"),
            (source as NSString).range(of: "removed"),
            NSRange(location: (source as NSString).length - 3, length: 3),
        ]

        for target in targets {
            let expectedSpans = result.spans.filter {
                NSIntersectionRange($0.range, target).length > 0
            }
            let candidateIndices = presentation.spanCandidateIndices(
                intersecting: target
            )
            let actualSpans = result.spans[candidateIndices].filter {
                NSIntersectionRange($0.range, target).length > 0
            }
            XCTAssertEqual(Array(actualSpans), expectedSpans)

            var actualHidden: [NSRange] = []
            presentation.forEachHiddenRange(intersecting: target) {
                actualHidden.append($0)
            }
            let expectedHidden = presentation.hiddenRanges.filter {
                NSIntersectionRange($0, target).length > 0
            }
            XCTAssertEqual(actualHidden, expectedHidden)
        }
    }

    func testEditorSyntaxCachesReuseExactBytesWithoutCrossEditorThrash() {
        let firstView = MarkdownTextView(usingTextLayoutManager: true)
        let secondView = MarkdownTextView(usingTextLayoutManager: true)
        let composed = "# caf\u{00E9}"
        let decomposed = "# cafe\u{0301}"

        XCTAssertFalse(
            firstView.markdownSyntaxCache === secondView.markdownSyntaxCache
        )
        _ = firstView.markdownSyntaxCache.result(for: composed)
        _ = firstView.markdownSyntaxCache.result(for: composed)
        _ = secondView.markdownSyntaxCache.result(for: decomposed)
        _ = firstView.markdownSyntaxCache.result(for: composed)

        XCTAssertEqual(firstView.markdownSyntaxCache.parseCount, 1)
        XCTAssertEqual(secondView.markdownSyntaxCache.parseCount, 1)

        _ = firstView.markdownSyntaxCache.result(for: decomposed)
        XCTAssertEqual(firstView.markdownSyntaxCache.parseCount, 2)
    }

    func testBlockDrawingReusesConfiguredEditorSyntaxCache() throws {
        let source = "> Cached quote\n```\nlet value = 1\n```"
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        textView.frame = NSRect(x: 0, y: 0, width: 220, height: 240)
        let textContainer = try XCTUnwrap(textView.textContainer)
        textContainer.containerSize = NSSize(
            width: 220,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = source
        MarkdownPresentation.configure(textView)
        let layoutManager = try XCTUnwrap(textView.textLayoutManager)
        layoutManager.ensureLayout(
            for: try XCTUnwrap(layoutManager.textContentManager).documentRange
        )
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 220,
                height: 240,
                bitsPerComponent: 8,
                bytesPerRow: 220 * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        let visibleRange = NSRange(
            location: 0,
            length: (source as NSString).length
        )
        XCTAssertEqual(textView.markdownSyntaxCache.parseCount, 1)

        for _ in 0..<2 {
            MarkdownPresentation.drawBlockBackgrounds(
                text: source,
                syntaxCache: textView.markdownSyntaxCache,
                layoutManager: layoutManager,
                containerWidth: textContainer.size.width,
                lineFragmentPadding: textContainer.lineFragmentPadding,
                containerOrigin: .zero,
                visibleRange: visibleRange,
                dirtyRect: textView.bounds,
                context: context
            )
        }

        XCTAssertEqual(textView.markdownSyntaxCache.parseCount, 1)
    }

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
                let highlight = MarkdownPresentation.renderingAttributes(
                    for: .highlight
                )
                let strike = MarkdownPresentation.renderingAttributes(
                    for: .strikethrough
                )
                let quote = MarkdownPresentation.renderingAttributes(
                    for: .blockquote
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
                    NSColor.secondaryLabelColor
                )
                XCTAssertNotNil(highlight[.backgroundColor] as? NSColor)
                XCTAssertEqual(
                    strike[.strikethroughStyle] as? Int,
                    NSUnderlineStyle.single.rawValue
                )
                XCTAssertEqual(
                    quote[.foregroundColor] as? NSColor,
                    NSColor.textColor
                )
                XCTAssertNil(quote[.backgroundColor])
            }
        }
    }

    func testFencedCodeUsesPanelWithoutPerGlyphBackground() throws {
        let source = "`inline`\n```swift\nlet value = 1\n```"
        let result = MarkdownSyntax.parse(source)
        let codeSpans = result.spans.filter { $0.role == .code }
        let inline = try XCTUnwrap(codeSpans.first)
        let fenced = try XCTUnwrap(codeSpans.last)

        XCTAssertNotNil(
            MarkdownPresentation.renderingAttributes(
                for: inline,
                in: result
            )[.backgroundColor]
        )
        XCTAssertNil(
            MarkdownPresentation.renderingAttributes(
                for: fenced,
                in: result
            )[.backgroundColor]
        )
    }

    func testBlockDecorationsFollowNativeLayoutAndFillContainerWidth() throws {
        let source = """
        > Root quote with enough text to wrap across multiple visual lines in a narrow editor.
        >
        > Last quoted line.
        Plain text.
            * > A quiet same-level list quote.
              > This continuation keeps the same logical marker column.
                * > Deeper list quote.
                * > Deeper list continuation.
        Plain again.
        ```swift

        let value = 1
        ```
        """
        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: 220, height: 500)
        )
        textView.textContainer?.containerSize = NSSize(
            width: 220,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.string = source
        MarkdownPresentation.configure(textView)
        let layoutManager = try XCTUnwrap(textView.textLayoutManager)
        layoutManager.ensureLayout(
            for: try XCTUnwrap(layoutManager.textContentManager).documentRange
        )
        let containerWidth = try XCTUnwrap(textView.textContainer).size.width

        let decorations = MarkdownPresentation.blockDecorations(
            text: source,
            layoutManager: layoutManager,
            containerWidth: containerWidth
        )
        let quotes = decorations.filter { $0.kind == .blockquote }
        let syntax = MarkdownSyntax.parse(source)
        let quoteMarkers = syntax.spans.filter {
            $0.role == .blockquoteMarker
        }
        let codeRuns = syntax.paragraphRuns.filter { $0.kind == .codeBlock }
        let code = try XCTUnwrap(
            decorations.first { $0.kind == .codeBlock }
        )

        XCTAssertEqual(quotes.count, 3)
        XCTAssertEqual(
            quotes[0].rect.minX,
            try segmentFrame(for: quoteMarkers[0].range, in: layoutManager).minX,
            accuracy: 0.01
        )
        let listMarkerFrame = try segmentFrame(
            for: quoteMarkers[3].range,
            in: layoutManager
        )
        let continuationMarkerFrame = try segmentFrame(
            for: quoteMarkers[4].range,
            in: layoutManager
        )
        XCTAssertGreaterThan(
            abs(listMarkerFrame.minX - continuationMarkerFrame.minX),
            0.01
        )
        XCTAssertEqual(
            quotes[1].rect.minX,
            min(listMarkerFrame.minX, continuationMarkerFrame.minX),
            accuracy: 0.01
        )
        XCTAssertEqual(
            quotes[2].rect.minX,
            try segmentFrame(for: quoteMarkers[5].range, in: layoutManager).minX,
            accuracy: 0.01
        )
        XCTAssertGreaterThan(quotes[1].rect.minX, quotes[0].rect.minX)
        XCTAssertGreaterThan(quotes[2].rect.minX, quotes[1].rect.minX)
        XCTAssertEqual(quotes[0].rect.maxX, containerWidth, accuracy: 0.01)
        XCTAssertEqual(quotes[1].rect.maxX, containerWidth, accuracy: 0.01)
        XCTAssertEqual(quotes[2].rect.maxX, containerWidth, accuracy: 0.01)
        let accent = try XCTUnwrap(quotes[0].accentRect)
        XCTAssertEqual(accent.width, 2, accuracy: 0.01)
        XCTAssertLessThan(accent.minX, quotes[0].rect.minX)
        XCTAssertLessThanOrEqual(accent.maxX, quotes[0].rect.minX)
        XCTAssertGreaterThan(
            quotes[0].rect.height,
            MarkdownPresentation.editorBodyFont.pointSize * 4
        )
        XCTAssertEqual(code.rect.minX, 0, accuracy: 0.01)
        XCTAssertEqual(code.rect.maxX, containerWidth, accuracy: 0.01)
        let firstCodeRun = try XCTUnwrap(codeRuns.first)
        let lastCodeRun = try XCTUnwrap(codeRuns.last)
        let codeRange = NSRange(
            location: firstCodeRun.range.location,
            length: NSMaxRange(lastCodeRun.range)
                - firstCodeRun.range.location
        )
        let codeFrames = try segmentFrames(
            for: codeRange,
            in: layoutManager
        )
        let codeContentTop = try XCTUnwrap(codeFrames.map(\.minY).min())
        let codeContentBottom = try XCTUnwrap(codeFrames.map(\.maxY).max())
        let topPadding = codeContentTop - code.rect.minY
        let bottomPadding = code.rect.maxY - codeContentBottom
        XCTAssertGreaterThan(topPadding, 0)
        XCTAssertEqual(topPadding, bottomPadding, accuracy: 0.01)
        XCTAssertGreaterThan(
            code.rect.height,
            MarkdownPresentation.editorBodyFont.pointSize * 3
        )
    }

    func testVisibleWrappedQuoteKeepsPanelWhenMarkerIsOutsideRange() throws {
        let source = "\t* > A quoted paragraph with enough text to wrap "
            + "across several visual lines in a narrow editor while its "
            + "leading marker remains outside the visible text range."
        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: 180, height: 200)
        )
        let textContainer = try XCTUnwrap(textView.textContainer)
        textContainer.containerSize = NSSize(
            width: 180,
            height: CGFloat.greatestFiniteMagnitude
        )
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 7
        textView.string = source
        MarkdownPresentation.configure(textView, fontSize: 22)
        let layoutManager = try XCTUnwrap(textView.textLayoutManager)
        layoutManager.ensureLayout(
            for: try XCTUnwrap(layoutManager.textContentManager).documentRange
        )
        let syntax = MarkdownSyntax.parse(source)
        let marker = try XCTUnwrap(
            syntax.spans.first { $0.role == .blockquoteMarker }
        )
        let visibleRange = (source as NSString).range(
            of: "leading marker remains outside"
        )
        XCTAssertEqual(
            NSIntersectionRange(marker.range, visibleRange).length,
            0
        )

        let decorations = MarkdownPresentation.blockDecorations(
            text: source,
            layoutManager: layoutManager,
            containerWidth: textContainer.size.width,
            lineFragmentPadding: textContainer.lineFragmentPadding,
            visibleRange: visibleRange
        )
        let quote = try XCTUnwrap(
            decorations.first { $0.kind == .blockquote }
        )
        let markerFrame = try segmentFrame(
            for: marker.range,
            in: layoutManager
        )

        XCTAssertEqual(quote.rect.minX, markerFrame.minX, accuracy: 0.01)
        XCTAssertEqual(quote.rect.maxX, textContainer.size.width, accuracy: 0.01)
    }

    func testNativeStrikethroughIsStoredAndStaleStyleIsCleared() throws {
        let source = "Keep ~~finished~~ text"
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.string = source
        MarkdownPresentation.configure(textView)
        let storage = try XCTUnwrap(textView.textStorage)
        let struckLocation = (source as NSString).range(of: "finished").location
        let plainLocation = (source as NSString).range(of: "Keep").location

        XCTAssertEqual(
            storage.attribute(
                .strikethroughStyle,
                at: struckLocation,
                effectiveRange: nil
            ) as? Int,
            NSUnderlineStyle.single.rawValue
        )
        XCTAssertNil(
            storage.attribute(
                .strikethroughStyle,
                at: plainLocation,
                effectiveRange: nil
            )
        )

        storage.addAttribute(
            .strikethroughStyle,
            value: NSUnderlineStyle.single.rawValue,
            range: NSRange(location: plainLocation, length: 4)
        )
        MarkdownPresentation.refresh(textView)
        XCTAssertNil(
            storage.attribute(
                .strikethroughStyle,
                at: plainLocation,
                effectiveRange: nil
            )
        )
    }

    func testFontSizeRefreshPreservesSourceSelectionAndUndoState() throws {
        let source = "# Heading\nBody ~~old~~"
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.allowsUndo = true
        textView.string = source
        MarkdownPresentation.configure(textView, fontSize: 17)
        textView.undoManager?.removeAllActions()
        let selection = (source as NSString).range(of: "Body")
        textView.setSelectedRange(selection)

        MarkdownPresentation.refresh(textView, fontSize: 24)

        let body = try font(at: "Body", in: source, textView: textView)
        XCTAssertEqual(body.pointSize, 24, accuracy: 0.01)
        XCTAssertEqual(textView.string, source)
        XCTAssertEqual(textView.selectedRange(), selection)
        XCTAssertFalse(textView.undoManager?.canUndo == true)
    }

    func testFontFamiliesPreserveSemanticFacesAndMonospacedCode() throws {
        let source = "Body **bold** *italic* `code`"
        var bodyFontNames: Set<String> = []

        for family in EditorFontFamily.allCases {
            let textView = NSTextView(usingTextLayoutManager: true)
            textView.string = source
            MarkdownPresentation.configure(
                textView,
                fontFamily: family
            )

            let body = try font(at: "Body", in: source, textView: textView)
            let bold = try font(at: "bold", in: source, textView: textView)
            let italic = try font(
                at: "italic",
                in: source,
                textView: textView
            )
            let code = try font(at: "code", in: source, textView: textView)
            let expectedBody = MarkdownPresentation.bodyFont(
                for: family,
                pointSize: 17
            )
            let expectedCode = MarkdownPresentation.codeFont(pointSize: 17)

            bodyFontNames.insert(body.fontName)
            XCTAssertEqual(body.fontName, expectedBody.fontName)
            XCTAssertTrue(
                NSFontManager.shared.traits(of: bold).contains(.boldFontMask)
            )
            let italicLocation = (source as NSString).range(
                of: "italic"
            ).location
            let obliqueness = (textView.textStorage?.attribute(
                .obliqueness,
                at: italicLocation,
                effectiveRange: nil
            ) as? NSNumber)?.doubleValue ?? 0
            XCTAssertTrue(
                NSFontManager.shared.traits(of: italic).contains(
                    .italicFontMask
                ) || obliqueness > 0,
                "Expected italic styling for \(family.title)"
            )
            XCTAssertEqual(code.fontName, expectedCode.fontName)
            XCTAssertEqual(
                ("iiii" as NSString).size(withAttributes: [.font: code]).width,
                ("WWWW" as NSString).size(withAttributes: [.font: code]).width,
                accuracy: 0.01
            )
        }

        XCTAssertEqual(bodyFontNames.count, EditorFontFamily.allCases.count)
    }

    func testFontFamilyRefreshPreservesSelectionAndUndoState() throws {
        let source = "Body with a selected phrase"
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.allowsUndo = true
        textView.string = source
        MarkdownPresentation.configure(textView, fontFamily: .system)
        textView.undoManager?.removeAllActions()
        let selection = (source as NSString).range(of: "selected")
        textView.setSelectedRange(selection)

        MarkdownPresentation.refresh(textView, fontFamily: .serif)

        let body = try font(at: "Body", in: source, textView: textView)
        XCTAssertEqual(
            body.fontName,
            MarkdownPresentation.bodyFont(
                for: .serif,
                pointSize: 17
            ).fontName
        )
        XCTAssertEqual(textView.string, source)
        XCTAssertEqual(textView.selectedRange(), selection)
        XCTAssertFalse(textView.undoManager?.canUndo == true)
    }

    func testFontSizeNormalizationRejectsInvalidAndClampsBounds() {
        XCTAssertEqual(MarkdownPresentation.normalizedFontSize(.nan), 17)
        XCTAssertEqual(MarkdownPresentation.normalizedFontSize(.infinity), 17)
        XCTAssertEqual(MarkdownPresentation.normalizedFontSize(5), 12)
        XCTAssertEqual(MarkdownPresentation.normalizedFontSize(50), 28)
    }

    func testParagraphStylesAlignWrappedListsQuotesAndCode() throws {
        let source = "Body\n* Root list\n\t* Tab list\n  > Quote\n```\ncode\n```"
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.string = source
        MarkdownPresentation.configure(textView)

        let body = try paragraphStyle(
            at: "Body",
            in: source,
            textView: textView
        )
        let rootList = try paragraphStyle(
            at: "Root list",
            in: source,
            textView: textView
        )
        let tabList = try paragraphStyle(
            at: "Tab list",
            in: source,
            textView: textView
        )
        let quote = try paragraphStyle(
            at: "Quote",
            in: source,
            textView: textView
        )
        let code = try paragraphStyle(
            at: "code",
            in: source,
            textView: textView
        )
        let font = MarkdownPresentation.editorBodyFont
        let spaceWidth = (" " as NSString).size(
            withAttributes: [.font: font]
        ).width
        let markerWidth = ("* " as NSString).size(
            withAttributes: [.font: font]
        ).width

        XCTAssertEqual(font.pointSize, 17, accuracy: 0.01)
        XCTAssertEqual(body.headIndent, 0)
        XCTAssertEqual(rootList.firstLineHeadIndent, 0)
        XCTAssertEqual(rootList.headIndent, markerWidth, accuracy: 0.01)
        XCTAssertEqual(
            tabList.headIndent,
            spaceWidth * 4 + markerWidth,
            accuracy: 0.01
        )
        XCTAssertGreaterThan(quote.headIndent, body.headIndent)
        XCTAssertGreaterThan(code.firstLineHeadIndent, 0)
        XCTAssertLessThan(code.tailIndent, 0)
    }

    func testIndentedContinuationKeepsSoftWrapAtLiteralIndent() throws {
        let source = """
        * A long item
          continued words that wrap in a narrow editor without moving left
        """
        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: 180, height: 240)
        )
        textView.textContainer?.containerSize = NSSize(
            width: 180,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.string = source
        MarkdownPresentation.configure(textView)

        let continuation = try paragraphStyle(
            at: "continued",
            in: source,
            textView: textView
        )
        let font = MarkdownPresentation.editorBodyFont
        let expectedIndent = ("  " as NSString).size(
            withAttributes: [.font: font]
        ).width
        let run = try XCTUnwrap(
            MarkdownSyntax.parse(source).paragraphRuns.first {
                $0.kind == .indented
            }
        )

        XCTAssertEqual(run.contentPrefixRange.length, 2)
        XCTAssertEqual(continuation.firstLineHeadIndent, 0)
        XCTAssertEqual(
            continuation.headIndent,
            expectedIndent,
            accuracy: 0.01
        )
    }

    func testContainerPrefixesStayBodySizedBeforeHeading() throws {
        let source = "* # Heading list\n> # Heading quote"
        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: 180, height: 240)
        )
        textView.string = source
        MarkdownPresentation.configure(textView)

        let listMarker = try font(at: "*", in: source, textView: textView)
        let quoteMarker = try font(at: ">", in: source, textView: textView)
        let listHeading = try font(
            at: "Heading list",
            in: source,
            textView: textView
        )
        let quoteHeading = try font(
            at: "Heading quote",
            in: source,
            textView: textView
        )
        let listStyle = try paragraphStyle(
            at: "Heading list",
            in: source,
            textView: textView
        )
        let quoteStyle = try paragraphStyle(
            at: "Heading quote",
            in: source,
            textView: textView
        )
        let bodyFont = MarkdownPresentation.editorBodyFont
        let listPrefixWidth = ("* " as NSString).size(
            withAttributes: [.font: bodyFont]
        ).width
        let quotePrefixWidth = ("> " as NSString).size(
            withAttributes: [.font: bodyFont]
        ).width

        XCTAssertEqual(listMarker.pointSize, bodyFont.pointSize, accuracy: 0.01)
        XCTAssertEqual(quoteMarker.pointSize, bodyFont.pointSize, accuracy: 0.01)
        XCTAssertGreaterThan(listHeading.pointSize, bodyFont.pointSize)
        XCTAssertGreaterThan(quoteHeading.pointSize, bodyFont.pointSize)
        XCTAssertEqual(listStyle.headIndent, listPrefixWidth, accuracy: 0.01)
        XCTAssertEqual(quoteStyle.headIndent, quotePrefixWidth, accuracy: 0.01)
    }

    func testRefreshClearsStaleParagraphAndFontStyles() throws {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.allowsUndo = true
        textView.string = "## Title"
        MarkdownPresentation.configure(textView)
        let headingFont = try font(
            at: "Title",
            in: textView.string,
            textView: textView
        )

        textView.string = "Plain text"
        textView.undoManager?.removeAllActions()
        MarkdownPresentation.refresh(textView)

        let plainFont = try font(
            at: "Plain",
            in: textView.string,
            textView: textView
        )
        let plainStyle = try paragraphStyle(
            at: "Plain",
            in: textView.string,
            textView: textView
        )
        XCTAssertLessThan(plainFont.pointSize, headingFont.pointSize)
        XCTAssertEqual(plainStyle.headIndent, 0)
        XCTAssertEqual(plainStyle.firstLineHeadIndent, 0)
        XCTAssertFalse(textView.undoManager?.canUndo == true)
    }

    func testMultilineBoldUsesBoldFontsOnBothLines() throws {
        for mode in [MarkdownEditorMode.source, .livePreview] {
            let view = NSTextView(usingTextLayoutManager: true)
            view.string = "**First line\nsecond line**\n\nPlain paragraph"
            MarkdownPresentation.configure(view, mode: mode)
            for word in ["First", "second"] {
                let actual = try font(at: word, in: view.string, textView: view)
                XCTAssertTrue(NSFontManager.shared.traits(of: actual).contains(.boldFontMask))
            }
            let plain = try font(at: "Plain", in: view.string, textView: view)
            XCTAssertFalse(NSFontManager.shared.traits(of: plain).contains(.boldFontMask))
        }
    }

    func testExtendedPresentationPreservesLiteralSourceAndUndoState() {
        let source = "* > ==Café== and ~~old~~ 👋🏽"
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.allowsUndo = true
        textView.string = source
        MarkdownPresentation.configure(textView)
        textView.undoManager?.removeAllActions()

        MarkdownPresentation.refresh(textView)
        XCTAssertEqual(textView.string, source)
        XCTAssertFalse(textView.undoManager?.canUndo == true)
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
            MarkdownPresentation.editorBodyFont.pointSize,
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

    func testBatchedEditsMatchFreshNativeFormatting() throws {
        let view = NSTextView(usingTextLayoutManager: true)
        view.string = "# Heading\nOrdinary café 🪐 paragraph.\n**Later**"
        MarkdownPresentation.configure(view, mode: .livePreview)
        let cache = MarkdownPresentation.syntaxCache(for: view)
        let storage = try XCTUnwrap(view.textStorage)
        for (target, replacement) in [("paragraph", "words"), ("café 🪐", "moon")] {
            storage.replaceCharacters(
                in: (view.string as NSString).range(of: target), with: replacement
            )
        }
        MarkdownPresentation.refresh(view, mode: .livePreview)
        XCTAssertEqual(cache.incrementalParseCount, 1)
        XCTAssertLessThan(cache.lastLayoutRange.length, storage.length)
        let reference = NSTextView(usingTextLayoutManager: true)
        reference.string = view.string
        MarkdownPresentation.configure(reference, mode: .livePreview)
        let expectedStorage = try XCTUnwrap(reference.textStorage)
        let keys: [NSAttributedString.Key] = [
            .font, .paragraphStyle, .foregroundColor, .kern, .obliqueness,
            .strikethroughColor, .strikethroughStyle,
        ]
        for position in 0..<storage.length {
            for key in keys {
                XCTAssertEqual(
                    storage.attribute(key, at: position, effectiveRange: nil) as? NSObject,
                    expectedStorage.attribute(key, at: position, effectiveRange: nil) as? NSObject,
                    "\(key) at \(position)"
                )
            }
        }
    }

    func testIncrementalLayoutMatchesFullRefreshAfterEditsAndFallback() throws {
        let view = NSTextView(usingTextLayoutManager: true)
        view.string = "# Heading\n\nOrdinary café 🪐 paragraph.\n\n**Bold** and ~~old~~\nTail"
        MarkdownPresentation.configure(view, mode: .livePreview)
        let cache = MarkdownPresentation.syntaxCache(for: view)
        let storage = try XCTUnwrap(view.textStorage)
        let keys: [NSAttributedString.Key] = [
            .font, .paragraphStyle, .foregroundColor, .kern, .obliqueness,
            .strikethroughColor, .strikethroughStyle,
        ]
        for (target, replacement, incremental) in [
            ("Ordinary", "Ordinary bright", true),
            ("café", "e\u{0301}", true),
            ("🪐", "moon", true),
            ("# ", "", true),
            ("paragraph.", "paragraph.\nNew line", true),
            ("New line", "**New line**", true),
        ] {
            let previousCount = cache.incrementalParseCount
            storage.replaceCharacters(
                in: (view.string as NSString).range(of: target),
                with: replacement
            )
            MarkdownPresentation.refresh(view, mode: .livePreview)
            XCTAssertEqual(cache.incrementalParseCount - previousCount,
                           incremental ? 1 : 0)
            if incremental {
                XCTAssertLessThan(cache.lastLayoutRange.length, storage.length)
            }
            XCTAssertEqual(cache.result(for: view.string), MarkdownSyntax.parse(view.string))
            let reference = NSTextView(usingTextLayoutManager: true)
            reference.string = view.string
            MarkdownPresentation.configure(reference, mode: .livePreview)
            let referenceStorage = try XCTUnwrap(reference.textStorage)
            for position in 0..<storage.length {
                for key in keys {
                    let actual = storage.attribute(key, at: position, effectiveRange: nil)
                    let expected = referenceStorage.attribute(key, at: position, effectiveRange: nil)
                    XCTAssertEqual(actual as? NSObject, expected as? NSObject,
                                   "\(target): \(key) at \(position)")
                }
            }
        }
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

    private func paragraphStyle(
        at substring: String,
        in source: String,
        textView: NSTextView
    ) throws -> NSParagraphStyle {
        let location = (source as NSString).range(of: substring).location
        return try XCTUnwrap(
            textView.textStorage?.attribute(
                .paragraphStyle,
                at: location,
                effectiveRange: nil
            ) as? NSParagraphStyle
        )
    }

    private func segmentFrame(
        for range: NSRange,
        in layoutManager: NSTextLayoutManager
    ) throws -> CGRect {
        try XCTUnwrap(
            segmentFrames(for: range, in: layoutManager).first
        )
    }

    private func segmentFrames(
        for range: NSRange,
        in layoutManager: NSTextLayoutManager
    ) throws -> [CGRect] {
        let contentManager = try XCTUnwrap(layoutManager.textContentManager)
        let documentStart = contentManager.documentRange.location
        let start = try XCTUnwrap(
            contentManager.location(documentStart, offsetBy: range.location)
        )
        let end = try XCTUnwrap(
            contentManager.location(start, offsetBy: range.length)
        )
        let textRange = try XCTUnwrap(
            NSTextRange(location: start, end: end)
        )
        var frames: [CGRect] = []
        layoutManager.enumerateTextSegments(
            in: textRange,
            type: .standard,
            options: [.rangeNotRequired]
        ) { _, frame, _, _ in
            frames.append(frame)
            return true
        }
        return frames
    }
#endif
}

private extension NSRange {
    func contains(_ other: NSRange) -> Bool {
        location <= other.location && NSMaxRange(self) >= NSMaxRange(other)
    }
}
