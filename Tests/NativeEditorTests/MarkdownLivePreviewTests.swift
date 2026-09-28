import XCTest

@testable import NativeEditor

#if os(macOS)
import AppKit
#endif

@MainActor
final class MarkdownLivePreviewTests: XCTestCase {
    func testModeCasesRemainStableForPersistence() {
        XCTAssertEqual(MarkdownEditorMode.source.rawValue, "source")
        XCTAssertEqual(
            MarkdownEditorMode.livePreview.rawValue,
            "livePreview"
        )
        XCTAssertEqual(MarkdownEditorMode.allCases, [.source, .livePreview])
    }

    func testInactiveParagraphCollapsesCommonInlineSyntax() {
        let source = """
        # **Café 👩🏽‍💻** and [guide](https://example.test/a/really/long/path)
        Other ==mark== ~~old~~ `code`
        """
        let selection = (source as NSString).range(of: "Other")

        let hidden = hiddenSubstrings(in: source, selection: selection)

        XCTAssertEqual(
            hidden,
            ["# **", "**", "[", "](https://example.test/a/really/long/path)"]
        )
    }

    func testActiveUnicodeParagraphRevealsItsSyntax() {
        let source = """
        # **Café 👩🏽‍💻** and [guide](https://example.test)
        Other ==mark== ~~old~~ `code`
        """
        let selection = (source as NSString).range(of: "👩🏽‍💻")

        let hidden = hiddenSubstrings(in: source, selection: selection)

        XCTAssertEqual(hidden, ["==", "==", "~~", "~~", "`", "`"])
    }

    func testSelectionAcrossParagraphsRevealsEveryTouchedParagraph() {
        let source = "**first**\n[second](https://example.test)\n==third=="
        let start = (source as NSString).range(of: "first").location
        let end = NSMaxRange((source as NSString).range(of: "second"))
        let selection = NSRange(location: start, length: end - start)

        let hidden = hiddenSubstrings(in: source, selection: selection)

        XCTAssertEqual(hidden, ["==", "=="])
    }

    func testSourceModeNeverRequestsHiddenRanges() {
        let source = "# **Café 👩🏽‍💻** [guide](https://example.test)"
        let result = MarkdownSyntax.parse(source)
        let snapshot = MarkdownLivePreviewSnapshot(
            mode: .source,
            selection: NSRange(location: 0, length: 0)
        )

        XCTAssertTrue(
            MarkdownLivePreview.hiddenRanges(
                in: source,
                result: result,
                snapshot: snapshot
            ).isEmpty
        )
    }

    func testUnfocusedPreviewCollapsesSyntaxInEveryParagraph() {
        let source = "**first**\n[second](https://example.test)"
        let result = MarkdownSyntax.parse(source)
        let snapshot = MarkdownLivePreviewSnapshot(
            mode: .livePreview,
            selection: (source as NSString).range(of: "first"),
            isEditing: false
        )

        let hidden = MarkdownLivePreview.hiddenRanges(
            in: source,
            result: result,
            snapshot: snapshot
        ).map { (source as NSString).substring(with: $0) }

        XCTAssertEqual(
            hidden,
            ["**", "**", "[", "](https://example.test)"]
        )
    }

    func testCaretAfterTrailingNewlineDoesNotRevealPreviousParagraph() {
        let source = "**finished**\n"
        let selection = NSRange(
            location: (source as NSString).length,
            length: 0
        )

        let hidden = hiddenSubstrings(in: source, selection: selection)

        XCTAssertEqual(hidden, ["**", "**"])
    }

    func testInactiveEmptyHeadingsKeepTheirSourceMarkersVisible() {
        let source = [
            "#", "##   ", "###", "####", "#####", "######", "> ##",
            "Active",
        ].joined(separator: "\n")
        let selection = (source as NSString).range(of: "Active")

        XCTAssertEqual(
            hiddenSubstrings(in: source, selection: selection),
            []
        )
    }

    func testEmptyHeadingBeforeTrailingNewlineRemainsVisible() {
        let source = "##\n"
        let selection = NSRange(
            location: (source as NSString).length,
            length: 0
        )

        XCTAssertEqual(
            hiddenSubstrings(in: source, selection: selection),
            []
        )
    }

    func testInactiveHeadingWithContentStillCollapsesOpeningMarker() {
        let source = "## Heading ##\nActive"
        let selection = (source as NSString).range(of: "Active")

        XCTAssertEqual(
            hiddenSubstrings(in: source, selection: selection),
            ["## "]
        )
    }

    func testNestedQuoteAndListPrefixesKeepInlineRangesBounded() {
        let source = """
        > * **quoted _café_**
        > continuation with [link](https://example.test)
        Plain
        """
        let selection = (source as NSString).range(of: "Plain")
        let result = MarkdownSyntax.parse(source)
        let snapshot = MarkdownLivePreviewSnapshot(
            mode: .livePreview,
            selection: selection
        )

        let ranges = MarkdownLivePreview.hiddenRanges(
            in: source,
            result: result,
            snapshot: snapshot
        )
        let hidden = ranges.map { (source as NSString).substring(with: $0) }

        XCTAssertEqual(
            hidden,
            ["**", "_", "_**", "[", "](https://example.test)"]
        )
        XCTAssertTrue(ranges.allSatisfy { Range($0, in: source) != nil })
    }

    func testInactiveUnorderedAndQuoteMarkersUseTransparentPresentation() {
        let source = """
        * first
        12. ordered
        > quote
        * > nested
        Active
        """
        let selection = (source as NSString).range(of: "Active")

        XCTAssertEqual(
            transparentSubstrings(in: source, selection: selection),
            ["*", ">", "*", ">"]
        )
    }

    func testActiveParagraphRevealsItsListAndQuoteMarkers() {
        let source = "* other\n> active quote"
        let selection = (source as NSString).range(of: "active")

        XCTAssertEqual(
            transparentSubstrings(in: source, selection: selection),
            ["*"]
        )
    }

#if os(macOS)
    func testInactiveEmptyHeadingRetainsVisibleTextAttributes() throws {
        let source = "##\nActive"
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        textView.string = source
        textView.setSelectedRange(
            (source as NSString).range(of: "Active")
        )

        MarkdownPresentation.configure(textView, mode: .livePreview)

        let storage = try XCTUnwrap(textView.textStorage)
        let markerFont = try XCTUnwrap(
            storage.attribute(
                .font,
                at: 0,
                effectiveRange: nil
            ) as? NSFont
        )
        let markerColor = try XCTUnwrap(
            storage.attribute(
                .foregroundColor,
                at: 0,
                effectiveRange: nil
            ) as? NSColor
        )
        XCTAssertGreaterThan(markerFont.pointSize, 1)
        XCTAssertEqual(markerColor, NSColor.textColor)
    }

    func testTypingStrikethroughAfterPreviouslyHiddenStrongText() throws {
        let source = "**B**"
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        textView.allowsUndo = true
        textView.string = source
        textView.setSelectedRange(
            NSRange(location: (source as NSString).length, length: 0)
        )
        MarkdownPresentation.configure(textView, mode: .livePreview)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = textView
        XCTAssertTrue(window.makeFirstResponder(textView))

        textView.insertText(
            "~",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let firstTilde = (textView.string as NSString).range(of: "~").location
        let insertedFont = try XCTUnwrap(
            textView.textStorage?.attribute(
                .font,
                at: firstTilde,
                effectiveRange: nil
            ) as? NSFont
        )
        let insertedColor = try XCTUnwrap(
            textView.textStorage?.attribute(
                .foregroundColor,
                at: firstTilde,
                effectiveRange: nil
            ) as? NSColor
        )
        XCTAssertGreaterThan(insertedFont.pointSize, 1)
        XCTAssertEqual(insertedColor, NSColor.textColor)
        MarkdownPresentation.refresh(textView, mode: .livePreview)

        for character in ["~", "word", "~", "~"] {
            textView.insertText(
                character,
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            MarkdownPresentation.refresh(textView, mode: .livePreview)
        }

        XCTAssertEqual(textView.string, "**B**~~word~~")
        XCTAssertEqual(
            textView.selectedRange(),
            NSRange(location: (textView.string as NSString).length, length: 0)
        )
        let font = try XCTUnwrap(
            textView.textStorage?.attribute(
                .font,
                at: firstTilde,
                effectiveRange: nil
            ) as? NSFont
        )
        let color = try XCTUnwrap(
            textView.textStorage?.attribute(
                .foregroundColor,
                at: firstTilde,
                effectiveRange: nil
            ) as? NSColor
        )
        XCTAssertGreaterThan(font.pointSize, 1)
        XCTAssertEqual(color, NSColor.textColor)
    }

    func testListBulletPresentationKeepsSourceMarkerGeometry() throws {
        let source = "* item\n12. ordered\n> quote\nActive"
        let selection = (source as NSString).range(of: "Active")
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        textView.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        textView.allowsUndo = true
        textView.string = source
        textView.setSelectedRange(selection)
        MarkdownPresentation.configure(textView, mode: .livePreview)
        textView.undoManager?.removeAllActions()
        let layoutManager = try XCTUnwrap(textView.textLayoutManager)
        layoutManager.ensureLayout(
            for: try XCTUnwrap(layoutManager.textContentManager).documentRange
        )
        let result = MarkdownSyntax.parse(source)
        let snapshot = MarkdownLivePreview.snapshot(for: textView)

        let unordered = (source as NSString).range(of: "*").location
        let ordered = (source as NSString).range(of: "12.").location
        let quote = (source as NSString).range(of: ">").location
        let unorderedFont = try XCTUnwrap(
            textView.textStorage?.attribute(
                .font,
                at: unordered,
                effectiveRange: nil
            ) as? NSFont
        )
        XCTAssertGreaterThan(unorderedFont.pointSize, 1)
        XCTAssertEqual(
            textView.textStorage?.attribute(
                .foregroundColor,
                at: unordered,
                effectiveRange: nil
            ) as? NSColor,
            NSColor.clear
        )
        XCTAssertEqual(
            textView.textStorage?.attribute(
                .foregroundColor,
                at: quote,
                effectiveRange: nil
            ) as? NSColor,
            NSColor.clear
        )
        XCTAssertEqual(
            textView.textStorage?.attribute(
                .foregroundColor,
                at: ordered,
                effectiveRange: nil
            ) as? NSColor,
            NSColor.textColor
        )
        let bullets = MarkdownPresentation.listBulletDecorations(
            text: source,
            result: result,
            layoutManager: layoutManager,
            snapshot: snapshot
        )
        XCTAssertEqual(bullets.count, 1)
        XCTAssertGreaterThan(bullets[0].rect.width, 0)
        XCTAssertEqual(textView.string, source)
        XCTAssertEqual(textView.selectedRange(), selection)
        XCTAssertFalse(textView.undoManager?.canUndo == true)
    }

    func testTaskCheckboxRendersWithoutChangingLiteralSource() throws {
        let source = "- [ ] Pack a map\n- [x] Mark the route\nActive"
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        textView.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        textView.string = source
        textView.setSelectedRange((source as NSString).range(of: "Active"))
        MarkdownPresentation.configure(textView, mode: .livePreview)
        let manager = try XCTUnwrap(textView.textLayoutManager)
        manager.ensureLayout(
            for: try XCTUnwrap(manager.textContentManager).documentRange
        )
        let syntax = MarkdownSyntax.parse(source)
        let snapshot = MarkdownLivePreview.snapshot(for: textView)
        let ranges = MarkdownLivePreview.ranges(
            in: source, result: syntax, snapshot: snapshot
        )
        let unchecked = (source as NSString).range(of: "[ ]")
        let checked = (source as NSString).range(of: "[x]")
        XCTAssertTrue(ranges.transparent.contains(unchecked))
        XCTAssertTrue(ranges.transparent.contains(checked))
        let checkboxes = MarkdownPresentation.taskCheckboxDecorations(
            text: source, result: syntax, layoutManager: manager,
            snapshot: snapshot
        )
        XCTAssertEqual(checkboxes.map(\.checked), [false, true])
        XCTAssertEqual(checkboxes.map(\.range), [unchecked, checked])
        XCTAssertTrue(checkboxes.allSatisfy { $0.rect.width >= 19 })
        XCTAssertEqual(
            checkboxes[0].rect.midX, checkboxes[1].rect.midX,
            accuracy: 0.5
        )
        let hit = checkboxes[0].rect.offsetBy(
            dx: textView.textContainerOrigin.x,
            dy: textView.textContainerOrigin.y
        )
        XCTAssertEqual(
            MarkdownPresentation.taskCheckbox(
                at: CGPoint(x: hit.midX, y: hit.midY), in: textView
            )?.range,
            unchecked
        )
        XCTAssertEqual(textView.string, source)
        XCTAssertTrue(MarkdownPresentation.listBulletDecorations(
            text: source, result: syntax, layoutManager: manager,
            snapshot: snapshot
        ).isEmpty)
        let active = MarkdownLivePreviewSnapshot(
            mode: .livePreview,
            selection: (source as NSString).range(of: "Pack")
        )
        let activeRanges = MarkdownLivePreview.ranges(
            in: source, result: syntax, snapshot: active
        )
        XCTAssertTrue(activeRanges.transparent.contains(unchecked))
        XCTAssertTrue(activeRanges.transparent.contains(
            (source as NSString).range(of: "-")
        ))
    }

    func testTaskCheckboxReflectsExternalSourceReplacement() throws {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        textView.string = "- [ ] Pack a map"
        MarkdownPresentation.configure(textView, mode: .livePreview)
        textView.textStorage?.replaceCharacters(
            in: NSRange(location: 0, length: (textView.string as NSString).length),
            with: "- [x] Pack a map"
        )
        MarkdownPresentation.refresh(textView, mode: .livePreview)
        let manager = try XCTUnwrap(textView.textLayoutManager)
        manager.ensureLayout(
            for: try XCTUnwrap(manager.textContentManager).documentRange
        )
        let checkboxes = MarkdownPresentation.taskCheckboxDecorations(
            text: textView.string,
            result: MarkdownPresentation.syntaxCache(for: textView)
                .result(for: textView.string),
            layoutManager: manager,
            snapshot: MarkdownLivePreview.snapshot(for: textView)
        )
        XCTAssertEqual(checkboxes.map(\.checked), [true])
        XCTAssertEqual(textView.string, "- [x] Pack a map")
    }

    func testTaskCheckboxesRemainDrawableBeforeDeferredRefresh() throws {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        textView.string = "- [ ] First\n- [ ] Second"
        MarkdownPresentation.configure(textView, mode: .livePreview)
        let cache = MarkdownPresentation.syntaxCache(for: textView)
        XCTAssertNotNil(cache.currentPresentation)

        let changed = (textView.string as NSString).range(of: "[ ]")
        let textStorage = try XCTUnwrap(textView.textStorage)
        textStorage.replaceCharacters(in: changed, with: "[x]")
        XCTAssertNil(cache.currentPresentation)

        let presentation = MarkdownPresentation.presentationForDrawing(
            in: textStorage,
            syntaxCache: cache,
            snapshot: MarkdownLivePreview.snapshot(for: textView)
        )
        let taskStates = presentation.result.spans.compactMap { span -> Bool? in
            guard case let .taskMarker(checked) = span.role else { return nil }
            return checked
        }
        XCTAssertEqual(taskStates, [true, false])
        XCTAssertNotNil(cache.currentPresentation)
    }

    func testTaskSpacingOnlyChangesLivePreviewLists() throws {
        let source = "- Ordinary\n- [ ] First\n- [x] Second"
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        textView.string = source
        MarkdownPresentation.configure(textView, mode: .livePreview)
        let storage = try XCTUnwrap(textView.textStorage)
        let firstTask = (source as NSString).range(of: "- [ ]").location
        let lastTask = (source as NSString).range(of: "- [x]").location
        func spacing(at location: Int) throws -> CGFloat {
            try XCTUnwrap(storage.attribute(
                .paragraphStyle, at: location, effectiveRange: nil
            ) as? NSParagraphStyle).paragraphSpacing
        }

        let ordinary = try spacing(at: 0)
        XCTAssertGreaterThan(try spacing(at: firstTask), ordinary + 5)
        XCTAssertEqual(try spacing(at: firstTask), try spacing(at: lastTask))

        MarkdownPresentation.refresh(textView, mode: .source)
        XCTAssertEqual(try spacing(at: firstTask), try spacing(at: 0))
    }

    func testOverlappingTaskTapTargetsChooseNearestCheckbox() {
        let first = MarkdownPresentation.TaskCheckboxDecoration(
            range: NSRange(location: 0, length: 3),
            rect: CGRect(x: 0, y: 1, width: 18, height: 18),
            checked: false
        )
        let second = MarkdownPresentation.TaskCheckboxDecoration(
            range: NSRange(location: 20, length: 3),
            rect: CGRect(x: 0, y: 21, width: 18, height: 18),
            checked: false
        )
        let decorations = [first, second]
        let hit = { (y: CGFloat) in
            MarkdownPresentation.taskCheckboxHit(
                at: CGPoint(x: 9, y: y),
                in: decorations,
                minimumTargetSide: 44
            )?.range
        }

        XCTAssertEqual(hit(10), first.range)
        XCTAssertEqual(hit(30), second.range)
        XCTAssertEqual(hit(21), second.range)
    }

    func testModeSwitchPreservesSourceSelectionAndUndo() throws {
        let source = "# Title\n[map](https://example.test/a/long/path)\nEdit 👩🏽‍💻"
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.allowsUndo = true
        textView.string = source
        let selection = (source as NSString).range(of: "👩🏽‍💻")
        textView.setSelectedRange(selection)
        MarkdownPresentation.configure(textView, mode: .livePreview)
        textView.undoManager?.removeAllActions()
        let markerLocation = (source as NSString).range(of: "#").location
        let storage = try XCTUnwrap(textView.textStorage)

        let hiddenFont = try XCTUnwrap(
            storage.attribute(
                .font,
                at: markerLocation,
                effectiveRange: nil
            ) as? NSFont
        )
        XCTAssertEqual(
            hiddenFont.pointSize,
            MarkdownLivePreview.collapsedFontSize,
            accuracy: 0.0001
        )
        XCTAssertEqual(textView.string, source)
        XCTAssertEqual(textView.selectedRange(), selection)
        XCTAssertFalse(textView.undoManager?.canUndo == true)

        MarkdownPresentation.refresh(textView, mode: .source)

        let restoredFont = try XCTUnwrap(
            storage.attribute(
                .font,
                at: markerLocation,
                effectiveRange: nil
            ) as? NSFont
        )
        let restoredColor = try XCTUnwrap(
            storage.attribute(
                .foregroundColor,
                at: markerLocation,
                effectiveRange: nil
            ) as? NSColor
        )
        XCTAssertGreaterThan(restoredFont.pointSize, 1)
        XCTAssertEqual(restoredColor, NSColor.textColor)
        XCTAssertEqual(textView.string, source)
        XCTAssertEqual(textView.selectedRange(), selection)
        XCTAssertFalse(textView.undoManager?.canUndo == true)
    }

    func testLongLinkDestinationHasCollapsedLayoutAttributes() throws {
        let destination = String(repeating: "long-segment/", count: 300)
        let source = "[label](https://example.test/\(destination))\nActive"
        let selection = (source as NSString).range(of: "Active")
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.frame = NSRect(x: 0, y: 0, width: 10_000, height: 500)
        textView.string = source
        textView.setSelectedRange(selection)

        MarkdownPresentation.configure(textView, mode: .livePreview)
        textView.layoutSubtreeIfNeeded()

        let urlLocation = (source as NSString).range(of: "https:").location
        let font = try XCTUnwrap(
            textView.textStorage?.attribute(
                .font,
                at: urlLocation,
                effectiveRange: nil
            ) as? NSFont
        )
        let kern = textView.textStorage?.attribute(
            .kern,
            at: urlLocation,
            effectiveRange: nil
        ) as? CGFloat
        XCTAssertEqual(
            font.pointSize,
            MarkdownLivePreview.collapsedFontSize,
            accuracy: 0.0001
        )
        XCTAssertEqual(kern, -MarkdownLivePreview.collapsedFontSize)
        let labelEnd = NSMaxRange((source as NSString).range(of: "label"))
        let linkEnd = (source as NSString).range(of: "\n").location
        var actualRange = NSRange()
        let labelRect = textView.firstRect(
            forCharacterRange: NSRange(location: labelEnd, length: 0),
            actualRange: &actualRange
        )
        let linkRect = textView.firstRect(
            forCharacterRange: NSRange(location: linkEnd, length: 0),
            actualRange: &actualRange
        )
        XCTAssertLessThan(abs(linkRect.minX - labelRect.minX), 2)
        XCTAssertEqual(textView.string, source)
    }
#endif

    private func hiddenSubstrings(
        in source: String,
        selection: NSRange,
        mode: MarkdownEditorMode = .livePreview
    ) -> [String] {
        let result = MarkdownSyntax.parse(source)
        let snapshot = MarkdownLivePreviewSnapshot(
            mode: mode,
            selection: selection
        )
        return MarkdownLivePreview.hiddenRanges(
            in: source,
            result: result,
            snapshot: snapshot
        ).map { (source as NSString).substring(with: $0) }
    }

    private func transparentSubstrings(
        in source: String,
        selection: NSRange,
        mode: MarkdownEditorMode = .livePreview
    ) -> [String] {
        let result = MarkdownSyntax.parse(source)
        let snapshot = MarkdownLivePreviewSnapshot(
            mode: mode,
            selection: selection
        )
        return MarkdownLivePreview.transparentRanges(
            in: source,
            result: result,
            snapshot: snapshot
        ).map { (source as NSString).substring(with: $0) }
    }
}
