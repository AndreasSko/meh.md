import Foundation

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Derived geometry only. Source rows stay in the native text storage, so
/// selection, copy, find, undo, and persistence continue to use Markdown ranges.
struct MarkdownTableLayout {
    struct Row {
        let range: NSRange
        let cells: [NSAttributedString]
        let height: CGFloat
        let isHeader: Bool
        let isLast: Bool
    }

    let rows: [Row]
    let delimiters: [NSRange]
    let width: CGFloat
    let padding: CGFloat

    static func make(
        text: String,
        result: MarkdownSyntaxResult,
        hiddenRanges: [NSRange],
        bodyFont: PlatformFont,
        width: CGFloat
    ) -> MarkdownTableLayout {
        let source = text as NSString
        let presentation = MarkdownRenderingPresentation(result: result, hiddenRanges: [])
        let padding = max(7, bodyFont.pointSize * 0.45)
        var rows: [Row] = []
        var delimiters: [NSRange] = []
        for table in result.tables where hiddenRanges.contains(where: {
            $0.location <= table.range.location
                && NSMaxRange($0) >= NSMaxRange(table.range)
        }) {
            let columnWidth = width / CGFloat(table.alignments.count)
            let textWidth = max(1, columnWidth - 2 * padding)
            let sourceRows = [table.header] + table.rows
            for (index, row) in sourceRows.enumerated() {
                let cells = table.alignments.enumerated().map { column, alignment in
                    let range = column < row.cells.count ? row.cells[column]
                        : NSRange(location: row.range.location, length: 0)
                    var spans: [MarkdownStyleSpan] = []
                    presentation.forEachSpan(intersecting: range) { spans.append($0) }
                    return cellText(
                        range: range, source: source, result: result, spans: spans,
                        bodyFont: bodyFont, alignment: alignment,
                        isHeader: index == 0
                    )
                }
                let textHeight = cells.map {
                    $0.boundingRect(
                        with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
                    ).height
                }.max() ?? 0
                rows.append(Row(
                    range: row.range,
                    cells: cells,
                    height: ceil(max(bodyFont.pointSize * 1.3, textHeight)) + 2 * padding,
                    isHeader: index == 0,
                    isLast: index == sourceRows.count - 1
                ))
            }
            delimiters.append(table.delimiterRange)
        }
        return MarkdownTableLayout(
            rows: rows, delimiters: delimiters, width: width, padding: padding
        )
    }

    private static func cellText(
        range: NSRange,
        source: NSString,
        result: MarkdownSyntaxResult,
        spans: [MarkdownStyleSpan],
        bodyFont: PlatformFont,
        alignment: MarkdownTableAlignment,
        isHeader: Bool
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        switch alignment {
        case .left: paragraph.alignment = .left
        case .center: paragraph.alignment = .center
        case .right: paragraph.alignment = .right
        }
        paragraph.lineBreakMode = .byWordWrapping
        let defaultFont = isHeader
            ? MarkdownPresentation.layoutFont(
                for: MarkdownFontRun(range: range, traits: .bold, headingLevel: nil),
                bodyFont: bodyFont
            ) : bodyFont
#if os(macOS)
        let color = NSColor.textColor
#else
        let color = UIColor.label
#endif
        let value = NSMutableAttributedString(
            string: source.substring(with: range),
            attributes: [.font: defaultFont, .foregroundColor: color,
                         .paragraphStyle: paragraph]
        )
        func local(_ other: NSRange) -> NSRange? {
            let overlap = NSIntersectionRange(range, other)
            guard overlap.length > 0 else { return nil }
            return NSRange(location: overlap.location - range.location,
                           length: overlap.length)
        }
        // Font runs are sorted and non-overlapping. Start at the cell rather
        // than scanning all formatting in the note for every rendered cell.
        var low = 0
        var high = result.fontRuns.count
        while low < high {
            let middle = low + (high - low) / 2
            if NSMaxRange(result.fontRuns[middle].range) <= range.location {
                low = middle + 1
            } else { high = middle }
        }
        for run in result.fontRuns[low...] {
            if run.range.location >= NSMaxRange(range) { break }
            guard let localRange = local(run.range) else { continue }
            let traits = isHeader ? run.traits.union(.bold) : run.traits
            let font = MarkdownPresentation.layoutFont(
                for: MarkdownFontRun(range: run.range, traits: traits, headingLevel: nil),
                bodyFont: bodyFont
            )
            value.addAttribute(.font, value: font, range: localRange)
        }
        var removed = IndexSet()
        for span in spans {
            guard let localRange = local(span.range) else { continue }
            value.addAttributes(
                MarkdownPresentation.renderingAttributes(for: span, in: result),
                range: localRange
            )
            for marker in MarkdownLivePreview.markerRanges(for: span, in: source) {
                if let marker = local(marker) {
                    removed.insert(integersIn: marker.location..<NSMaxRange(marker))
                }
            }
        }
        // Decode Markdown punctuation escapes in the visual copy only. A pipe
        // also needs escaping inside a GFM table's inline code span.
        let raw = value.string as NSString
        var index = 0
        while index + 1 < raw.length {
            let next = raw.character(at: index + 1)
            let inCode = spans.contains {
                $0.role == .code && NSLocationInRange(range.location + index, $0.range)
            }
            if raw.character(at: index) == 92,
               (next == 124 || (!inCode && (33...126).contains(next)
                    && !CharacterSet.alphanumerics.contains(UnicodeScalar(next)!))) {
                removed.insert(index)
                index += 2
            } else {
                index += 1
            }
        }
        for run in removed.rangeView.reversed() {
            value.deleteCharacters(in: NSRange(location: run.lowerBound, length: run.count))
        }
        return value
    }

    func apply(to text: NSMutableAttributedString, sourceRange: NSRange) {
        for row in rows { apply(row.range, height: row.height, to: text, sourceRange: sourceRange) }
        for delimiter in delimiters {
            apply(delimiter, height: 0.1, to: text, sourceRange: sourceRange)
        }
    }

    private func apply(
        _ range: NSRange, height: CGFloat,
        to text: NSMutableAttributedString, sourceRange: NSRange
    ) {
        let overlap = NSIntersectionRange(range, sourceRange)
        guard overlap.length > 0 else { return }
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        style.lineSpacing = 0
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        text.addAttribute(
            .paragraphStyle, value: style,
            range: NSRange(location: overlap.location - sourceRange.location,
                           length: overlap.length)
        )
    }

    func draw(
        fragment: NSTextLayoutFragment,
        layoutManager: NSTextLayoutManager,
        origin: CGPoint,
        lineFragmentPadding: CGFloat,
        context: CGContext
    ) {
        guard let manager = layoutManager.textContentManager else { return }
        let location = manager.offset(
            from: manager.documentRange.location,
            to: fragment.rangeInElement.location
        )
        guard let row = rows.first(where: { $0.range.location == location }) else { return }
        let rect = CGRect(
            x: origin.x + lineFragmentPadding,
            y: origin.y + fragment.layoutFragmentFrame.minY,
            width: width, height: row.height
        )
        context.saveGState()
        defer { context.restoreGState() }
#if os(macOS)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        let border = NSColor.separatorColor
        let fill = NSColor.quaternaryLabelColor.withAlphaComponent(0.08)
#else
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        let border = UIColor.separator
        let fill = UIColor.secondarySystemBackground
#endif
        if row.isHeader {
            context.setFillColor(fill.cgColor)
            context.fill(rect)
        }
        context.setStrokeColor(border.cgColor)
        context.setLineWidth(0.5)
        context.stroke(rect.insetBy(dx: 0.25, dy: 0.25))
        let columnWidth = width / CGFloat(row.cells.count)
        for (index, cell) in row.cells.enumerated() {
            let x = rect.minX + CGFloat(index) * columnWidth
            if index > 0 {
                context.move(to: CGPoint(x: x, y: rect.minY))
                context.addLine(to: CGPoint(x: x, y: rect.maxY))
                context.strokePath()
            }
            let cellRect = CGRect(x: x + padding, y: rect.minY + padding,
                                  width: columnWidth - 2 * padding,
                                  height: row.height - 2 * padding)
            context.saveGState()
            context.clip(to: cellRect)
            cell.draw(with: cellRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            context.restoreGState()
        }
    }
}
