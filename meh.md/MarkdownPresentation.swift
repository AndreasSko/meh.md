import Foundation

#if os(macOS)
import AppKit

typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
#else
import UIKit

typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
#endif

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

#if os(macOS)
    static var editorBodyFont: PlatformFont {
        bodyFont(pointSize: defaultFontSize)
    }
#else
    static var editorBodyFont: PlatformFont {
        bodyFont(pointSize: defaultFontSize)
    }
#endif

    static func normalizedFontSize(_ value: Double) -> CGFloat {
        guard value.isFinite else { return defaultFontSize }
        return min(max(CGFloat(value), fontSizeRange.lowerBound),
                   fontSizeRange.upperBound)
    }

#if os(macOS)
    static func configure(_ textView: NSTextView, fontSize: Double = 17) {
        guard let layoutManager = textView.textLayoutManager else {
            assertionFailure("Markdown editor requires TextKit 2")
            return
        }

        let syntaxCache = syntaxCache(for: textView)
        layoutManager.renderingAttributesValidator = {
            [weak textView] manager, fragment in
            guard let textView else { return }
            _ = applyRenderingAttributes(
                to: manager,
                fragment: fragment,
                result: syntaxCache.result(for: textView.string)
            )
        }
        let font = bodyFont(pointSize: normalizedFontSize(fontSize))
        textView.font = font
        refresh(textView, fontSize: fontSize, syntaxCache: syntaxCache)
    }

    static func refresh(
        _ textView: NSTextView,
        fontSize: Double = 17,
        syntaxCache suppliedSyntaxCache: MarkdownSyntaxCache? = nil
    ) {
        guard !textView.hasMarkedText(),
              let textStorage = textView.textStorage else { return }

        let syntaxCache = suppliedSyntaxCache ?? Self.syntaxCache(for: textView)
        let text = textView.string
        let result = syntaxCache.result(for: text)
        let bodyFont = bodyFont(pointSize: normalizedFontSize(fontSize))
        let selection = textView.selectedRange()
        applyLayoutAttributes(
            to: textStorage,
            text: text,
            result: result,
            bodyFont: bodyFont,
            undoManager: textView.undoManager
        )
        if textView.selectedRange() != selection {
            textView.setSelectedRange(selection)
        }
        applyBaseTypingAttributes(to: textView, bodyFont: bodyFont)
        refreshVisibleRenderingAttributes(
            in: textView.textLayoutManager,
            text: text,
            syntaxCache: syntaxCache
        )
        textView.needsDisplay = true
    }

    private static func syntaxCache(
        for textView: NSTextView
    ) -> MarkdownSyntaxCache {
        (textView as? MarkdownTextView)?.markdownSyntaxCache
            ?? MarkdownSyntaxCache()
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
        drawBlockBackgrounds(
            text: textView.string,
            syntaxCache: syntaxCache(for: textView),
            layoutManager: layoutManager,
            containerWidth: textContainer.size.width,
            lineFragmentPadding: textContainer.lineFragmentPadding,
            containerOrigin: textView.textContainerOrigin,
            visibleRange: visibleRange,
            dirtyRect: dirtyRect,
            context: context
        )
    }
#else
    static func configure(_ textView: UITextView, fontSize: Double = 17) {
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

        let syntaxCache = syntaxCache(for: textView)
        layoutManager.renderingAttributesValidator = {
            [weak textView] manager, fragment in
            guard let textView else { return }
            _ = applyRenderingAttributes(
                to: manager,
                fragment: fragment,
                result: syntaxCache.result(for: textView.text ?? "")
            )
        }
        let font = bodyFont(pointSize: normalizedFontSize(fontSize))
        textView.font = font
        refresh(textView, fontSize: fontSize, syntaxCache: syntaxCache)
    }

    static func refresh(
        _ textView: UITextView,
        fontSize: Double = 17,
        syntaxCache suppliedSyntaxCache: MarkdownSyntaxCache? = nil
    ) {
        guard textView.markedTextRange == nil else { return }

        let syntaxCache = suppliedSyntaxCache ?? Self.syntaxCache(for: textView)
        let text = textView.text ?? ""
        let result = syntaxCache.result(for: text)
        let bodyFont = bodyFont(pointSize: normalizedFontSize(fontSize))
        let selection = textView.selectedRange
        applyLayoutAttributes(
            to: textView.textStorage,
            text: text,
            result: result,
            bodyFont: bodyFont,
            undoManager: textView.undoManager
        )
        if textView.selectedRange != selection {
            textView.selectedRange = selection
        }
        applyBaseTypingAttributes(to: textView, bodyFont: bodyFont)
        refreshVisibleRenderingAttributes(
            in: textView.textLayoutManager,
            text: text,
            syntaxCache: syntaxCache
        )
        textView.setNeedsDisplay()
    }

    private static func syntaxCache(
        for textView: UITextView
    ) -> MarkdownSyntaxCache {
        (textView as? MarkdownTextView)?.markdownSyntaxCache
            ?? MarkdownSyntaxCache()
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
        let decorations = fragmentBlockDecorations(
            fragmentRange: fragmentRange,
            fragmentFrame: fragment.layoutFragmentFrame,
            text: textView.text ?? "",
            plan: syntaxCache.decorationPlan(for: text),
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
            result: syntaxCache.result(for: text),
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

    private static func applyLayoutAttributes(
        to textStorage: NSTextStorage,
        text: String,
        result: MarkdownSyntaxResult,
        bodyFont: PlatformFont,
        undoManager: UndoManager?
    ) {
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
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
        let desired = NSMutableAttributedString(string: text)
        desired.addAttribute(.font, value: bodyFont, range: fullRange)
        desired.addAttribute(
            .paragraphStyle,
            value: bodyParagraphStyle(for: bodyFont),
            range: fullRange
        )
        for run in result.fontRuns {
            let font = layoutFont(for: run, bodyFont: bodyFont)
            desired.addAttribute(.font, value: font, range: run.range)
        }
        for run in result.paragraphRuns {
            let style = paragraphStyle(
                for: run,
                text: text as NSString,
                bodyFont: bodyFont
            )
            desired.addAttribute(
                .paragraphStyle,
                value: style,
                range: run.range
            )
        }
        for span in result.spans where span.role == .strikethrough {
            desired.addAttributes(
                [
                    .strikethroughColor: secondaryTextColor,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                ],
                range: span.range
            )
        }

        var changes: [AttributeChange] = []
        for key in [
            NSAttributedString.Key.font,
            .paragraphStyle,
            .strikethroughColor,
            .strikethroughStyle,
        ] {
            changes.append(contentsOf: changedAttributes(
                key,
                from: desired,
                to: textStorage,
                range: fullRange
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
                at: location,
                longestEffectiveRange: &desiredRange,
                in: range
            )
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
        result: MarkdownSyntaxResult
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
        for span in result.spans {
            let attributes = renderingAttributes(for: span, in: result)
            guard !attributes.isEmpty else { continue }

            let intersection = NSIntersectionRange(span.range, fragmentRange)
            guard intersection.length > 0,
                  let textRange = textRange(
                    for: intersection,
                    documentStart: documentStart,
                    contentManager: contentManager
                  ) else { continue }
            layoutManager.setRenderingAttributes(attributes, for: textRange)
            appliedCount += 1
        }
        return appliedCount
    }

    @discardableResult
    static func refreshVisibleRenderingAttributes(
        in layoutManager: NSTextLayoutManager?,
        text: String,
        syntaxCache: MarkdownSyntaxCache? = nil
    ) -> Int {
        guard let layoutManager,
              let contentManager = layoutManager.textContentManager else {
            return 0
        }
        layoutManager.invalidateRenderingAttributes(
            for: contentManager.documentRange
        )
        let viewportController = layoutManager.textViewportLayoutController
        viewportController.layoutViewport()
        guard let viewportRange = viewportController.viewportRange else {
            return 0
        }

        let result = syntaxCache?.result(for: text)
            ?? MarkdownSyntax.parse(text)
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
                    result: result
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
        let size = bodyFont.pointSize * headingScale(for: run.headingLevel)
        var font = run.traits.contains(.monospaced)
            ? monospacedFont(size: size)
            : fontWithSize(bodyFont, size: size)
        if run.traits.contains(.bold) {
            font = strongFont(font)
        }
        if run.traits.contains(.italic) {
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
    private static func bodyFont(pointSize: CGFloat) -> NSFont {
        .systemFont(ofSize: pointSize)
    }

    private static func strongFont(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    private static func emphasisFont(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }

    private static func fontWithSize(_ font: NSFont, size: CGFloat) -> NSFont {
        NSFont(descriptor: font.fontDescriptor, size: size) ?? font
    }

    private static func monospacedFont(size: CGFloat) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static var primaryTextColor: NSColor { .textColor }
    private static var secondaryTextColor: NSColor { .secondaryLabelColor }
    private static var tertiaryTextColor: NSColor { .tertiaryLabelColor }
#else
    private static func bodyFont(pointSize: CGFloat) -> UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .systemFont(ofSize: pointSize)
        )
    }

    private static func strongFont(_ font: UIFont) -> UIFont {
        fontAddingTrait(.traitBold, to: font)
    }

    private static func emphasisFont(_ font: UIFont) -> UIFont {
        fontAddingTrait(.traitItalic, to: font)
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

    private static func monospacedFont(size: CGFloat) -> UIFont {
        .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static var primaryTextColor: UIColor { .label }
    private static var secondaryTextColor: UIColor { .secondaryLabel }
    private static var tertiaryTextColor: UIColor { .tertiaryLabel }
#endif
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

final class MarkdownSyntaxCache {
    private struct GroupGeometryKey: Hashable {
        let location: Int
        let length: Int
        let fontSize: CGFloat
        let lineFragmentPadding: CGFloat
    }

    private var cachedText: String?
    private var cachedResult: MarkdownSyntaxResult?
    private var cachedDecorationPlan: MarkdownDecorationPlan?
    private var cachedGroupLefts: [GroupGeometryKey: CGFloat] = [:]
    private(set) var parseCount = 0

    func result(for text: String) -> MarkdownSyntaxResult {
        if let cachedText, cachedText.utf8.elementsEqual(text.utf8),
           let cachedResult {
            return cachedResult
        }
        let result = MarkdownSyntax.parse(text)
        parseCount += 1
        cachedText = text
        cachedResult = result
        cachedDecorationPlan = nil
        cachedGroupLefts.removeAll(keepingCapacity: true)
        return result
    }

    func decorationPlan(for text: String) -> MarkdownDecorationPlan {
        let result = result(for: text)
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
