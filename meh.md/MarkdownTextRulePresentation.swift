import CoreText
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// How the editor shows text rule decorations in Live Preview: colors as
/// rendering attributes, hidden text like hidden Markdown markers, and
/// inserted text drawn in each layout fragment, like time calculator
/// results. Nothing here touches the note's characters.
enum MarkdownTextRulePresentation {
    #if os(macOS)
    private static var secondaryColor: PlatformColor { .secondaryLabelColor }
    #else
    private static var secondaryColor: PlatformColor { .secondaryLabel }
    #endif

    static func color(for style: MarkdownTextRuleDecoration.Style) -> PlatformColor? {
        switch style {
        case .muted, .strike: secondaryColor
        case .accent: MehStyle.highlighterStroke
        case .warning: .systemOrange
        case .error: .systemRed
        case .success: .systemGreen
        case .highlight, .strong, .emphasis, .code: nil
        }
    }

    static func renderingAttributes(
        for style: MarkdownTextRuleDecoration.Style
    ) -> [NSAttributedString.Key: Any] {
        switch style {
        case .highlight: [.backgroundColor: MehStyle.highlighter]
        case .code: [.backgroundColor: PlatformColor.secondarySystemFill]
        case .strike: [
            .foregroundColor: secondaryColor,
            .strikethroughColor: secondaryColor,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
        ]
        case .strong, .emphasis: [:]
        default: color(for: style).map { [.foregroundColor: $0] } ?? [:]
        }
    }

    static func width(of text: String, font: PlatformFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Rule-hidden text joins Live Preview's hidden markers, except in the
    /// paragraph being edited, which shows its text as written.
    static func addingHides(
        _ hides: [NSRange], to ranges: MarkdownLivePreviewRanges,
        in text: NSString, snapshot: MarkdownLivePreviewSnapshot
    ) -> MarkdownLivePreviewRanges {
        let concealed = hides.filter {
            NSMaxRange($0) <= text.length
                && MarkdownLivePreview.conceals($0, in: text, snapshot: snapshot)
        }
        guard !concealed.isEmpty else { return ranges }
        return MarkdownLivePreviewRanges(
            collapsed: MarkdownTextRuleBlocks.merged(ranges.collapsed + concealed),
            transparent: ranges.transparent
        )
    }

    // MARK: - Links

    /// The rule link at an offset, when it shows as a link: everywhere but
    /// the paragraph being edited, where a tap places the caret instead.
    static func link(
        at offset: Int, in textView: MarkdownTextView, includingEdited: Bool = false
    ) -> MarkdownTextRuleDecorations.Link? {
        guard let link = textView.markdownSyntaxCache.textRuleDecorations.link(at: offset)
        else { return nil }
        #if os(macOS)
        let source = textView.string as NSString
        #else
        let source = (textView.text ?? "") as NSString
        #endif
        guard NSMaxRange(link.range) <= source.length else { return nil }
        if includingEdited { return link }
        return MarkdownLivePreview.conceals(
            link.range, in: source, snapshot: MarkdownLivePreview.snapshot(for: textView)
        ) ? link : nil
    }

    // MARK: - Inserted text

    private struct Drawn {
        let text: String
        let font: PlatformFont
        let color: PlatformColor
        let background: PlatformColor?
        /// The baseline start in text container coordinates.
        let origin: CGPoint
        let width: CGFloat
    }

    /// Redraws the lines whose inserted text changed after a refresh.
    static func update(_ textView: MarkdownTextView) {
        let current = textView.markdownSyntaxCache.textRuleDecorations.inserts
        let previous = textView.markdownSyntaxCache.drawnTextRuleInserts
        guard current != previous else { return }
        textView.markdownSyntaxCache.drawnTextRuleInserts = current
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return }
        #if os(macOS)
        let source = textView.string as NSString
        #else
        let source = (textView.text ?? "") as NSString
        #endif
        let changed = Set(previous).symmetricDifference(current).map(\.location)
        for location in Set(changed) where location <= source.length && source.length > 0 {
            let line = source.lineRange(for: NSRange(location: min(location, source.length - 1),
                                                     length: 0))
            if let range = MarkdownPresentation.textRange(
                for: line, documentStart: contentManager.documentRange.location,
                contentManager: contentManager
            ) {
                layoutManager.invalidateLayout(for: range)
                textView.redrawMarkdownDecorations(for: range)
            }
        }
    }

    private static func inserts(
        in fragment: NSTextLayoutFragment, textView: MarkdownTextView
    ) -> [MarkdownTextRuleDecorations.Insert] {
        let all = textView.markdownSyntaxCache.textRuleDecorations.inserts
        guard !all.isEmpty, let layoutManager = fragment.textLayoutManager,
              let range = MarkdownHistoryMarks.nsRange(of: fragment, in: layoutManager)
        else { return [] }
        #if os(macOS)
        let length = (textView.string as NSString).length
        #else
        let length = ((textView.text ?? "") as NSString).length
        #endif
        // Inserts are sorted by position, so find the first one here.
        var low = 0, high = all.count
        while low < high {
            let middle = (low + high) / 2
            if all[middle].location < range.location { low = middle + 1 } else { high = middle }
        }
        let end = NSMaxRange(range) == length ? length + 1 : NSMaxRange(range)
        return Array(all[low...].prefix { $0.location < end })
    }

    private static func drawn(
        _ inserts: [MarkdownTextRuleDecorations.Insert], in textView: MarkdownTextView,
        layoutManager: NSTextLayoutManager
    ) -> [Drawn] {
        guard let contentManager = layoutManager.textContentManager else { return [] }
        #if os(macOS)
        guard let storage = textView.textStorage else { return [] }
        #else
        let storage = textView.textStorage
        #endif
        let source = storage.string as NSString
        guard source.length > 0 else { return [] }
        func font(for insert: MarkdownTextRuleDecorations.Insert, anchor: Int) -> PlatformFont {
            let font = storage.attribute(.font, at: anchor, effectiveRange: nil)
                as? PlatformFont ?? textView.font ?? MarkdownPresentation.editorBodyFont
            return MarkdownPresentation.textRuleFont(font, style: insert.style)
        }
        // Inserts at one place share its room, one after the other.
        var totals: [Int: CGFloat] = [:]
        for insert in inserts where insert.location <= source.length {
            let lineStart = source.lineRange(for: NSRange(
                location: min(insert.location, source.length - 1), length: 0)).location
            let anchor = insert.location == lineStart
                ? min(insert.location, source.length - 1) : insert.location - 1
            totals[insert.location, default: 0] += width(of: insert.text,
                                                        font: font(for: insert, anchor: anchor))
        }
        var placed: [Int: CGFloat] = [:]
        var result: [Drawn] = []
        for insert in inserts where insert.location <= source.length {
            let line = source.lineRange(for: NSRange(
                location: min(insert.location, source.length - 1), length: 0))
            var lineEnd = NSMaxRange(line)
            while lineEnd > line.location,
                  source.character(at: lineEnd - 1) == 10 || source.character(at: lineEnd - 1) == 13 {
                lineEnd -= 1
            }
            let atLineStart = insert.location == line.location
            if atLineStart && insert.location >= lineEnd { continue }
            // Inside a line the layout kept room; at its end the text goes
            // after the last character.
            let anchor = atLineStart ? insert.location : insert.location - 1
            guard anchor >= 0, anchor < source.length,
                  let range = MarkdownPresentation.textRange(
                      for: NSRange(location: anchor, length: 1),
                      documentStart: contentManager.documentRange.location,
                      contentManager: contentManager) else { continue }
            let font = font(for: insert, anchor: anchor)
            let width = width(of: insert.text, font: font)
            let total = totals[insert.location] ?? width
            let before = placed[insert.location, default: 0]
            placed[insert.location] = before + width
            let reserved = insert.location < lineEnd
            var origin: CGPoint?
            layoutManager.enumerateTextSegments(
                in: range, type: .standard, options: [.rangeNotRequired]
            ) { _, frame, baseline, _ in
                guard !frame.isNull else { return true }
                let x = (atLineStart ? frame.minX - total
                    : (reserved ? frame.maxX - total : frame.maxX)) + before
                origin = CGPoint(x: x, y: frame.minY + baseline)
                return false
            }
            guard let origin else { continue }
            #if os(macOS)
            let primary = PlatformColor.textColor
            #else
            let primary = PlatformColor.label
            #endif
            result.append(Drawn(
                text: insert.text, font: font,
                color: color(for: insert.style) ?? primary,
                background: insert.style == .highlight ? MehStyle.highlighter
                    : insert.style == .code ? PlatformColor.secondarySystemFill : nil,
                origin: origin, width: width))
        }
        return result
    }

    /// Where a fragment draws its inserted text, relative to the fragment.
    static func surfaceBounds(
        of fragment: NSTextLayoutFragment, textView: MarkdownTextView
    ) -> CGRect? {
        let inserts = inserts(in: fragment, textView: textView)
        guard !inserts.isEmpty, let layoutManager = fragment.textLayoutManager else { return nil }
        let frame = fragment.layoutFragmentFrame
        return drawn(inserts, in: textView, layoutManager: layoutManager)
            .map { item in
                CGRect(x: item.origin.x - frame.minX,
                       y: item.origin.y - frame.minY - item.font.ascender,
                       width: item.width, height: item.font.ascender - item.font.descender)
            }
            .reduce(CGRect.null) { $0.union($1) }
    }

    static func draw(
        in fragment: NSTextLayoutFragment, textView: MarkdownTextView,
        at point: CGPoint, context: CGContext
    ) {
        let inserts = inserts(in: fragment, textView: textView)
        guard !inserts.isEmpty, let layoutManager = fragment.textLayoutManager else { return }
        let frame = fragment.layoutFragmentFrame
        let offset = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        context.saveGState()
        defer { context.restoreGState() }
        // Text views draw flipped; CoreText expects the y axis to point up.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for item in drawn(inserts, in: textView, layoutManager: layoutManager) {
            let x = item.origin.x + offset.x
            let y = item.origin.y + offset.y
            if let background = item.background {
                context.setFillColor(background.cgColor)
                context.fill(CGRect(x: x, y: y - item.font.ascender, width: item.width,
                                    height: item.font.ascender - item.font.descender))
            }
            context.setFillColor(item.color.cgColor)
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: item.text,
                attributes: [
                    .font: item.font,
                    NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
                ]))
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, context)
        }
    }
}

extension MarkdownTextRuleDecorations {
    /// Colors for links and styles, in rule order: later entries paint
    /// over earlier ones.
    func renderingAttributes(
        intersecting target: NSRange
    ) -> [(NSRange, [NSAttributedString.Key: Any])] {
        guard !isEmpty else { return [] }
        var result: [(NSRange, [NSAttributedString.Key: Any])] = []
        for link in links where NSIntersectionRange(link.range, target).length > 0 {
            result.append((link.range, [.foregroundColor: MehStyle.ink]))
        }
        for style in styles where NSIntersectionRange(style.range, target).length > 0 {
            let attributes = MarkdownTextRulePresentation.renderingAttributes(for: style.style)
            if !attributes.isEmpty { result.append((style.range, attributes)) }
        }
        return result
    }
}
