import Foundation
import NoteCore
import ObjectiveC

#if os(macOS)
import AppKit

typealias PlatformFont = NSFont
typealias PlatformFontDescriptor = NSFontDescriptor
typealias PlatformColor = NSColor
#else
import UIKit

typealias PlatformFont = UIFont
typealias PlatformFontDescriptor = UIFontDescriptor
typealias PlatformColor = UIColor
#endif

nonisolated(unsafe) private var markdownPresentationSyntaxCacheKey: UInt8 = 0

enum EditorFontFamily: String, CaseIterable, Identifiable {
    case system
    case serif
    case rounded
    case monospaced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .serif: "Serif"
        case .rounded: "Rounded"
        case .monospaced: "Monospaced"
        }
    }
}

enum MarkdownPresentation {
    static let defaultFontSize: CGFloat = 17
    static let fontSizeRange: ClosedRange<CGFloat> = 12...28

    struct BlockDecoration: Equatable {
        enum Kind: Equatable {
            case blockquote
            case codeBlock
        }

        let kind: Kind
        let rect: CGRect

        var accentRect: CGRect? {
            guard kind == .blockquote else { return nil }
            return CGRect(
                x: rect.minX - 3,
                y: rect.minY,
                width: 2,
                height: rect.height
            )
        }
    }

    struct ListBulletDecoration: Equatable {
        let rect: CGRect
    }

    struct TaskCheckboxDecoration: Equatable {
        let range: NSRange
        let rect: CGRect
        let checked: Bool
    }

#if os(macOS)
    static var editorBodyFont: PlatformFont {
        bodyFont(for: .system, pointSize: defaultFontSize)
    }
#else
    static var editorBodyFont: PlatformFont {
        bodyFont(for: .system, pointSize: defaultFontSize)
    }
#endif

    static func normalizedFontSize(_ value: Double) -> CGFloat {
        guard value.isFinite else { return defaultFontSize }
        return min(max(CGFloat(value), fontSizeRange.lowerBound),
                   fontSizeRange.upperBound)
    }

#if os(macOS)
    static func configure(
        _ textView: NSTextView,
        fontSize: Double = 17,
        fontFamily: EditorFontFamily = .system,
        mode: MarkdownEditorMode = .source
    ) {
        guard let layoutManager = textView.textLayoutManager else {
            assertionFailure("Markdown editor requires TextKit 2")
            return
        }

        MarkdownLivePreview.update(
            textView,
            mode: mode,
            selection: textView.selectedRange(),
            isEditing: textView.window?.firstResponder === textView,
            fontSize: normalizedFontSize(fontSize)
        )
        let syntaxCache = syntaxCache(for: textView)
        if let textStorage = textView.textStorage {
            syntaxCache.observeCharacterEdits(in: textStorage)
        }
        layoutManager.renderingAttributesValidator = {
            manager, fragment in
            guard let presentation = syntaxCache.currentPresentation else {
                return
            }
            _ = applyRenderingAttributes(
                to: manager,
                fragment: fragment,
                presentation: presentation
            )
        }
        let font = bodyFont(
            for: fontFamily,
            pointSize: normalizedFontSize(fontSize)
        )
        textView.font = font
        refresh(
            textView,
            fontSize: fontSize,
            fontFamily: fontFamily,
            mode: mode,
            syntaxCache: syntaxCache
        )
    }

    static func refresh(
        _ textView: NSTextView,
        fontSize: Double = 17,
        fontFamily: EditorFontFamily = .system,
        mode: MarkdownEditorMode = .source,
        syntaxCache suppliedSyntaxCache: MarkdownSyntaxCache? = nil
    ) {
        let selection = textView.selectedRange()
        MarkdownLivePreview.update(
            textView,
            mode: mode,
            selection: selection,
            isEditing: textView.window?.firstResponder === textView,
            fontSize: normalizedFontSize(fontSize)
        )
        guard !textView.hasMarkedText(),
              let textStorage = textView.textStorage else { return }

        let syntaxCache = suppliedSyntaxCache ?? Self.syntaxCache(for: textView)
        let text = syntaxCache.prepare(in: textStorage)
        let snapshot = MarkdownLivePreview.snapshot(for: textView)
        let presentation = syntaxCache.presentation(
            in: textStorage,
            snapshot: snapshot
        )
        let result = presentation.result
        let bodyFont = bodyFont(
            for: fontFamily,
            pointSize: normalizedFontSize(fontSize)
        )
        let previewRanges = presentation.previewRanges
        var layoutRange = syntaxCache.layoutRange(
            for: presentation, text: text, bodyFont: bodyFont
        )
        let tableWidth = snapshot.tableWidth
        if let tableRange = syntaxCache.prepareTables(
            text: text, presentation: presentation,
            bodyFont: bodyFont, width: tableWidth,
            activeCell: (textView as? MarkdownTextView)?.markdownCellController.target,
            activeColumnWidths: (textView as? MarkdownTextView)?.markdownCellController.fixedColumnWidths
        ) {
            layoutRange = layoutRange.length == 0 ? tableRange
                : NSUnionRange(layoutRange, tableRange)
        }
        syntaxCache.tableRefresh = { [weak textView] in
            guard let textView else { return }
            refresh(textView, fontSize: fontSize, fontFamily: fontFamily, mode: mode)
        }
        syntaxCache.isApplyingLayoutAttributes = true
        applyLayoutAttributes(
            to: textStorage,
            text: text,
            result: result,
            bodyFont: bodyFont,
            hiddenRanges: previewRanges.collapsed,
            transparentRanges: previewRanges.transparent,
            livePreview: mode == .livePreview,
            undoManager: textView.undoManager,
            range: layoutRange,
            tableLayout: syntaxCache.tableLayout
        )
        syntaxCache.isApplyingLayoutAttributes = false
        if textView.selectedRange() != selection {
            textView.setSelectedRange(selection)
        }
        applyBaseTypingAttributes(to: textView, bodyFont: bodyFont)
        refreshVisibleRenderingAttributes(
            in: textView.textLayoutManager,
            text: text,
            syntaxCache: syntaxCache,
            presentation: presentation,
            invalidatedRange: layoutRange
        )
        textView.needsDisplay = true
        textView.window?.invalidateCursorRects(for: textView)
        (textView as? MarkdownTextView)?.updateMarkdownTableScrollOverlays()
    }

    static func syntaxCache(
        for textView: NSTextView
    ) -> MarkdownSyntaxCache {
        if let markdownTextView = textView as? MarkdownTextView {
            return markdownTextView.markdownSyntaxCache
        }
        if let cache = objc_getAssociatedObject(
            textView,
            &markdownPresentationSyntaxCacheKey
        ) as? MarkdownSyntaxCache {
            return cache
        }
        let cache = MarkdownSyntaxCache()
        objc_setAssociatedObject(
            textView,
            &markdownPresentationSyntaxCacheKey,
            cache,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return cache
    }

    private static func applyBaseTypingAttributes(
        to textView: NSTextView,
        bodyFont: PlatformFont
    ) {
        var attributes = textView.typingAttributes
        attributes[.font] = bodyFont
        attributes[.foregroundColor] = primaryTextColor
        attributes[.paragraphStyle] = bodyParagraphStyle(for: bodyFont)
        textView.typingAttributes = attributes
    }

    static func drawBlockBackgrounds(
        in textView: NSTextView,
        dirtyRect: CGRect
    ) {
        guard let layoutManager = textView.textLayoutManager,
              let textContainer = textView.textContainer,
              let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        guard let visibleRange = visibleRange(in: layoutManager) else { return }
        let text = textView.string
        let syntaxCache = syntaxCache(for: textView)
        guard let presentation = syntaxCache.currentPresentation else {
            return
        }
        drawBlockBackgrounds(
            text: text,
            syntaxCache: syntaxCache,
            result: presentation.result,
            layoutManager: layoutManager,
            containerWidth: textContainer.size.width,
            lineFragmentPadding: textContainer.lineFragmentPadding,
            containerOrigin: textView.textContainerOrigin,
            visibleRange: visibleRange,
            dirtyRect: dirtyRect,
            context: context
        )
        if let tableLayout = syntaxCache.tableLayout,
           let manager = layoutManager.textContentManager,
           let start = manager.location(manager.documentRange.location,
                                        offsetBy: visibleRange.location) {
            layoutManager.enumerateTextLayoutFragments(from: start) { fragment in
                let frame = fragment.layoutFragmentFrame.offsetBy(
                    dx: textView.textContainerOrigin.x,
                    dy: textView.textContainerOrigin.y
                )
                if frame.minY > dirtyRect.maxY { return false }
                if frame.intersects(dirtyRect) {
                    tableLayout.draw(
                        fragment: fragment, layoutManager: layoutManager,
                        origin: textView.textContainerOrigin,
                        lineFragmentPadding: textContainer.lineFragmentPadding,
                        context: context,
                        horizontalOffsets: (textView as? MarkdownTextView)?.markdownTableDrawingOffsets
                            ?? syntaxCache.tableHorizontalOffsets,
                        activeCell: (textView as? MarkdownTextView)?.markdownCellController.target
                    )
                }
                return true
            }
        }
        drawListBullets(
            listBulletDecorations(
                text: text,
                result: presentation.result,
                layoutManager: layoutManager,
                snapshot: MarkdownLivePreview.snapshot(for: textView),
                visibleRange: visibleRange,
                spanIndices: presentation.spanCandidateIndices(
                    intersecting: visibleRange
                )
            ),
            offset: textView.textContainerOrigin,
            dirtyRect: dirtyRect,
            context: context
        )
        drawTaskCheckboxes(
            taskCheckboxDecorations(
                text: text,
                result: presentation.result,
                layoutManager: layoutManager,
                snapshot: MarkdownLivePreview.snapshot(for: textView),
                visibleRange: visibleRange,
                spanIndices: presentation.spanCandidateIndices(
                    intersecting: visibleRange
                )
            ),
            offset: textView.textContainerOrigin,
            dirtyRect: dirtyRect,
            context: context
        )
    }
#else
    static func configure(
        _ textView: UITextView,
        fontSize: Double = 17,
        fontFamily: EditorFontFamily = .system,
        mode: MarkdownEditorMode = .source
    ) {
        guard let layoutManager = textView.textLayoutManager else {
            assertionFailure("Markdown editor requires TextKit 2")
            return
        }
        guard let markdownTextView = textView as? MarkdownTextView else {
            assertionFailure("Markdown editor requires MarkdownTextView")
            return
        }
        markdownTextView.installMarkdownLayoutManagerDelegate(
            on: layoutManager
        )
        markdownTextView.installMarkdownTableScrolling()
        markdownTextView.installMarkdownTaskTap()

        MarkdownLivePreview.update(
            textView,
            mode: mode,
            selection: textView.selectedRange,
            isEditing: textView.isFirstResponder,
            fontSize: normalizedFontSize(fontSize)
        )
        let syntaxCache = syntaxCache(for: textView)
        syntaxCache.observeCharacterEdits(in: textView.textStorage)
        layoutManager.renderingAttributesValidator = {
            manager, fragment in
            guard let presentation = syntaxCache.currentPresentation else {
                return
            }
            _ = applyRenderingAttributes(
                to: manager,
                fragment: fragment,
                presentation: presentation
            )
        }
        let font = bodyFont(
            for: fontFamily,
            pointSize: normalizedFontSize(fontSize)
        )
        textView.font = font
        refresh(
            textView,
            fontSize: fontSize,
            fontFamily: fontFamily,
            mode: mode,
            syntaxCache: syntaxCache
        )
    }

    static func refresh(
        _ textView: UITextView,
        fontSize: Double = 17,
        fontFamily: EditorFontFamily = .system,
        mode: MarkdownEditorMode = .source,
        syntaxCache suppliedSyntaxCache: MarkdownSyntaxCache? = nil
    ) {
        let selection = textView.selectedRange
        MarkdownLivePreview.update(
            textView,
            mode: mode,
            selection: selection,
            isEditing: textView.isFirstResponder,
            fontSize: normalizedFontSize(fontSize)
        )
        guard textView.markedTextRange == nil else { return }

        let syntaxCache = suppliedSyntaxCache ?? Self.syntaxCache(for: textView)
        let text = syntaxCache.prepare(in: textView.textStorage)
        let snapshot = MarkdownLivePreview.snapshot(for: textView)
        let presentation = syntaxCache.presentation(
            in: textView.textStorage,
            snapshot: snapshot
        )
        let result = presentation.result
        let bodyFont = bodyFont(
            for: fontFamily,
            pointSize: normalizedFontSize(fontSize)
        )
        (textView as? MarkdownTextView)?.markdownBodyLineHeight = bodyFont.lineHeight
        let previewRanges = presentation.previewRanges
        var layoutRange = syntaxCache.layoutRange(
            for: presentation, text: text, bodyFont: bodyFont
        )
        let tableWidth = snapshot.tableWidth
        if let tableRange = syntaxCache.prepareTables(
            text: text, presentation: presentation,
            bodyFont: bodyFont, width: tableWidth,
            activeCell: (textView as? MarkdownTextView)?.markdownCellController.target,
            activeColumnWidths: (textView as? MarkdownTextView)?.markdownCellController.fixedColumnWidths
        ) {
            layoutRange = layoutRange.length == 0 ? tableRange
                : NSUnionRange(layoutRange, tableRange)
        }
        // Gap ownership can change on either side of an edit, especially
        // when a formerly empty EOF gains its first stored character.
        let renderingRange = layoutRange
        layoutRange = paragraphGapLayoutRange(layoutRange, in: text)
        syntaxCache.recordAppliedLayoutRange(layoutRange)
        syntaxCache.tableRefresh = { [weak textView] in
            guard let textView else { return }
            refresh(textView, fontSize: fontSize, fontFamily: fontFamily, mode: mode)
        }
        syntaxCache.isApplyingLayoutAttributes = true
        applyLayoutAttributes(
            to: textView.textStorage,
            text: text,
            result: result,
            bodyFont: bodyFont,
            hiddenRanges: previewRanges.collapsed,
            transparentRanges: previewRanges.transparent,
            livePreview: mode == .livePreview,
            undoManager: textView.undoManager,
            range: layoutRange,
            tableLayout: syntaxCache.tableLayout
        )
        syntaxCache.isApplyingLayoutAttributes = false
        if textView.selectedRange != selection {
            textView.selectedRange = selection
        }
        applyBaseTypingAttributes(to: textView, bodyFont: bodyFont)
        refreshVisibleRenderingAttributes(
            in: textView.textLayoutManager,
            text: text,
            syntaxCache: syntaxCache,
            presentation: presentation,
            invalidatedRange: renderingRange
        )
        textView.setNeedsDisplay()
        (textView as? MarkdownTextView)?.updateMarkdownTableScrollOverlays()
    }

    static func syntaxCache(
        for textView: UITextView
    ) -> MarkdownSyntaxCache {
        if let markdownTextView = textView as? MarkdownTextView {
            return markdownTextView.markdownSyntaxCache
        }
        if let cache = objc_getAssociatedObject(
            textView,
            &markdownPresentationSyntaxCacheKey
        ) as? MarkdownSyntaxCache {
            return cache
        }
        let cache = MarkdownSyntaxCache()
        objc_setAssociatedObject(
            textView,
            &markdownPresentationSyntaxCacheKey,
            cache,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return cache
    }

    private static func applyBaseTypingAttributes(
        to textView: UITextView,
        bodyFont: PlatformFont
    ) {
        var attributes = textView.typingAttributes
        attributes[.font] = bodyFont
        attributes[.foregroundColor] = primaryTextColor
        let style = bodyParagraphStyle(for: bodyFont)
        let source = (textView.text ?? "") as NSString
        let position = min(source.length, textView.selectedRange.location)
        let paragraph = source.paragraphRange(
            for: NSRange(location: position, length: 0)
        )
        let cache = syntaxCache(for: textView)
        if paragraph.location > 0, paragraph.length > 0,
           let presentation = cache.currentPresentation {
            let previous = source.paragraphRange(
                for: NSRange(location: paragraph.location - 1, length: 0)
            )
            var taskParagraphs: Set<Int> = []
            if MarkdownLivePreview.snapshot(for: textView).mode == .livePreview,
               let run = presentation.result.paragraphRuns.last(where: {
                   NSLocationInRange(previous.location, $0.range)
               }) {
                presentation.forEachSpan(intersecting: run.range) { span in
                    if case .taskMarker = span.role {
                        taskParagraphs.insert(run.range.location)
                    }
                }
            }
            style.paragraphSpacingBefore = originalParagraphSpacing(
                at: previous.location, source: source,
                result: presentation.result, bodyFont: bodyFont,
                taskParagraphs: taskParagraphs, tableLayout: cache.tableLayout
            )
        }
        attributes[.paragraphStyle] = style
        textView.typingAttributes = attributes
    }

    static func drawBlockBackgrounds(
        in fragment: NSTextLayoutFragment,
        textView: UITextView,
        at point: CGPoint,
        context: CGContext
    ) {
        guard let textView = textView as? MarkdownTextView,
              let layoutManager = fragment.textLayoutManager,
              let contentManager = layoutManager.textContentManager else {
            return
        }
        let fragmentRange = nsRange(
            for: fragment.rangeInElement,
            documentStart: contentManager.documentRange.location,
            contentManager: contentManager
        )
        let text = textView.text ?? ""
        let syntaxCache = syntaxCache(for: textView)
        // An edit invalidates the presentation before the coordinator's
        // deferred refresh. Keep decorations visible during that interval.
        let presentation = presentationForDrawing(
            in: textView.textStorage,
            syntaxCache: syntaxCache,
            snapshot: MarkdownLivePreview.snapshot(for: textView)
        )
        let result = presentation.result
        let decorations = fragmentBlockDecorations(
            fragmentRange: fragmentRange,
            fragmentFrame: fragment.layoutFragmentFrame,
            text: textView.text ?? "",
            plan: syntaxCache.decorationPlan(for: text, result: result),
            syntaxCache: syntaxCache,
            layoutManager: layoutManager,
            containerWidth: textView.textContainer.size.width,
            lineFragmentPadding: textView.textContainer.lineFragmentPadding
        )
        let fragmentFrame = fragment.layoutFragmentFrame
        let drawingOffset = CGPoint(
            x: point.x - fragmentFrame.minX,
            y: point.y - fragmentFrame.minY
        )

        context.saveGState()
        defer { context.restoreGState() }
        let surfaceBounds = fragment.renderingSurfaceBounds.offsetBy(
            dx: point.x,
            dy: point.y
        )
        context.clip(to: surfaceBounds)
        syntaxCache.tableLayout?.draw(
            fragment: fragment, layoutManager: layoutManager,
            origin: drawingOffset,
            lineFragmentPadding: textView.textContainer.lineFragmentPadding,
            context: context,
            horizontalOffsets: textView.markdownTableDrawingOffsets,
            activeCell: textView.markdownCellController.target
        )
        for decoration in decorations {
            let rect = decoration.rect.offsetBy(
                dx: drawingOffset.x,
                dy: drawingOffset.y
            )
            draw(decoration, in: rect, context: context)
        }
        drawListBullets(
            listBulletDecorations(
                text: text,
                result: result,
                layoutManager: layoutManager,
                snapshot: MarkdownLivePreview.snapshot(for: textView),
                visibleRange: fragmentRange,
                spanIndices: presentation.spanCandidateIndices(
                    intersecting: fragmentRange
                )
            ),
            offset: drawingOffset,
            dirtyRect: surfaceBounds,
            context: context
        )
        drawTaskCheckboxes(
            taskCheckboxDecorations(
                text: text,
                result: result,
                layoutManager: layoutManager,
                snapshot: MarkdownLivePreview.snapshot(for: textView),
                visibleRange: fragmentRange,
                spanIndices: presentation.spanCandidateIndices(
                    intersecting: fragmentRange
                )
            ),
            offset: drawingOffset,
            dirtyRect: surfaceBounds,
            context: context
        )
    }

    private static func fragmentBlockDecorations(
        fragmentRange: NSRange,
        fragmentFrame: CGRect,
        text: String,
        plan: MarkdownDecorationPlan,
        syntaxCache: MarkdownSyntaxCache,
        layoutManager: NSTextLayoutManager,
        containerWidth: CGFloat,
        lineFragmentPadding: CGFloat
    ) -> [BlockDecoration] {
        guard containerWidth > 0,
              let contentManager = layoutManager.textContentManager else {
            return []
        }
        let source = text as NSString
        var decorations: [BlockDecoration] = []

        for group in plan.groups(intersecting: fragmentRange) {
            let ownedGroupIndices = group.runIndices(
                intersecting: fragmentRange
            )
            guard let firstOwned = ownedGroupIndices.first,
                  let lastOwned = ownedGroupIndices.last else { continue }
            let ownedRange = NSRange(
                location: group.runs[firstOwned].paragraph.range.location,
                length: NSMaxRange(group.runs[lastOwned].paragraph.range)
                    - group.runs[firstOwned].paragraph.range.location
            )
            let lineFrames = textSegmentFrames(
                for: ownedRange,
                layoutManager: layoutManager,
                contentManager: contentManager
            )
            guard var top = lineFrames.map(\.minY).min(),
                  var bottom = lineFrames.map(\.maxY).max(),
                  bottom > top else { continue }

            if firstOwned > group.runs.startIndex {
                top = min(top, fragmentFrame.minY)
            } else if group.kind == .codeBlock {
                top -= codeBlockVerticalPadding(from: lineFrames)
            }
            if lastOwned < group.runs.index(before: group.runs.endIndex) {
                bottom = max(bottom, fragmentFrame.maxY)
            } else if group.kind == .codeBlock {
                bottom += codeBlockVerticalPadding(from: lineFrames)
            }

            let left: CGFloat
            if group.kind == .codeBlock {
                left = 0
            } else {
                guard let markerLeft = syntaxCache.cachedGroupLeft(
                    range: group.range,
                    fontSize: bodyFontPointSize(
                        in: contentManager,
                        at: group.range.location
                    ),
                    lineFragmentPadding: lineFragmentPadding,
                    calculate: {
                        group.runs.compactMap { run -> CGFloat? in
                            guard let marker = run.markerRange else {
                                return nil
                            }
                            return quoteMarkerFallbackX(
                                markerLocation: marker.location,
                                paragraph: run.paragraph,
                                text: source,
                                contentManager: contentManager,
                                lineFragmentPadding: lineFragmentPadding
                            )
                        }.min()
                    }
                ) else { continue }
                left = markerLeft
            }
            decorations.append(
                BlockDecoration(
                    kind: group.kind,
                    rect: CGRect(
                        x: left,
                        y: top,
                        width: max(0, containerWidth - left),
                        height: bottom - top
                    )
                )
            )
        }
        return decorations
    }

    private static func bodyFontPointSize(
        in contentManager: NSTextContentManager,
        at location: Int
    ) -> CGFloat {
        guard let contentStorage = contentManager as? NSTextContentStorage,
              let textStorage = contentStorage.textStorage,
              location < textStorage.length else { return defaultFontSize }
        return (textStorage.attribute(
            .font,
            at: location,
            effectiveRange: nil
        ) as? PlatformFont)?.pointSize ?? defaultFontSize
    }
#endif

    static func drawBlockBackgrounds(
        text: String,
        syntaxCache: MarkdownSyntaxCache,
        result suppliedResult: MarkdownSyntaxResult? = nil,
        layoutManager: NSTextLayoutManager,
        containerWidth: CGFloat,
        lineFragmentPadding: CGFloat,
        containerOrigin: CGPoint,
        visibleRange: NSRange?,
        dirtyRect: CGRect,
        context: CGContext
    ) {
        let decorations = blockDecorations(
            text: text,
            result: suppliedResult ?? syntaxCache.result(for: text),
            layoutManager: layoutManager,
            containerWidth: containerWidth,
            lineFragmentPadding: lineFragmentPadding,
            visibleRange: visibleRange
        )
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: dirtyRect)
        for decoration in decorations {
            let rect = decoration.rect.offsetBy(
                dx: containerOrigin.x,
                dy: containerOrigin.y
            )
            guard rect.intersects(dirtyRect) else { continue }
            draw(decoration, in: rect, context: context)
        }
    }

    private static func draw(
        _ decoration: BlockDecoration,
        in rect: CGRect,
        context: CGContext
    ) {
        let color: PlatformColor = decoration.kind == .blockquote
            ? PlatformColor.systemBlue.withAlphaComponent(0.07)
            : PlatformColor.secondarySystemFill
        context.setFillColor(color.cgColor)
        context.fill(rect)
        guard let accentRect = decoration.accentRect else { return }
        context.setFillColor(
            PlatformColor.systemBlue.withAlphaComponent(0.38).cgColor
        )
        context.fill(
            CGRect(
                x: rect.minX + accentRect.minX - decoration.rect.minX,
                y: rect.minY + accentRect.minY - decoration.rect.minY,
                width: accentRect.width,
                height: accentRect.height
            )
        )
    }

    static func listBulletDecorations(
        text: String,
        result: MarkdownSyntaxResult,
        layoutManager: NSTextLayoutManager,
        snapshot: MarkdownLivePreviewSnapshot,
        visibleRange: NSRange? = nil,
        spanIndices: Range<Int>? = nil
    ) -> [ListBulletDecoration] {
        guard let contentManager = layoutManager.textContentManager else {
            return []
        }
        let source = text as NSString
        if let contentStorage = contentManager as? NSTextContentStorage,
           contentStorage.textStorage?.length != source.length {
            return []
        }
        var decorations: [ListBulletDecoration] = []
        let indices = spanIndices ?? result.spans.indices
        let taskLines = Set(result.spans[indices].compactMap { span -> Int? in
            guard case .taskMarker = span.role else { return nil }
            return source.lineRange(for: span.range).location
        })
        for span in result.spans[indices] {
            if let visibleRange,
               NSMaxRange(span.range) <= visibleRange.location {
                continue
            }
            if let visibleRange,
               span.range.location >= NSMaxRange(visibleRange) {
                break
            }
            guard span.role == .listMarker, span.range.length == 1,
                  !taskLines.contains(source.lineRange(for: span.range).location),
                  MarkdownLivePreview.conceals(
                      span.range,
                      in: source,
                      snapshot: snapshot
                  ),
                  span.range.location < source.length else { continue }
            let marker = source.character(at: span.range.location)
            guard marker == 42 || marker == 43 || marker == 45,
                  let markerFrame = textSegmentFrames(
                      for: span.range,
                      layoutManager: layoutManager,
                      contentManager: contentManager
                  ).first else { continue }
            let diameter = min(5, max(3, markerFrame.height * 0.2))
            decorations.append(ListBulletDecoration(
                rect: CGRect(
                    x: markerFrame.midX - diameter / 2,
                    y: markerFrame.midY - diameter / 2,
                    width: diameter,
                    height: diameter
                )
            ))
        }
        return decorations
    }

    static func taskCheckboxDecorations(
        text: String,
        result: MarkdownSyntaxResult,
        layoutManager: NSTextLayoutManager,
        snapshot: MarkdownLivePreviewSnapshot,
        visibleRange: NSRange? = nil,
        spanIndices: Range<Int>? = nil
    ) -> [TaskCheckboxDecoration] {
        guard snapshot.mode == .livePreview,
              let contentManager = layoutManager.textContentManager else {
            return []
        }
        let source = text as NSString
        if let storage = contentManager as? NSTextContentStorage,
           storage.textStorage?.length != source.length { return [] }
        let indices = spanIndices ?? result.spans.indices
        return result.spans[indices].compactMap { span in
            guard case let .taskMarker(checked) = span.role,
                  NSMaxRange(span.range) <= source.length,
                  visibleRange.map({ NSIntersectionRange($0, span.range).length > 0 })
                    ?? true,
                  let frame = textSegmentFrames(
                      for: span.range,
                      layoutManager: layoutManager,
                      contentManager: contentManager
                  ).first else { return nil }
            let side = min(22, max(19, frame.height * 0.9))
            return TaskCheckboxDecoration(
                range: span.range,
                rect: CGRect(
                    x: frame.midX - side / 2,
                    y: frame.midY - side / 2,
                    width: side,
                    height: side
                ),
                checked: checked
            )
        }
    }

    static func presentationForDrawing(
        in textStorage: NSTextStorage,
        syntaxCache: MarkdownSyntaxCache,
        snapshot: MarkdownLivePreviewSnapshot
    ) -> MarkdownRenderingPresentation {
        syntaxCache.currentPresentation
            ?? syntaxCache.presentation(in: textStorage, snapshot: snapshot)
    }

    static func taskCheckbox(
        at point: CGPoint,
        in textView: MarkdownTextView
    ) -> TaskCheckboxDecoration? {
        guard textView.isEditable,
              let layoutManager = textView.textLayoutManager
        else { return nil }
#if os(macOS)
        guard let textStorage = textView.textStorage else { return nil }
#else
        let textStorage = textView.textStorage
#endif
        let presentation = presentationForDrawing(
            in: textStorage,
            syntaxCache: textView.markdownSyntaxCache,
            snapshot: MarkdownLivePreview.snapshot(for: textView)
        )
#if os(macOS)
        let source = textView.string
        let origin = textView.textContainerOrigin
#else
        let source = textView.text ?? ""
        let origin = CGPoint(x: textView.textContainerInset.left,
                             y: textView.textContainerInset.top)
#endif
        let containerPoint = CGPoint(x: point.x - origin.x,
                                     y: point.y - origin.y)
        guard let visibleRange = visibleRange(in: layoutManager) else {
            return nil
        }
        let decorations = taskCheckboxDecorations(
            text: source,
            result: presentation.result,
            layoutManager: layoutManager,
            snapshot: MarkdownLivePreview.snapshot(for: textView),
            visibleRange: visibleRange,
            spanIndices: presentation.spanCandidateIndices(
                intersecting: visibleRange
            )
        )
#if os(macOS)
        let targetSide: CGFloat = 31
#else
        let targetSide: CGFloat = 44
#endif
        return taskCheckboxHit(
            at: containerPoint,
            in: decorations,
            minimumTargetSide: targetSide
        )
    }

    static func taskCheckboxHit(
        at point: CGPoint,
        in decorations: [TaskCheckboxDecoration],
        minimumTargetSide: CGFloat
    ) -> TaskCheckboxDecoration? {
        decorations.filter { checkbox in
            let padding = max(
                0, (minimumTargetSide - checkbox.rect.width) / 2
            )
            return checkbox.rect.insetBy(
                dx: -padding, dy: -padding
            ).contains(point)
        }.min { left, right in
            let leftX = left.rect.midX - point.x
            let leftY = left.rect.midY - point.y
            let rightX = right.rect.midX - point.x
            let rightY = right.rect.midY - point.y
            return leftX * leftX + leftY * leftY
                < rightX * rightX + rightY * rightY
        }
    }

    private static func drawTaskCheckboxes(
        _ decorations: [TaskCheckboxDecoration],
        offset: CGPoint,
        dirtyRect: CGRect,
        context: CGContext
    ) {
        for decoration in decorations {
            let rect = decoration.rect.offsetBy(dx: offset.x, dy: offset.y)
            guard rect.intersects(dirtyRect) else { continue }
            let path = CGPath(
                roundedRect: rect.insetBy(dx: 0.75, dy: 0.75),
                cornerWidth: 3, cornerHeight: 3, transform: nil
            )
            context.saveGState()
            context.setLineWidth(1.5)
            context.setStrokeColor(
                (decoration.checked ? PlatformColor.systemBlue : secondaryTextColor)
                    .cgColor
            )
            context.addPath(path)
            context.strokePath()
            if decoration.checked {
                context.setFillColor(PlatformColor.systemBlue.cgColor)
                context.addPath(path)
                context.fillPath()
                context.setStrokeColor(PlatformColor.white.cgColor)
                context.setLineWidth(1.7)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.move(to: CGPoint(x: rect.minX + rect.width * 0.22,
                                         y: rect.midY))
                context.addLine(to: CGPoint(x: rect.minX + rect.width * 0.43,
                                            y: rect.maxY - rect.height * 0.25))
                context.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.2,
                                            y: rect.minY + rect.height * 0.26))
                context.strokePath()
            }
            context.restoreGState()
        }
    }

    private static func drawListBullets(
        _ decorations: [ListBulletDecoration],
        offset: CGPoint,
        dirtyRect: CGRect,
        context: CGContext
    ) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(secondaryTextColor.cgColor)
        for decoration in decorations {
            let rect = decoration.rect.offsetBy(dx: offset.x, dy: offset.y)
            guard rect.intersects(dirtyRect) else { continue }
            context.fillEllipse(in: rect)
        }
    }

    private static func applyLayoutAttributes(
        to textStorage: NSTextStorage,
        text: String,
        result: MarkdownSyntaxResult,
        bodyFont: PlatformFont,
        hiddenRanges: [NSRange],
        transparentRanges: [NSRange],
        livePreview: Bool,
        undoManager: UndoManager?,
        range: NSRange,
        tableLayout: MarkdownTableLayout?
    ) {
        let fullRange = NSRange(location: 0, length: range.length)
        func local(_ source: NSRange) -> NSRange? {
            let intersection = NSIntersectionRange(source, range)
            guard intersection.length > 0 else { return nil }
            return NSRange(location: intersection.location - range.location,
                           length: intersection.length)
        }
        let undoRegistrationWasEnabled =
            undoManager?.isUndoRegistrationEnabled == true
        if undoRegistrationWasEnabled {
            undoManager?.disableUndoRegistration()
        }
        defer {
            if undoRegistrationWasEnabled {
                undoManager?.enableUndoRegistration()
            }
        }

        guard fullRange.length > 0 else { return }
        let desired = NSMutableAttributedString(
            string: (text as NSString).substring(with: range)
        )
        desired.addAttribute(.font, value: bodyFont, range: fullRange)
        desired.addAttribute(
            .foregroundColor,
            value: primaryTextColor,
            range: fullRange
        )
        desired.addAttribute(
            .paragraphStyle,
            value: bodyParagraphStyle(for: bodyFont),
            range: fullRange
        )
        for run in result.fontRuns {
            guard let localRange = local(run.range) else { continue }
            let font = layoutFont(for: run, bodyFont: bodyFont)
            desired.addAttribute(.font, value: font, range: localRange)
            if run.traits.contains(.italic), !hasItalicTrait(font) {
                // The rounded system design has no native italic face.
                desired.addAttribute(.obliqueness, value: 0.18, range: localRange)
            }
        }
        if livePreview {
            let markerFont = PlatformFont.monospacedSystemFont(
                ofSize: bodyFont.pointSize, weight: .regular
            )
            for span in result.spans {
                guard case .taskMarker = span.role,
                      let localRange = local(span.range) else { continue }
                desired.addAttribute(.font, value: markerFont, range: localRange)
            }
        }
        let source = text as NSString
        let taskParagraphs = taskParagraphLocations(
            in: result, source: source, livePreview: livePreview
        )
        for run in result.paragraphRuns {
            guard let localRange = local(run.range) else { continue }
            let style = paragraphStyle(
                for: run,
                text: source,
                bodyFont: bodyFont,
                isTask: taskParagraphs.contains(run.range.location)
            )
            desired.addAttribute(
                .paragraphStyle,
                value: style,
                range: localRange
            )
        }
        for span in result.spans where span.role == .strikethrough {
            guard let localRange = local(span.range) else { continue }
            desired.addAttributes(
                [
                    .strikethroughColor: secondaryTextColor,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                ],
                range: localRange
            )
        }
        let collapsedFont = fontWithSize(
            bodyFont,
            size: MarkdownLivePreview.collapsedFontSize
        )
        for range in hiddenRanges {
            guard let range = local(range) else { continue }
            desired.addAttributes(
                [
                    .font: collapsedFont,
                    .foregroundColor: PlatformColor.clear,
                    .kern: -MarkdownLivePreview.collapsedFontSize,
                ],
                range: range
            )
        }
        for range in transparentRanges {
            guard let range = local(range) else { continue }
            desired.addAttribute(
                .foregroundColor,
                value: PlatformColor.clear,
                range: range
            )
        }
        tableLayout?.apply(to: desired, sourceRange: range)
        #if os(iOS)
        applyLeadingParagraphGaps(
            to: desired, sourceRange: range, source: source,
            result: result, bodyFont: bodyFont,
            taskParagraphs: taskParagraphs, tableLayout: tableLayout
        )
        #endif
        var changes: [AttributeChange] = []
        var layoutAttributeKeys: [NSAttributedString.Key] = [
            .font,
            .paragraphStyle,
            .kern,
            .obliqueness,
            .strikethroughColor,
            .strikethroughStyle,
        ]
        #if os(macOS)
        layoutAttributeKeys.append(.foregroundColor)
        #endif
        for key in layoutAttributeKeys {
            changes.append(contentsOf: changedAttributes(
                key,
                from: desired,
                to: textStorage,
                range: range
            ))
        }
        guard !changes.isEmpty else { return }
        textStorage.beginEditing()
        for change in changes {
            if let value = change.value {
                textStorage.addAttribute(
                    change.key,
                    value: value,
                    range: change.range
                )
            } else {
                textStorage.removeAttribute(change.key, range: change.range)
            }
        }
        textStorage.endEditing()
    }

    private struct AttributeChange {
        let key: NSAttributedString.Key
        let value: Any?
        let range: NSRange
    }

    private static func changedAttributes(
        _ key: NSAttributedString.Key,
        from desired: NSAttributedString,
        to textStorage: NSTextStorage,
        range: NSRange
    ) -> [AttributeChange] {
        var changes: [AttributeChange] = []
        var location = range.location
        let end = NSMaxRange(range)
        while location < end {
            var desiredRange = NSRange()
            var existingRange = NSRange()
            let desiredValue = desired.attribute(
                key,
                at: location - range.location,
                longestEffectiveRange: &desiredRange,
                in: NSRange(location: 0, length: range.length)
            )
            desiredRange.location += range.location
            let existingValue = textStorage.attribute(
                key,
                at: location,
                longestEffectiveRange: &existingRange,
                in: range
            )
            let comparisonEnd = min(
                NSMaxRange(desiredRange),
                NSMaxRange(existingRange)
            )
            guard comparisonEnd > location else { break }
            let comparisonRange = NSRange(
                location: location,
                length: comparisonEnd - location
            )
            if !attributeValuesEqual(existingValue, desiredValue) {
                changes.append(
                    AttributeChange(
                        key: key,
                        value: desiredValue,
                        range: comparisonRange
                    )
                )
            }
            location = comparisonEnd
        }
        return changes
    }

    private static func attributeValuesEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (left as NSObject, right as NSObject):
            return left.isEqual(right)
        default:
            return false
        }
    }

    private static func applyRenderingAttributes(
        to layoutManager: NSTextLayoutManager,
        fragment: NSTextLayoutFragment,
        presentation: MarkdownRenderingPresentation
    ) -> Int {
        guard let contentManager = layoutManager.textContentManager else {
            return 0
        }
        let documentStart = contentManager.documentRange.location
        let fragmentRange = nsRange(
            for: fragment.rangeInElement,
            documentStart: documentStart,
            contentManager: contentManager
        )

        #if os(iOS)
        let baseAttributes: [NSAttributedString.Key: Any] = [.foregroundColor: primaryTextColor]
        #else
        let baseAttributes: [NSAttributedString.Key: Any] = [:]
        #endif
        var appliedCount = 0
        for command in presentation.renderingCommands(in: fragmentRange,
                                                       baseAttributes: baseAttributes) {
            guard let textRange = textRange(for: command.range,
                documentStart: documentStart, contentManager: contentManager) else { continue }
            if command.replacesAttributes {
                layoutManager.setRenderingAttributes(command.attributes, for: textRange)
            } else {
                for (key, value) in command.attributes {
                    layoutManager.addRenderingAttribute(key, value: value, for: textRange)
                }
            }
            appliedCount += 1
        }
        return appliedCount
    }

    @discardableResult
    static func refreshVisibleRenderingAttributes(
        in layoutManager: NSTextLayoutManager?,
        text: String,
        syntaxCache: MarkdownSyntaxCache? = nil,
        presentation suppliedPresentation: MarkdownRenderingPresentation? = nil,
        hiddenRanges: [NSRange] = [],
        invalidatedRange: NSRange? = nil
    ) -> Int {
        guard let layoutManager,
              let contentManager = layoutManager.textContentManager else {
            return 0
        }
        if let invalidatedRange {
            if invalidatedRange.length > 0,
               let range = textRange(
                for: invalidatedRange,
                documentStart: contentManager.documentRange.location,
                contentManager: contentManager
               ) {
                layoutManager.invalidateRenderingAttributes(for: range)
            }
        } else {
            layoutManager.invalidateRenderingAttributes(for: contentManager.documentRange)
        }
        let viewportController = layoutManager.textViewportLayoutController
        viewportController.layoutViewport()
        guard let viewportRange = viewportController.viewportRange else {
            return 0
        }

        let result = suppliedPresentation?.result
            ?? syntaxCache?.result(for: text)
            ?? MarkdownSyntax.parse(text)
        let presentation = suppliedPresentation
            ?? MarkdownRenderingPresentation(
                result: result,
                hiddenRanges: hiddenRanges
            )
        let documentStart = contentManager.documentRange.location
        let viewport = nsRange(
            for: viewportRange,
            documentStart: documentStart,
            contentManager: contentManager
        )
        var appliedCount = 0
        layoutManager.enumerateTextLayoutFragments(
            from: viewportRange.location,
            options: []
        ) { fragment in
            let fragmentRange = nsRange(
                for: fragment.rangeInElement,
                documentStart: documentStart,
                contentManager: contentManager
            )
            guard fragmentRange.location < NSMaxRange(viewport) else {
                return false
            }
            if NSIntersectionRange(fragmentRange, viewport).length > 0 {
                appliedCount += applyRenderingAttributes(
                    to: layoutManager,
                    fragment: fragment,
                    presentation: presentation
                )
            }
            return true
        }
        return appliedCount
    }

    private static func nsRange(
        for textRange: NSTextRange,
        documentStart: any NSTextLocation,
        contentManager: NSTextContentManager
    ) -> NSRange {
        let location = contentManager.offset(
            from: documentStart,
            to: textRange.location
        )
        let end = contentManager.offset(
            from: documentStart,
            to: textRange.endLocation
        )
        return NSRange(location: location, length: max(0, end - location))
    }

    private static func textRange(
        for range: NSRange,
        documentStart: any NSTextLocation,
        contentManager: NSTextContentManager
    ) -> NSTextRange? {
        guard let start = contentManager.location(
            documentStart,
            offsetBy: range.location
        ), let end = contentManager.location(
            start,
            offsetBy: range.length
        ) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    static func blockDecorations(
        text: String,
        layoutManager: NSTextLayoutManager,
        containerWidth: CGFloat,
        lineFragmentPadding: CGFloat = 0,
        visibleRange: NSRange? = nil
    ) -> [BlockDecoration] {
        blockDecorations(
            text: text,
            result: MarkdownSyntax.parse(text),
            layoutManager: layoutManager,
            containerWidth: containerWidth,
            lineFragmentPadding: lineFragmentPadding,
            visibleRange: visibleRange
        )
    }

    private static func blockDecorations(
        text: String,
        result: MarkdownSyntaxResult,
        layoutManager: NSTextLayoutManager,
        containerWidth: CGFloat,
        lineFragmentPadding: CGFloat,
        visibleRange: NSRange?
    ) -> [BlockDecoration] {
        guard containerWidth > 0,
              let contentManager = layoutManager.textContentManager else {
            return []
        }
        let source = text as NSString
        if let contentStorage = contentManager as? NSTextContentStorage,
           let textStorage = contentStorage.textStorage,
           textStorage.length != source.length {
            return []
        }
        let runs = result.paragraphRuns.filter {
            let isDecorated = $0.kind == .blockquote || $0.kind == .codeBlock
            guard isDecorated, let visibleRange else { return isDecorated }
            return NSIntersectionRange($0.range, visibleRange).length > 0
                || NSLocationInRange($0.range.location, visibleRange)
        }.sorted { $0.range.location < $1.range.location }
        let decoratedRuns = runs.compactMap { run -> DecoratedRun? in
            let kind: BlockDecoration.Kind = run.kind == .blockquote
                ? .blockquote
                : .codeBlock
            let left: CGFloat
            var markerColumn: Int?
            switch kind {
            case .codeBlock:
                left = 0
                markerColumn = nil
            case .blockquote:
                guard let marker = result.spans.first(where: {
                    $0.role == .blockquoteMarker
                        && NSLocationInRange($0.range.location, run.range)
                }) else { return nil }
                let markerIsVisible = visibleRange.map {
                    NSIntersectionRange(marker.range, $0).length > 0
                } ?? true
                if markerIsVisible,
                   let markerFrame = textSegmentFrames(
                       for: marker.range,
                       layoutManager: layoutManager,
                       contentManager: contentManager
                   ).first {
                    left = markerFrame.minX
                } else {
                    left = quoteMarkerFallbackX(
                        markerLocation: marker.range.location,
                        paragraph: run,
                        text: source,
                        contentManager: contentManager,
                        lineFragmentPadding: lineFragmentPadding
                    )
                }
                markerColumn = sourceColumn(
                    from: run.range.location,
                    to: marker.range.location,
                    in: source
                )
            }
            return DecoratedRun(
                run: run,
                kind: kind,
                left: left,
                markerColumn: markerColumn
            )
        }
        let groups = blockGroups(from: decoratedRuns)

        return groups.compactMap { group in
            let range = NSRange(
                location: group.runs[0].run.range.location,
                length: NSMaxRange(group.runs[group.runs.count - 1].run.range)
                    - group.runs[0].run.range.location
            )
            let lineFrames = textSegmentFrames(
                for: range,
                layoutManager: layoutManager,
                contentManager: contentManager
            )
            guard let top = lineFrames.map(\.minY).min(),
                  let bottom = lineFrames.map(\.maxY).max(),
                  bottom > top else { return nil }

            let verticalPadding = group.kind == .codeBlock
                ? codeBlockVerticalPadding(from: lineFrames)
                : 0

            return BlockDecoration(
                kind: group.kind,
                rect: CGRect(
                    x: group.left,
                    y: top - verticalPadding,
                    width: max(0, containerWidth - group.left),
                    height: bottom - top + 2 * verticalPadding
                )
            )
        }
    }

    private struct DecoratedRun {
        let run: MarkdownParagraphRun
        let kind: BlockDecoration.Kind
        let left: CGFloat
        let markerColumn: Int?
    }

    private struct BlockGroup {
        let kind: BlockDecoration.Kind
        var left: CGFloat
        let markerColumn: Int?
        var runs: [DecoratedRun]
    }

    private static func blockGroups(
        from runs: [DecoratedRun]
    ) -> [BlockGroup] {
        var groups: [BlockGroup] = []
        for run in runs {
            if let previous = groups.last,
               previous.kind == run.kind,
               previous.markerColumn == run.markerColumn,
               NSMaxRange(previous.runs[previous.runs.count - 1].run.range)
                == run.run.range.location {
                groups[groups.count - 1].runs.append(run)
                groups[groups.count - 1].left = min(previous.left, run.left)
            } else {
                groups.append(
                    BlockGroup(
                        kind: run.kind,
                        left: run.left,
                        markerColumn: run.markerColumn,
                        runs: [run]
                    )
                )
            }
        }
        return groups
    }

    private static func sourceColumn(
        from start: Int,
        to end: Int,
        in text: NSString
    ) -> Int {
        var column = 0
        guard start < end else { return column }
        for location in start..<min(end, text.length) {
            if text.character(at: location) == 9 {
                column = ((column / 4) + 1) * 4
            } else {
                column += 1
            }
        }
        return column
    }

    private static func quoteMarkerFallbackX(
        markerLocation: Int,
        paragraph: MarkdownParagraphRun,
        text: NSString,
        contentManager: NSTextContentManager,
        lineFragmentPadding: CGFloat
    ) -> CGFloat {
        guard let contentStorage = contentManager as? NSTextContentStorage,
              let textStorage = contentStorage.textStorage,
              paragraph.range.location < textStorage.length else {
            return lineFragmentPadding
        }
        let paragraphStyle = textStorage.attribute(
            .paragraphStyle,
            at: paragraph.range.location,
            effectiveRange: nil
        ) as? NSParagraphStyle
        var x = paragraphStyle?.firstLineHeadIndent ?? 0
        let prefixEnd = min(markerLocation, text.length, textStorage.length)
        guard paragraph.range.location < prefixEnd else {
            return lineFragmentPadding + x
        }

        for location in paragraph.range.location..<prefixEnd {
            let font = textStorage.attribute(
                .font,
                at: location,
                effectiveRange: nil
            ) as? PlatformFont ?? editorBodyFont
            if text.character(at: location) == 9 {
                if let tabStop = paragraphStyle?.tabStops.first(where: {
                    $0.location > x
                }) {
                    x = tabStop.location
                    continue
                }
                let interval = paragraphStyle?.defaultTabInterval ?? 0
                let tabWidth = interval > 0 ? interval : spaceWidth(for: font) * 4
                x = ((x / tabWidth).rounded(.down) + 1) * tabWidth
            } else {
                let character = text.substring(
                    with: NSRange(location: location, length: 1)
                ) as NSString
                x += character.size(withAttributes: [.font: font]).width
            }
        }
        return lineFragmentPadding + x
    }

    private static func codeBlockVerticalPadding(
        from lineFrames: [CGRect]
    ) -> CGFloat {
        guard let lineHeight = lineFrames.map(\.height).filter({ $0 > 0 }).min()
        else { return 0 }
        return lineHeight * 0.25
    }

    static func textSegmentFrames(
        for range: NSRange,
        layoutManager: NSTextLayoutManager,
        contentManager: NSTextContentManager
    ) -> [CGRect] {
        let documentStart = contentManager.documentRange.location
        guard let range = textRange(
            for: range,
            documentStart: documentStart,
            contentManager: contentManager
        ) else { return [] }

        var frames: [CGRect] = []
        layoutManager.enumerateTextSegments(
            in: range,
            type: .standard,
            options: [.rangeNotRequired]
        ) { _, frame, _, _ in
            if !frame.isNull, !frame.isEmpty {
                frames.append(frame)
            }
            return true
        }
        return frames
    }

    static func visibleRange(
        in layoutManager: NSTextLayoutManager
    ) -> NSRange? {
        guard let contentManager = layoutManager.textContentManager,
              let viewportRange = layoutManager.textViewportLayoutController
                .viewportRange else { return nil }
        return nsRange(
            for: viewportRange,
            documentStart: contentManager.documentRange.location,
            contentManager: contentManager
        )
    }

    static func renderingAttributes(
        for role: MarkdownStyleRole
    ) -> [NSAttributedString.Key: Any] {
        switch role {
        case .code:
            return [
                .backgroundColor: PlatformColor.secondarySystemFill,
                .foregroundColor: primaryTextColor,
            ]
        case .highlight:
            return [
                .backgroundColor: PlatformColor.systemYellow.withAlphaComponent(
                    0.32
                ),
            ]
        case .strikethrough:
            return [
                .strikethroughColor: secondaryTextColor,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            ]
        case .link:
            return [.foregroundColor: PlatformColor.systemBlue]
        case .listMarker, .taskMarker:
            return [.foregroundColor: secondaryTextColor]
        case .blockquote:
            return [
                .foregroundColor: primaryTextColor,
            ]
        case .blockquoteMarker:
            return [.foregroundColor: tertiaryTextColor]
        case .heading, .strong, .emphasis:
            return [:]
        }
    }

    static func renderingAttributes(
        for span: MarkdownStyleSpan,
        in result: MarkdownSyntaxResult
    ) -> [NSAttributedString.Key: Any] {
        var attributes = renderingAttributes(for: span.role)
        if span.role == .code,
           result.paragraphRuns.contains(where: {
               $0.kind == .codeBlock
                   && NSLocationInRange($0.range.location, span.range)
           }) {
            attributes.removeValue(forKey: .backgroundColor)
        }
        return attributes
    }

    private static func taskParagraphLocations(
        in result: MarkdownSyntaxResult,
        source: NSString,
        livePreview: Bool
    ) -> Set<Int> {
        guard livePreview else { return [] }
        return Set(result.spans.compactMap { span in
            guard case .taskMarker = span.role else { return nil }
            return source.paragraphRange(for: span.range).location
        })
    }

    #if os(iOS)
    private static func paragraphGapLayoutRange(
        _ range: NSRange, in text: String
    ) -> NSRange {
        guard range.length > 0 else { return range }
        let source = text as NSString
        let full = NSRange(location: 0, length: source.length)
        var paragraphs = source.paragraphRange(
            for: NSIntersectionRange(range, full)
        )
        if paragraphs.location > 0 {
            let previous = source.paragraphRange(for: NSRange(
                location: paragraphs.location - 1, length: 0
            ))
            paragraphs = NSUnionRange(previous, paragraphs)
        }
        let end = NSMaxRange(paragraphs)
        if end < source.length {
            let next = source.paragraphRange(
                for: NSRange(location: end, length: 0)
            )
            paragraphs = NSUnionRange(paragraphs, next)
        }
        return paragraphs
    }

    private static func originalParagraphSpacing(
        at position: Int,
        source: NSString,
        result: MarkdownSyntaxResult,
        bodyFont: PlatformFont,
        taskParagraphs: Set<Int>,
        tableLayout: MarkdownTableLayout?
    ) -> CGFloat {
        if let tableLayout,
           tableLayout.rows.contains(where: {
               NSLocationInRange(position, $0.range)
           }) || tableLayout.delimiters.contains(where: {
               NSLocationInRange(position, $0)
           }) {
            return 0
        }
        guard let run = result.paragraphRuns.last(where: {
            NSLocationInRange(position, $0.range)
        }) else { return bodyParagraphStyle(for: bodyFont).paragraphSpacing }
        return paragraphStyle(
            for: run, text: source, bodyFont: bodyFont,
            isTask: taskParagraphs.contains(run.range.location)
        ).paragraphSpacing
    }

    private static func applyLeadingParagraphGaps(
        to desired: NSMutableAttributedString,
        sourceRange: NSRange,
        source: NSString,
        result: MarkdownSyntaxResult,
        bodyFont: PlatformFont,
        taskParagraphs: Set<Int>,
        tableLayout: MarkdownTableLayout?
    ) {
        var previousSpacing: CGFloat = 0
        if sourceRange.location > 0 {
            let previous = source.paragraphRange(for: NSRange(
                location: sourceRange.location - 1, length: 0
            ))
            // Read the original syntax, not an already transformed neighbor.
            // Otherwise repeated incremental refreshes accumulate the gap.
            previousSpacing = originalParagraphSpacing(
                at: previous.location, source: source, result: result,
                bodyFont: bodyFont, taskParagraphs: taskParagraphs,
                tableLayout: tableLayout
            )
        }
        var cursor = sourceRange.location
        while cursor < NSMaxRange(sourceRange) {
            let paragraph = source.paragraphRange(for: NSRange(
                location: cursor, length: 0
            ))
            let local = NSRange(
                location: paragraph.location - sourceRange.location,
                length: paragraph.length
            )
            guard let original = desired.attribute(
                .paragraphStyle, at: local.location, effectiveRange: nil
            ) as? NSParagraphStyle,
                  let style = original.mutableCopy()
                    as? NSMutableParagraphStyle else { return }
            let trailingSpacing = original.paragraphSpacing
            // UIKit's pre-selection layout can re-anchor a long document
            // when fragments have trailing paragraph gaps. Apple's gap
            // contract is previous.after + current.before, so assign the
            // same distance to the following paragraph instead.
            style.paragraphSpacingBefore += previousSpacing
            if paragraph.location == 0,
               let run = result.paragraphRuns.last(where: {
                   NSLocationInRange(paragraph.location, $0.range)
               }), case let .heading(level) = run.kind {
                // A concealed heading marker can otherwise make native
                // pre-selection layout add the first heading's line height
                // to already visible fragment positions. Keep its natural
                // minimum while allowing taller fallback glyphs to grow.
                style.minimumLineHeight = headingFont(
                    level: level, bodyFont: bodyFont
                ).lineHeight
            }
            // UIKit's virtual empty EOF does not apply a leading gap until
            // its first glyph exists. Keep the last stored trailing gap;
            // it transfers to the next paragraph when text is inserted.
            if NSMaxRange(paragraph) < source.length {
                style.paragraphSpacing = 0
            }
            desired.addAttribute(.paragraphStyle, value: style, range: local)
            previousSpacing = trailingSpacing
            cursor = NSMaxRange(paragraph)
        }
    }
    #endif

    private static func bodyParagraphStyle(
        for bodyFont: PlatformFont
    ) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = max(1, bodyFont.pointSize * 0.12)
        style.paragraphSpacing = max(6, bodyFont.pointSize * 0.42)
        style.tabStops = []
        style.defaultTabInterval = spaceWidth(for: bodyFont) * 4
        return style
    }

    private static func paragraphStyle(
        for run: MarkdownParagraphRun,
        text: NSString,
        bodyFont: PlatformFont,
        isTask: Bool
    ) -> NSParagraphStyle {
        let style = bodyParagraphStyle(for: bodyFont)
        let em = bodyFont.pointSize
        switch run.kind {
        case let .heading(level):
            style.paragraphSpacingBefore = level <= 2 ? em * 0.7 : em * 0.45
            style.paragraphSpacing = level <= 2 ? em * 0.35 : em * 0.25
            style.lineSpacing = 0
        case .list:
            style.headIndent = prefixWidth(
                for: run,
                in: text,
                font: bodyFont
            )
            style.firstLineHeadIndent = 0
            style.paragraphSpacing = em * (isTask ? 0.55 : 0.2)
        case .indented:
            style.headIndent = prefixWidth(
                for: run,
                in: text,
                font: bodyFont
            )
            style.firstLineHeadIndent = 0
        case .blockquote:
            style.headIndent = prefixWidth(
                for: run,
                in: text,
                font: bodyFont
            )
            style.firstLineHeadIndent = 0
            style.paragraphSpacing = em * 0.3
        case .codeBlock:
            style.firstLineHeadIndent = em * 0.65
            style.headIndent = em * 0.65
            style.tailIndent = -em * 0.65
            style.paragraphSpacingBefore = em * 0.3
            style.paragraphSpacing = em * 0.3
            style.lineSpacing = em * 0.08
        }
        return style
    }

    private static func spaceWidth(for font: PlatformFont) -> CGFloat {
        (" " as NSString).size(withAttributes: [.font: font]).width
    }

    private static func prefixWidth(
        for run: MarkdownParagraphRun,
        in text: NSString,
        font: PlatformFont
    ) -> CGFloat {
        let tabWidth = spaceWidth(for: font) * 4
        var width: CGFloat = 0
        let end = NSMaxRange(run.contentPrefixRange)
        for location in run.contentPrefixRange.location..<end {
            if text.character(at: location) == 9 {
                width = ((width / tabWidth).rounded(.down) + 1) * tabWidth
            } else {
                let character = text.substring(
                    with: NSRange(location: location, length: 1)
                ) as NSString
                width += character.size(withAttributes: [.font: font]).width
            }
        }
        return width
    }

    static func layoutFont(
        for run: MarkdownFontRun,
        bodyFont: PlatformFont
    ) -> PlatformFont {
        styledFont(
            traits: run.traits, headingLevel: run.headingLevel,
            bodyFont: bodyFont
        )
    }

    static func headingFont(
        level: Int,
        bodyFont: PlatformFont
    ) -> PlatformFont {
        styledFont(traits: .bold, headingLevel: level, bodyFont: bodyFont)
    }

    private static func styledFont(
        traits: MarkdownFontTraits,
        headingLevel: Int?,
        bodyFont: PlatformFont
    ) -> PlatformFont {
        let size = bodyFont.pointSize * headingScale(for: headingLevel)
        var font = traits.contains(.monospaced)
            ? codeFont(pointSize: size)
            : fontWithSize(bodyFont, size: size)
        if traits.contains(.bold) {
            font = strongFont(font)
        }
        if traits.contains(.italic) {
            font = emphasisFont(font)
        }
        return font
    }

    private static func headingScale(for level: Int?) -> CGFloat {
        switch level {
        case 1: 2
        case 2: 1.65
        case 3: 1.4
        case 4: 1.25
        case 5: 1.15
        case 6: 1.08
        default: 1
        }
    }

#if os(macOS)
    static func bodyFont(
        for family: EditorFontFamily,
        pointSize: CGFloat
    ) -> NSFont {
        let base = NSFont.systemFont(ofSize: pointSize)
        guard family != .system,
              let descriptor = base.fontDescriptor.withDesign(
                  systemDesign(for: family)
              ),
              let font = NSFont(descriptor: descriptor, size: pointSize)
        else { return base }
        return font
    }

    private static func strongFont(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    private static func emphasisFont(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }

    private static func hasItalicTrait(_ font: NSFont) -> Bool {
        NSFontManager.shared.traits(of: font).contains(.italicFontMask)
    }

    private static func fontWithSize(_ font: NSFont, size: CGFloat) -> NSFont {
        NSFont(descriptor: font.fontDescriptor, size: size) ?? font
    }

    static func codeFont(pointSize: CGFloat) -> NSFont {
        .monospacedSystemFont(ofSize: pointSize, weight: .regular)
    }

    private static var primaryTextColor: NSColor { .textColor }
    private static var secondaryTextColor: NSColor { .secondaryLabelColor }
    private static var tertiaryTextColor: NSColor { .tertiaryLabelColor }
#else
    static func bodyFont(
        for family: EditorFontFamily,
        pointSize: CGFloat
    ) -> UIFont {
        let base = UIFont.systemFont(ofSize: pointSize)
        let designedFont: UIFont
        if family != .system,
           let descriptor = base.fontDescriptor.withDesign(
               systemDesign(for: family)
           ) {
            designedFont = UIFont(descriptor: descriptor, size: pointSize)
        } else {
            designedFont = base
        }
        return UIFontMetrics(forTextStyle: .body).scaledFont(
            for: designedFont
        )
    }

    private static func strongFont(_ font: UIFont) -> UIFont {
        fontAddingTrait(.traitBold, to: font)
    }

    private static func emphasisFont(_ font: UIFont) -> UIFont {
        fontAddingTrait(.traitItalic, to: font)
    }

    private static func hasItalicTrait(_ font: UIFont) -> Bool {
        font.fontDescriptor.symbolicTraits.contains(.traitItalic)
    }

    private static func fontAddingTrait(
        _ trait: UIFontDescriptor.SymbolicTraits,
        to value: UIFont
    ) -> UIFont {
        let traits = value.fontDescriptor.symbolicTraits.union(trait)
        guard let descriptor = value.fontDescriptor.withSymbolicTraits(traits)
        else { return value }
        return UIFont(descriptor: descriptor, size: value.pointSize)
    }

    private static func fontWithSize(_ font: UIFont, size: CGFloat) -> UIFont {
        UIFont(descriptor: font.fontDescriptor, size: size)
    }

    static func codeFont(pointSize: CGFloat) -> UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .monospacedSystemFont(ofSize: pointSize, weight: .regular)
        )
    }

    private static var primaryTextColor: UIColor { .label }
    private static var secondaryTextColor: UIColor { .secondaryLabel }
    private static var tertiaryTextColor: UIColor { .tertiaryLabel }
#endif

    private static func systemDesign(
        for family: EditorFontFamily
    ) -> PlatformFontDescriptor.SystemDesign {
        switch family {
        case .system: .default
        case .serif: .serif
        case .rounded: .rounded
        case .monospaced: .monospaced
        }
    }
}

struct MarkdownDecorationRun {
    let paragraph: MarkdownParagraphRun
    let markerRange: NSRange?
}

struct MarkdownDecorationGroup {
    let kind: MarkdownPresentation.BlockDecoration.Kind
    let markerColumn: Int?
    var runs: [MarkdownDecorationRun]

    var range: NSRange {
        guard let first = runs.first, let last = runs.last else {
            return NSRange(location: 0, length: 0)
        }
        return NSRange(
            location: first.paragraph.range.location,
            length: NSMaxRange(last.paragraph.range)
                - first.paragraph.range.location
        )
    }

    func runIndices(intersecting target: NSRange) -> [Int] {
        var low = runs.startIndex
        var high = runs.endIndex
        while low < high {
            let middle = low + (high - low) / 2
            if NSMaxRange(runs[middle].paragraph.range) <= target.location {
                low = middle + 1
            } else {
                high = middle
            }
        }
        var result: [Int] = []
        var index = low
        while index < runs.endIndex,
              runs[index].paragraph.range.location < NSMaxRange(target) {
            let runRange = runs[index].paragraph.range
            if NSIntersectionRange(runRange, target).length > 0
                || NSLocationInRange(runRange.location, target) {
                result.append(index)
            }
            index += 1
        }
        return result
    }
}

struct MarkdownDecorationPlan {
    let groups: [MarkdownDecorationGroup]

    func groups(intersecting target: NSRange) -> ArraySlice<MarkdownDecorationGroup> {
        var low = groups.startIndex
        var high = groups.endIndex
        while low < high {
            let middle = low + (high - low) / 2
            if NSMaxRange(groups[middle].range) <= target.location {
                low = middle + 1
            } else {
                high = middle
            }
        }
        var end = low
        while end < groups.endIndex,
              groups[end].range.location < NSMaxRange(target) {
            end += 1
        }
        return groups[low..<end]
    }
}

struct MarkdownRenderingPresentation {
    struct RenderingCommand {
        var range: NSRange
        let replacesAttributes: Bool
        let attributes: [NSAttributedString.Key: Any]
    }

    /// Sweep only the indexed spans intersecting this fragment. Later setters
    /// replace earlier dictionaries; untouched ranges retain add-only behavior.
    func renderingCommands(in target: NSRange,
                           baseAttributes: [NSAttributedString.Key: Any]) -> [RenderingCommand] {
        guard target.length > 0 else { return [] }
        struct Event {
            let offset: Int
            let index: Int
            let begins: Bool
        }
        var events: [Event] = []
        var setters: [[NSAttributedString.Key: Any]] = []
        func append(_ range: NSRange, attributes: [NSAttributedString.Key: Any]) {
            let clipped = NSIntersectionRange(range, target)
            guard clipped.length > 0 else { return }
            let index = setters.count
            setters.append(attributes)
            events.append(Event(offset: clipped.location, index: index, begins: true))
            events.append(Event(offset: NSMaxRange(clipped), index: index, begins: false))
        }
        forEachRenderingSpan(intersecting: target) { span, attributes in
            append(span.range, attributes: attributes)
        }
        forEachHiddenRange(intersecting: target) {
            append($0, attributes: hiddenRenderingAttributes)
        }
        events.sort { $0.offset < $1.offset }
        var active = Array(repeating: false, count: setters.count)
        var heap: [Int] = []
        func insert(_ index: Int) {
            heap.append(index)
            var child = heap.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard heap[parent] < heap[child] else { break }
                heap.swapAt(parent, child)
                child = parent
            }
        }
        func winner() -> Int? {
            while let first = heap.first, !active[first] {
                let last = heap.removeLast()
                if heap.isEmpty { continue }
                heap[0] = last
                var parent = 0
                while 2 * parent + 1 < heap.count {
                    var child = 2 * parent + 1
                    if child + 1 < heap.count, heap[child + 1] > heap[child] { child += 1 }
                    guard heap[parent] < heap[child] else { break }
                    heap.swapAt(parent, child)
                    parent = child
                }
            }
            return heap.first
        }
        var commands: [RenderingCommand] = []
        func emit(from start: Int, to end: Int) {
            guard end > start else { return }
            let index = winner()
            let attributes = index.map { setters[$0] } ?? baseAttributes
            guard !attributes.isEmpty else { return }
            let replaces = index != nil
            if let previous = commands.last,
               NSMaxRange(previous.range) == start,
               previous.replacesAttributes == replaces,
               previous.attributes.count == attributes.count,
               attributes.allSatisfy({ key, value in
                   guard let lhs = value as? NSObject,
                         let rhs = previous.attributes[key] as? NSObject else { return false }
                   return lhs.isEqual(rhs)
               }) {
                commands[commands.count - 1].range.length += end - start
            } else {
                commands.append(RenderingCommand(range: NSRange(location: start, length: end - start),
                    replacesAttributes: replaces, attributes: attributes))
            }
        }
        var cursor = target.location
        var eventIndex = 0
        while eventIndex < events.count {
            let offset = events[eventIndex].offset
            emit(from: cursor, to: offset)
            while eventIndex < events.count, events[eventIndex].offset == offset {
                let event = events[eventIndex]
                active[event.index] = event.begins
                if event.begins { insert(event.index) }
                eventIndex += 1
            }
            cursor = offset
        }
        emit(from: cursor, to: NSMaxRange(target))
        return commands
    }

    let result: MarkdownSyntaxResult
    let previewRanges: MarkdownLivePreviewRanges
    let hiddenRanges: [NSRange]
    let hiddenRenderingAttributes: [NSAttributedString.Key: Any] = [
        .foregroundColor: PlatformColor.clear,
    ]
    private let hiddenPrefixMaximumEnds: [Int]
    private let renderingIndex: SyntaxIndex

    /// Palette values remain dynamic platform colors, never resolved CGColors.
    /// Only spans that paint appearance participate in the rendering lookup.
    fileprivate final class SyntaxIndex {
        let spanRanges: [NSRange]
        let spanPrefixMaximumEnds: [Int]
        let spanIndices: [Int]
        let ranges: [NSRange]
        let prefixMaximumEnds: [Int]
        let codeBlockStarts: [Int]
        let attributes: [[NSAttributedString.Key: Any]]

        init(result: MarkdownSyntaxResult) {
            spanRanges = result.spans.map(\.range)
            spanPrefixMaximumEnds = MarkdownRenderingPresentation.prefixMaximumEnds(spanRanges)
            spanIndices = result.spans.indices.filter {
                Self.attributeIndex(for: result.spans[$0].role) != nil
            }
            ranges = spanIndices.map { result.spans[$0].range }
            prefixMaximumEnds = MarkdownRenderingPresentation.prefixMaximumEnds(ranges)
            // Full and incremental parsers keep code-block paragraphs in source
            // order. Build once, instead of scanning all paragraphs per glyph.
            codeBlockStarts = result.paragraphRuns.compactMap {
                $0.kind == .codeBlock ? $0.range.location : nil
            }
            var fenced = MarkdownPresentation.renderingAttributes(for: .code)
            fenced.removeValue(forKey: .backgroundColor)
            attributes = [
                MarkdownPresentation.renderingAttributes(for: .code), fenced,
                MarkdownPresentation.renderingAttributes(for: .highlight),
                MarkdownPresentation.renderingAttributes(for: .strikethrough),
                MarkdownPresentation.renderingAttributes(for: .link),
                MarkdownPresentation.renderingAttributes(for: .listMarker),
                MarkdownPresentation.renderingAttributes(for: .blockquote),
                MarkdownPresentation.renderingAttributes(for: .blockquoteMarker),
            ]
        }

        static func attributeIndex(for role: MarkdownStyleRole) -> Int? {
            switch role {
            case .code: 0
            case .highlight: 2
            case .strikethrough: 3
            case .link: 4
            case .listMarker, .taskMarker: 5
            case .blockquote: 6
            case .blockquoteMarker: 7
            case .heading, .strong, .emphasis: nil
            }
        }

        func attributes(for span: MarkdownStyleSpan) -> [NSAttributedString.Key: Any] {
            guard var index = Self.attributeIndex(for: span.role) else { return [:] }
            if span.role == .code {
                var low = 0
                var high = codeBlockStarts.count
                while low < high {
                    let middle = low + (high - low) / 2
                    if codeBlockStarts[middle] < span.range.location {
                        low = middle + 1
                    } else {
                        high = middle
                    }
                }
                if low < codeBlockStarts.count,
                   NSLocationInRange(codeBlockStarts[low], span.range) {
                    index = 1
                }
            }
            return attributes[index]
        }
    }

    init(
        result: MarkdownSyntaxResult,
        previewRanges: MarkdownLivePreviewRanges
    ) {
        self.init(result: result, previewRanges: previewRanges,
                  syntaxIndex: SyntaxIndex(result: result))
    }

    fileprivate init(
        result: MarkdownSyntaxResult,
        previewRanges: MarkdownLivePreviewRanges,
        syntaxIndex: SyntaxIndex
    ) {
        self.result = result
        self.previewRanges = previewRanges
        hiddenRanges = (
            previewRanges.collapsed + previewRanges.transparent
        ).sorted { left, right in
            if left.location == right.location {
                return left.length > right.length
            }
            return left.location < right.location
        }
        hiddenPrefixMaximumEnds = Self.prefixMaximumEnds(hiddenRanges)
        renderingIndex = syntaxIndex
    }

    init(result: MarkdownSyntaxResult, hiddenRanges: [NSRange]) {
        self.result = result
        previewRanges = MarkdownLivePreviewRanges(
            collapsed: hiddenRanges,
            transparent: []
        )
        self.hiddenRanges = hiddenRanges.sorted { left, right in
            if left.location == right.location {
                return left.length > right.length
            }
            return left.location < right.location
        }
        hiddenPrefixMaximumEnds = Self.prefixMaximumEnds(self.hiddenRanges)
        renderingIndex = SyntaxIndex(result: result)
    }

    func forEachRenderingSpan(
        intersecting target: NSRange,
        _ body: (MarkdownStyleSpan, [NSAttributedString.Key: Any]) -> Void
    ) {
        for index in candidateIndices(
            ranges: renderingIndex.ranges,
            prefixMaximumEnds: renderingIndex.prefixMaximumEnds,
            target: target
        ) {
            let span = result.spans[renderingIndex.spanIndices[index]]
            if NSIntersectionRange(span.range, target).length > 0 {
                body(span, renderingIndex.attributes(for: span))
            }
        }
    }

    func forEachSpan(
        intersecting target: NSRange,
        _ body: (MarkdownStyleSpan) -> Void
    ) {
        for index in candidateIndices(
            ranges: renderingIndex.spanRanges,
            prefixMaximumEnds: renderingIndex.spanPrefixMaximumEnds,
            target: target
        ) {
            let span = result.spans[index]
            if NSIntersectionRange(span.range, target).length > 0 {
                body(span)
            }
        }
    }

    func spanCandidateIndices(intersecting target: NSRange) -> Range<Int> {
        candidateIndices(
            ranges: renderingIndex.spanRanges,
            prefixMaximumEnds: renderingIndex.spanPrefixMaximumEnds,
            target: target
        )
    }

    func forEachHiddenRange(
        intersecting target: NSRange,
        _ body: (NSRange) -> Void
    ) {
        for index in candidateIndices(
            ranges: hiddenRanges,
            prefixMaximumEnds: hiddenPrefixMaximumEnds,
            target: target
        ) {
            let range = hiddenRanges[index]
            if NSIntersectionRange(range, target).length > 0 {
                body(range)
            }
        }
    }

    private func candidateIndices(
        ranges: [NSRange],
        prefixMaximumEnds: [Int],
        target: NSRange
    ) -> Range<Int> {
        guard !ranges.isEmpty, target.length > 0 else { return 0..<0 }
        let targetEnd = NSMaxRange(target)
        var low = 0
        var high = ranges.count
        while low < high {
            let middle = low + (high - low) / 2
            if ranges[middle].location < targetEnd {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let upperBound = low
        low = 0
        high = upperBound
        while low < high {
            let middle = low + (high - low) / 2
            if prefixMaximumEnds[middle] <= target.location {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low..<upperBound
    }

    private static func prefixMaximumEnds(_ ranges: [NSRange]) -> [Int] {
        var maximumEnd = 0
        return ranges.map { range in
            maximumEnd = max(maximumEnd, NSMaxRange(range))
            return maximumEnd
        }
    }
}

final class MarkdownSyntaxCache: NSObject {
    private(set) var tableLayout: MarkdownTableLayout?
    private(set) var tableHorizontalOffsets: [NSRange: CGFloat] = [:]

    @discardableResult
    func setTableHorizontalOffset(_ offset: CGFloat, for range: NSRange) -> Bool {
        guard offset.isFinite, let layout = tableLayout,
              let contentWidth = layout.contentWidth(for: range) else { return false }
        let clamped = min(max(0, offset), max(0, contentWidth - layout.width))
        guard tableHorizontalOffsets[range, default: 0] != clamped else { return false }
        tableHorizontalOffsets[range] = clamped
        return true
    }

    private var tableTexts: [String] = []
    private var parsedTables: [MarkdownTable] = []
    private var tableHiddenRanges: [NSRange] = []
    private var tableActiveCell: MarkdownTableCellEditing.Target?
    private var tableFont: PlatformFont?
    private var tableWidth: CGFloat = 0
    var tableRefresh: (() -> Void)?
    private var tableRefreshScheduled = false

    func prepareTables(
        text: String, presentation: MarkdownRenderingPresentation,
        bodyFont: PlatformFont, width: CGFloat,
        activeCell: MarkdownTableCellEditing.Target? = nil,
        activeColumnWidths: [CGFloat]? = nil
    ) -> NSRange? {
        guard !presentation.result.tables.isEmpty || tableLayout != nil else {
            return nil
        }
        let hidden = presentation.result.tables.compactMap { table in
            presentation.previewRanges.collapsed.contains {
                $0.location <= table.range.location
                    && NSMaxRange($0) >= NSMaxRange(table.range)
            } ? table.range : nil
        }
        let source = text as NSString
        let tables = presentation.result.tables
        let texts = tables.map { source.substring(with: $0.range) }
        let sameText = texts.count == tableTexts.count
            && zip(texts, tableTexts).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
        let geometryChanged = tableWidth != width || tableFont?.isEqual(bodyFont) != true
        guard geometryChanged || tableHiddenRanges != hidden
            || parsedTables != tables || !sameText || tableActiveCell != activeCell else { return nil }
        var ranges: [NSRange] = []
        if tableActiveCell != activeCell {
            if let old = tableActiveCell { ranges.append(old.tableRange) }
            if let activeCell { ranges.append(activeCell.tableRange) }
        }
        tableActiveCell = activeCell
        for (index, table) in parsedTables.enumerated() {
            if geometryChanged || index >= tables.count || table != tables[index]
                || !tableTexts[index].utf8.elementsEqual(texts[index].utf8)
                || tableHiddenRanges.contains(table.range) != hidden.contains(table.range) {
                ranges.append(table.range)
            }
        }
        for (index, table) in tables.enumerated() {
            if geometryChanged || index >= parsedTables.count || table != parsedTables[index]
                || !texts[index].utf8.elementsEqual(tableTexts[index].utf8)
                || tableHiddenRanges.contains(table.range) != hidden.contains(table.range) {
                ranges.append(table.range)
            }
        }
        var retainedOffsets: [NSRange: CGFloat] = [:]
        for (index, table) in tables.enumerated() {
            if index < parsedTables.count,
               tableTexts[index].utf8.elementsEqual(texts[index].utf8) {
                retainedOffsets[table.range] = tableHorizontalOffsets[
                    parsedTables[index].range, default: 0
                ]
            }
        }
        parsedTables = tables
        tableTexts = texts
        tableWidth = width
        tableFont = bodyFont
        tableHiddenRanges = hidden
        tableLayout = presentation.result.tables.isEmpty ? nil : MarkdownTableLayout.make(
            text: text, result: presentation.result,
            hiddenRanges: tableHiddenRanges, bodyFont: bodyFont, width: width,
            activeCell: activeCell, activeColumnWidths: activeColumnWidths
        )
        tableHorizontalOffsets = retainedOffsets
        // A wider viewport can make the previous offset exceed the new limit.
        for (range, offset) in retainedOffsets {
            _ = setTableHorizontalOffset(offset, for: range)
        }
        guard let first = ranges.first else { return nil }
        let affected = ranges.dropFirst().reduce(first, NSUnionRange)
        return NSIntersectionRange(affected, NSRange(location: 0, length: text.utf16.count))
    }

    func refreshTablesAfterResize(width: CGFloat) {
        guard tableLayout != nil, abs(tableWidth - width) > 0.5,
              !isApplyingLayoutAttributes, !tableRefreshScheduled else { return }
        tableRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tableRefreshScheduled = false
            self.tableRefresh?()
        }
    }

    private struct GroupGeometryKey: Hashable {
        let location: Int
        let length: Int
        let fontSize: CGFloat
        let lineFragmentPadding: CGFloat
    }

    private var cachedText: String?
    private var storageSnapshot: String?
    private var snapshotRevision: UInt64?
    private var parsedStorageRevision: UInt64?
    private(set) var snapshotCount = 0
    private var cachedResult: MarkdownSyntaxResult?
    private var cachedPreviewSnapshot: MarkdownLivePreviewSnapshot?
    private var cachedPreviewRanges: MarkdownLivePreviewRanges?
    private var cachedRenderingPresentation: MarkdownRenderingPresentation?
    // Installing syntax, rather than selection equality or a whole-result
    // comparison, owns this editor-local immutable index's lifetime.
    private var renderingSyntaxIndex: MarkdownRenderingPresentation.SyntaxIndex?
    private(set) var renderingSyntaxIndexBuildCount = 0
    private weak var observedTextStorage: NSTextStorage?
    private var presentationIsCurrent = false
    private var cachedDecorationPlan: MarkdownDecorationPlan?
    private var cachedGroupLefts: [GroupGeometryKey: CGFloat] = [:]
    private(set) var parseCount = 0
    private(set) var incrementalParseCount = 0
    private(set) var fullTextComparisonCount = 0
    private struct CharacterEdit {
        let range: NSRange
        let delta: Int
    }
    var isApplyingLayoutAttributes = false
    private var characterEdit: CharacterEdit?
    // Toolbar and presentation preparation may consume characterEdit before
    // the model commit. Native edit intent survives until acknowledgement.
    private var nativeCharacterEdit: CharacterEdit?
    private var processingNativeCharacterEdit: CharacterEdit?

    func nativeTextChange(in storage: NSTextStorage) -> NoteEditorTextChange? {
        guard observedTextStorage === storage, let edit = nativeCharacterEdit else { return nil }
        let oldLength = edit.range.length - edit.delta
        guard oldLength >= 0, edit.range.location >= 0,
              NSMaxRange(edit.range) <= storage.length,
              oldLength == 0 || edit.range.length == 0 else { return nil }
        // Pure insertions/deletions have one unambiguous native intent. Mixed
        // replacements retain the existing whole-text diff and merge path.
        return NoteEditorTextChange(
            range: NSRange(location: edit.range.location, length: oldLength),
            replacement: (textSnapshot(in: storage) as NSString).substring(with: edit.range)
        )
    }

    func acknowledgeNativeText() {
        nativeCharacterEdit = nil
        processingNativeCharacterEdit = nil
    }
    private var cachedCharacterRevision: UInt64 = 0
    // nil means that the complete layout must be refreshed.
    private var dirtyLayoutRange: NSRange?
    private var appliedPreviewRanges: MarkdownLivePreviewRanges?
    private(set) var appliedBodyFont: PlatformFont?
    private(set) var lastLayoutRange = NSRange(location: 0, length: 0)

    func recordAppliedLayoutRange(_ range: NSRange) {
        lastLayoutRange = range
    }

    func layoutRange(
        for presentation: MarkdownRenderingPresentation,
        text: String,
        bodyFont: PlatformFont
    ) -> NSRange {
        let source = text as NSString
        let full = NSRange(location: 0, length: source.length)
        var range = full
        if let dirtyLayoutRange, let old = appliedPreviewRanges,
           appliedBodyFont?.isEqual(bodyFont) == true {
            var affected = dirtyLayoutRange
            // Only concealment that changed needs updating on caret movement.
            for (before, after) in [
                (old.collapsed, presentation.previewRanges.collapsed),
                (old.transparent, presentation.previewRanges.transparent),
            ] {
                for changed in Set(before).symmetricDifference(Set(after)) {
                    affected = affected.length == 0 ? changed
                        : NSUnionRange(affected, changed)
                }
            }
            range = affected.length == 0 ? affected
                : source.paragraphRange(for: NSIntersectionRange(affected, full))
        }
        appliedPreviewRanges = presentation.previewRanges
        appliedBodyFont = bodyFont
        dirtyLayoutRange = NSRange(location: 0, length: 0)
        lastLayoutRange = range
        return range
    }

    private func prepareIncrementally(for text: String) -> Bool {
        guard let edit = characterEdit,
              parsedStorageRevision == cachedCharacterRevision,
              cachedCharacterRevision != characterRevision,
              let cachedText, let cachedResult,
              let update = MarkdownSyntax.incrementallyParse(
                text, previousText: cachedText, previousResult: cachedResult,
                editedRange: edit.range, changeInLength: edit.delta
              ) else { return false }
        let oldPreview = appliedPreviewRanges
        let oldDirty = dirtyLayoutRange
        install(update.result, for: text)
        incrementalParseCount += 1
        // Native text storage already shifts the attributes after an edit.
        // Shift the matching concealment metadata before comparing it again.
        let oldLine = NSRange(
            location: update.invalidatedRange.location,
            length: update.invalidatedRange.length - edit.delta
        )
        func shifted(_ ranges: [NSRange]) -> [NSRange] {
            ranges.compactMap { range in
                // The dirty line will reset all its attributes, including
                // markers removed or resized by the edit.
                if NSIntersectionRange(range, oldLine).length > 0 { return nil }
                if range.location >= NSMaxRange(oldLine) {
                    return NSRange(location: range.location + edit.delta,
                                   length: range.length)
                }
                return range
            }
        }
        if let oldPreview, let oldDirty, oldDirty.length == 0 {
            appliedPreviewRanges = MarkdownLivePreviewRanges(
                collapsed: shifted(oldPreview.collapsed),
                transparent: shifted(oldPreview.transparent)
            )
            dirtyLayoutRange = update.invalidatedRange
            #if os(iOS)
            if update.invalidatedRange.length == 0,
               update.invalidatedRange.location == (text as NSString).length,
               !text.isEmpty {
                // Removing the last paragraph transfers its leading gap
                // back to the preceding stored paragraph. A zero-length
                // parse invalidation would otherwise leave its gap stale.
                dirtyLayoutRange = (text as NSString).paragraphRange(
                    for: NSRange(location: (text as NSString).length - 1,
                                 length: 0)
                )
            }
            #endif
        }
        return true
    }
    private var characterRevision: UInt64 = 0
    /// Native text storage notifications identify changes without scanning text.
    /// The immutable snapshot is shared by the commit and presentation paths.
    func textSnapshot(in textStorage: NSTextStorage) -> String {
        observeCharacterEdits(in: textStorage)
        if snapshotRevision == characterRevision, let storageSnapshot {
            return storageSnapshot
        }
        var text = textStorage.string
        text.makeContiguousUTF8()
        storageSnapshot = text
        snapshotRevision = characterRevision
        snapshotCount += 1
        return text
    }

    @discardableResult
    func prepare(in textStorage: NSTextStorage) -> String {
        let text = textSnapshot(in: textStorage)
        if parsedStorageRevision != characterRevision || cachedResult == nil {
            _ = updateResult(for: text)
            parsedStorageRevision = characterRevision
        }
        return text
    }

    /// The observed storage revision already identifies this prepared result.
    /// Native consumers must not recheck an unrelated string's contents.
    func preparedSyntax(in textStorage: NSTextStorage) -> MarkdownSyntaxResult {
        _ = prepare(in: textStorage)
        return cachedResult!
    }

    // Arbitrary strings have no native revision identity. Keep exact equality
    // here, including for callers that reuse a cache with unrelated text.
    func result(for text: String) -> MarkdownSyntaxResult {
        if let cachedText {
            fullTextComparisonCount += 1
            if cachedText.utf8.elementsEqual(text.utf8), let cachedResult {
                return cachedResult
            }
        }
        // Only the observed storage path can apply its pending edit range.
        let result = MarkdownSyntax.parse(text)
        parseCount += 1
        install(result, for: text)
        return result
    }

    private func updateResult(for text: String) -> MarkdownSyntaxResult {
        if prepareIncrementally(for: text), let cachedResult {
            return cachedResult
        }
        let result = MarkdownSyntax.parse(text)
        parseCount += 1
        install(result, for: text)
        return result
    }

    private func install(_ result: MarkdownSyntaxResult, for text: String) {
        parsedStorageRevision = nil
        cachedText = text
        cachedResult = result
        cachedCharacterRevision = characterRevision
        characterEdit = nil
        dirtyLayoutRange = nil
        cachedPreviewSnapshot = nil
        cachedPreviewRanges = nil
        cachedRenderingPresentation = nil
        renderingSyntaxIndex = nil
        presentationIsCurrent = false
        cachedDecorationPlan = nil
        cachedGroupLefts.removeAll(keepingCapacity: true)
    }

    var currentPresentation: MarkdownRenderingPresentation? {
        guard presentationIsCurrent else { return nil }
        return cachedRenderingPresentation
    }

    func presentation(
        for text: String,
        snapshot: MarkdownLivePreviewSnapshot
    ) -> MarkdownRenderingPresentation {
        makePresentation(for: text, result: result(for: text), snapshot: snapshot)
    }

    func presentation(
        in textStorage: NSTextStorage,
        snapshot: MarkdownLivePreviewSnapshot
    ) -> MarkdownRenderingPresentation {
        let text = prepare(in: textStorage)
        // prepare installs a result for this exact storage revision.
        return makePresentation(for: text, result: cachedResult!, snapshot: snapshot)
    }

    private func makePresentation(
        for text: String,
        result: MarkdownSyntaxResult,
        snapshot: MarkdownLivePreviewSnapshot
    ) -> MarkdownRenderingPresentation {
        if presentationIsCurrent,
           cachedPreviewSnapshot == snapshot,
           let cachedRenderingPresentation {
            return cachedRenderingPresentation
        }
        let previewRanges: MarkdownLivePreviewRanges
        if cachedPreviewSnapshot == snapshot,
           let cachedPreviewRanges {
            previewRanges = cachedPreviewRanges
        } else {
            previewRanges = MarkdownLivePreview.ranges(
                in: text,
                result: result,
                snapshot: snapshot
            )
            cachedPreviewSnapshot = snapshot
            cachedPreviewRanges = previewRanges
        }
        presentationIsCurrent = true
        let syntaxIndex: MarkdownRenderingPresentation.SyntaxIndex
        if let renderingSyntaxIndex {
            syntaxIndex = renderingSyntaxIndex
        } else {
            syntaxIndex = MarkdownRenderingPresentation.SyntaxIndex(result: result)
            renderingSyntaxIndex = syntaxIndex
            renderingSyntaxIndexBuildCount += 1
        }
        let presentation = MarkdownRenderingPresentation(
            result: result,
            previewRanges: previewRanges,
            syntaxIndex: syntaxIndex
        )
        cachedRenderingPresentation = presentation
        return presentation
    }

    func observeCharacterEdits(in textStorage: NSTextStorage) {
        guard observedTextStorage !== textStorage else { return }
        if let observedTextStorage {
            NotificationCenter.default.removeObserver(
                self,
                name: NSTextStorage.didProcessEditingNotification,
                object: observedTextStorage
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSTextStorage.willProcessEditingNotification,
                object: observedTextStorage
            )
        }
        observedTextStorage = textStorage
        renderingSyntaxIndex = nil
        nativeCharacterEdit = nil
        processingNativeCharacterEdit = nil
        characterRevision &+= 1
        characterEdit = nil
        storageSnapshot = nil
        snapshotRevision = nil
        parsedStorageRevision = nil
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cachedTextStorageWillProcessEditing(_:)),
            name: NSTextStorage.willProcessEditingNotification,
            object: textStorage
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cachedTextStorageDidProcessEditing(_:)),
            name: NSTextStorage.didProcessEditingNotification,
            object: textStorage
        )
    }

    @objc private func cachedTextStorageWillProcessEditing(
        _ notification: Notification
    ) {
        guard let storage = notification.object as? NSTextStorage else { return }
        // Attribute fixing can widen the processed range to a whole paragraph.
        // Preserve the earlier character range for the validated model hint.
        processingNativeCharacterEdit = storage.editedMask.contains(.editedCharacters)
            ? CharacterEdit(range: storage.editedRange, delta: storage.changeInLength)
            : nil
    }

    @objc private func cachedTextStorageDidProcessEditing(
        _ notification: Notification
    ) {
        guard let textStorage = notification.object as? NSTextStorage else { return }
        let nativeEdit = processingNativeCharacterEdit
        processingNativeCharacterEdit = nil
        guard textStorage.editedMask.contains(.editedCharacters) else {
            if !isApplyingLayoutAttributes { dirtyLayoutRange = nil }
            return
        }
        presentationIsCurrent = false
        cachedRenderingPresentation = nil
        renderingSyntaxIndex = nil
        characterRevision &+= 1
        let range = textStorage.editedRange
        let delta = textStorage.changeInLength
        let nativeRange = nativeEdit?.range ?? range
        let nativeDelta = nativeEdit?.delta ?? delta
        if let pending = nativeCharacterEdit {
            let replaced = NSRange(location: nativeRange.location,
                                   length: nativeRange.length - nativeDelta)
            let start = min(pending.range.location, replaced.location)
            let end = max(NSMaxRange(pending.range), NSMaxRange(replaced))
            nativeCharacterEdit = CharacterEdit(
                range: NSRange(location: start, length: end - start + nativeDelta),
                delta: pending.delta + nativeDelta
            )
        } else {
            nativeCharacterEdit = CharacterEdit(range: nativeRange, delta: nativeDelta)
        }
        if let pending = characterEdit {
            // Both ranges below use coordinates immediately before this edit.
            // Enclose the previous changes and this replacement, then map the
            // enclosing range forward. This also handles deletions, overlapping
            // replacements, and edits before an earlier pending edit.
            let replaced = NSRange(location: range.location,
                                   length: range.length - delta)
            let start = min(pending.range.location, replaced.location)
            let end = max(NSMaxRange(pending.range), NSMaxRange(replaced))
            characterEdit = CharacterEdit(
                range: NSRange(location: start, length: end - start + delta),
                delta: pending.delta + delta
            )
        } else {
            characterEdit = CharacterEdit(range: range, delta: delta)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func decorationPlan(
        for text: String,
        result suppliedResult: MarkdownSyntaxResult? = nil
    ) -> MarkdownDecorationPlan {
        let result = suppliedResult ?? result(for: text)
        if let cachedDecorationPlan { return cachedDecorationPlan }
        let source = text as NSString
        let markers = result.spans.filter {
            $0.role == .blockquoteMarker
        }.sorted { $0.range.location < $1.range.location }
        var markerIndex = markers.startIndex
        var groups: [MarkdownDecorationGroup] = []

        let decoratedParagraphs = result.paragraphRuns.filter {
            $0.kind == .blockquote || $0.kind == .codeBlock
        }.sorted { $0.range.location < $1.range.location }
        for paragraph in decoratedParagraphs {
            while markerIndex < markers.endIndex,
                  markers[markerIndex].range.location
                    < paragraph.range.location {
                markerIndex += 1
            }
            let kind: MarkdownPresentation.BlockDecoration.Kind
            let markerRange: NSRange?
            let markerColumn: Int?
            if paragraph.kind == .codeBlock {
                kind = .codeBlock
                markerRange = nil
                markerColumn = nil
            } else {
                guard markerIndex < markers.endIndex,
                      NSLocationInRange(
                          markers[markerIndex].range.location,
                          paragraph.range
                      ) else { continue }
                kind = .blockquote
                markerRange = markers[markerIndex].range
                markerColumn = Self.sourceColumn(
                    from: paragraph.range.location,
                    to: markers[markerIndex].range.location,
                    in: source
                )
            }
            let run = MarkdownDecorationRun(
                paragraph: paragraph,
                markerRange: markerRange
            )
            if let previous = groups.last,
               previous.kind == kind,
               previous.markerColumn == markerColumn,
               NSMaxRange(previous.range) == paragraph.range.location {
                groups[groups.index(before: groups.endIndex)].runs.append(run)
            } else {
                groups.append(
                    MarkdownDecorationGroup(
                        kind: kind,
                        markerColumn: markerColumn,
                        runs: [run]
                    )
                )
            }
        }
        let plan = MarkdownDecorationPlan(groups: groups)
        cachedDecorationPlan = plan
        return plan
    }

    func cachedGroupLeft(
        range: NSRange,
        fontSize: CGFloat,
        lineFragmentPadding: CGFloat,
        calculate: () -> CGFloat?
    ) -> CGFloat? {
        let key = GroupGeometryKey(
            location: range.location,
            length: range.length,
            fontSize: fontSize,
            lineFragmentPadding: lineFragmentPadding
        )
        if let cached = cachedGroupLefts[key] { return cached }
        guard let calculated = calculate() else { return nil }
        cachedGroupLefts[key] = calculated
        return calculated
    }

    private static func sourceColumn(
        from start: Int,
        to end: Int,
        in text: NSString
    ) -> Int {
        var column = 0
        guard start < end else { return column }
        for location in start..<min(end, text.length) {
            if text.character(at: location) == 9 {
                column = ((column / 4) + 1) * 4
            } else {
                column += 1
            }
        }
        return column
    }
}
