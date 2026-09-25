import Foundation
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
            isEditing: textView.window?.firstResponder === textView
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
            isEditing: textView.window?.firstResponder === textView
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
        let layoutRange = syntaxCache.layoutRange(
            for: presentation, text: text, bodyFont: bodyFont
        )
        syntaxCache.isApplyingLayoutAttributes = true
        applyLayoutAttributes(
            to: textStorage,
            text: text,
            result: result,
            bodyFont: bodyFont,
            hiddenRanges: previewRanges.collapsed,
            transparentRanges: previewRanges.transparent,
            undoManager: textView.undoManager,
            range: layoutRange
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

        MarkdownLivePreview.update(
            textView,
            mode: mode,
            selection: textView.selectedRange,
            isEditing: textView.isFirstResponder
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
            isEditing: textView.isFirstResponder
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
        let previewRanges = presentation.previewRanges
        let layoutRange = syntaxCache.layoutRange(
            for: presentation, text: text, bodyFont: bodyFont
        )
        syntaxCache.isApplyingLayoutAttributes = true
        applyLayoutAttributes(
            to: textView.textStorage,
            text: text,
            result: result,
            bodyFont: bodyFont,
            hiddenRanges: previewRanges.collapsed,
            transparentRanges: previewRanges.transparent,
            undoManager: textView.undoManager,
            range: layoutRange
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
            invalidatedRange: layoutRange
        )
        textView.setNeedsDisplay()
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
        attributes[.paragraphStyle] = bodyParagraphStyle(for: bodyFont)
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
        guard let presentation = syntaxCache.currentPresentation else {
            return
        }
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
        undoManager: UndoManager?,
        range: NSRange
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
        for run in result.paragraphRuns {
            guard let localRange = local(run.range) else { continue }
            let style = paragraphStyle(
                for: run,
                text: text as NSString,
                bodyFont: bodyFont
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
        var changes: [AttributeChange] = []
        for key in [
            NSAttributedString.Key.font,
            .paragraphStyle,
            .foregroundColor,
            .kern,
            .obliqueness,
            .strikethroughColor,
            .strikethroughStyle,
        ] {
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

        var appliedCount = 0
        presentation.forEachSpan(intersecting: fragmentRange) { span in
            let intersection = NSIntersectionRange(span.range, fragmentRange)
            guard intersection.length > 0 else { return }
            let attributes = renderingAttributes(
                for: span,
                in: presentation.result
            )
            guard !attributes.isEmpty,
                  let textRange = textRange(
                    for: intersection,
                    documentStart: documentStart,
                      contentManager: contentManager
                  ) else { return }
            layoutManager.setRenderingAttributes(attributes, for: textRange)
            appliedCount += 1
        }
        presentation.forEachHiddenRange(intersecting: fragmentRange) { range in
            let intersection = NSIntersectionRange(range, fragmentRange)
            guard intersection.length > 0,
                  let textRange = textRange(
                      for: intersection,
                      documentStart: documentStart,
                      contentManager: contentManager
                  ) else { return }
            layoutManager.setRenderingAttributes(
                [.foregroundColor: PlatformColor.clear],
                for: textRange
            )
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

    private static func textSegmentFrames(
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
        case .listMarker:
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
        bodyFont: PlatformFont
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
            style.paragraphSpacing = em * 0.2
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

    private static func layoutFont(
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
    let result: MarkdownSyntaxResult
    let previewRanges: MarkdownLivePreviewRanges
    let hiddenRanges: [NSRange]
    private let spanRanges: [NSRange]
    private let spanPrefixMaximumEnds: [Int]
    private let hiddenPrefixMaximumEnds: [Int]

    init(
        result: MarkdownSyntaxResult,
        previewRanges: MarkdownLivePreviewRanges
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
        spanRanges = result.spans.map(\.range)
        spanPrefixMaximumEnds = Self.prefixMaximumEnds(spanRanges)
        hiddenPrefixMaximumEnds = Self.prefixMaximumEnds(hiddenRanges)
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
        spanRanges = result.spans.map(\.range)
        spanPrefixMaximumEnds = Self.prefixMaximumEnds(spanRanges)
        hiddenPrefixMaximumEnds = Self.prefixMaximumEnds(self.hiddenRanges)
    }

    func forEachSpan(
        intersecting target: NSRange,
        _ body: (MarkdownStyleSpan) -> Void
    ) {
        for index in candidateIndices(
            ranges: spanRanges,
            prefixMaximumEnds: spanPrefixMaximumEnds,
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
            ranges: spanRanges,
            prefixMaximumEnds: spanPrefixMaximumEnds,
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
    private weak var observedTextStorage: NSTextStorage?
    private var presentationIsCurrent = false
    private var cachedDecorationPlan: MarkdownDecorationPlan?
    private var cachedGroupLefts: [GroupGeometryKey: CGFloat] = [:]
    private(set) var parseCount = 0
    private(set) var incrementalParseCount = 0
    private struct CharacterEdit {
        let range: NSRange
        let delta: Int
    }
    var isApplyingLayoutAttributes = false
    private var characterEdit: CharacterEdit?
    private var cachedCharacterRevision: UInt64 = 0
    // nil means that the complete layout must be refreshed.
    private var dirtyLayoutRange: NSRange?
    private var appliedPreviewRanges: MarkdownLivePreviewRanges?
    private var appliedBodyFont: PlatformFont?
    private(set) var lastLayoutRange = NSRange(location: 0, length: 0)

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

    // Arbitrary strings have no native revision identity. Keep exact equality
    // here, including for callers that reuse a cache with unrelated text.
    func result(for text: String) -> MarkdownSyntaxResult {
        if let cachedText, cachedText.utf8.elementsEqual(text.utf8),
           let cachedResult {
            return cachedResult
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
        let presentation = MarkdownRenderingPresentation(
            result: result,
            previewRanges: previewRanges
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
        }
        observedTextStorage = textStorage
        characterRevision &+= 1
        characterEdit = nil
        storageSnapshot = nil
        snapshotRevision = nil
        parsedStorageRevision = nil
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cachedTextStorageDidProcessEditing(_:)),
            name: NSTextStorage.didProcessEditingNotification,
            object: textStorage
        )
    }

    @objc private func cachedTextStorageDidProcessEditing(
        _ notification: Notification
    ) {
        guard let textStorage = notification.object as? NSTextStorage else { return }
        guard textStorage.editedMask.contains(.editedCharacters) else {
            if !isApplyingLayoutAttributes { dirtyLayoutRange = nil }
            return
        }
        presentationIsCurrent = false
        cachedRenderingPresentation = nil
        characterRevision &+= 1
        let range = textStorage.editedRange
        let delta = textStorage.changeInLength
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
