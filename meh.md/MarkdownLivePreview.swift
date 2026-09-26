import Foundation
import ObjectiveC

#if os(macOS)
import AppKit
typealias MarkdownNativeTextView = NSTextView
#else
import UIKit
typealias MarkdownNativeTextView = UITextView
#endif

enum MarkdownEditorMode: String, CaseIterable {
    case source
    case livePreview
}

struct MarkdownLivePreviewSnapshot: Equatable {
    let mode: MarkdownEditorMode
    let selection: NSRange
    let isEditing: Bool
    let tableWidth: CGFloat
    let fontSize: CGFloat

    init(
        mode: MarkdownEditorMode,
        selection: NSRange,
        isEditing: Bool = true,
        tableWidth: CGFloat = .greatestFiniteMagnitude,
        fontSize: CGFloat = 17
    ) {
        self.mode = mode
        self.selection = selection
        self.isEditing = isEditing
        self.tableWidth = tableWidth
        self.fontSize = fontSize
    }
}

struct MarkdownLivePreviewRanges: Equatable {
    let collapsed: [NSRange]
    let transparent: [NSRange]
}

private final class MarkdownLivePreviewViewState: NSObject {
    var snapshot = MarkdownLivePreviewSnapshot(
        mode: .source,
        selection: NSRange(location: 0, length: 0)
    )
}

nonisolated(unsafe) private var markdownLivePreviewStateKey: UInt8 = 0

enum MarkdownLivePreview {
    static let collapsedFontSize: CGFloat = 0.001

    static func update(
        _ textView: MarkdownNativeTextView,
        mode: MarkdownEditorMode,
        selection: NSRange,
        isEditing: Bool,
        fontSize: CGFloat = 17
    ) {
#if os(macOS)
        let container = textView.textContainer
        let width = (container?.size.width ?? 0)
            - 2 * (container?.lineFragmentPadding ?? 0)
#else
        let width = textView.textContainer.size.width
            - 2 * textView.textContainer.lineFragmentPadding
#endif
        state(for: textView).snapshot = MarkdownLivePreviewSnapshot(
            mode: mode,
            selection: selection,
            isEditing: isEditing,
            tableWidth: width,
            fontSize: fontSize
        )
    }

    static func snapshot(
        for textView: MarkdownNativeTextView
    ) -> MarkdownLivePreviewSnapshot {
        state(for: textView).snapshot
    }

    static func hiddenRanges(
        in text: String,
        result: MarkdownSyntaxResult,
        snapshot: MarkdownLivePreviewSnapshot
    ) -> [NSRange] {
        ranges(in: text, result: result, snapshot: snapshot).collapsed
    }

    static func transparentRanges(
        in text: String,
        result: MarkdownSyntaxResult,
        snapshot: MarkdownLivePreviewSnapshot
    ) -> [NSRange] {
        ranges(in: text, result: result, snapshot: snapshot).transparent
    }

    static func ranges(
        in text: String,
        result: MarkdownSyntaxResult,
        snapshot: MarkdownLivePreviewSnapshot
    ) -> MarkdownLivePreviewRanges {
        guard snapshot.mode == .livePreview, !text.isEmpty else {
            return MarkdownLivePreviewRanges(collapsed: [], transparent: [])
        }
        let source = text as NSString
        var collapsed: [NSRange] = []
        var transparent: [NSRange] = []
        for span in result.spans {
            collapsed.append(contentsOf: markerRanges(for: span, in: source))
            switch span.role {
            case .blockquoteMarker:
                transparent.append(span.range)
            case .listMarker where span.range.length == 1:
                let marker = source.character(at: span.range.location)
                if marker == 42 || marker == 43 || marker == 45 {
                    transparent.append(span.range)
                }
            default:
                break
            }
        }
        var activeRange = snapshot.isEditing
            ? activeParagraphRange(in: source, selection: snapshot.selection)
            : nil
        // A table is one editing unit. Revealing only the current paragraph
        // would leave a mixture of source rows and rendered rows.
        for table in result.tables {
            if let active = activeRange, intersects(table.range, active) {
                activeRange = NSUnionRange(active, table.range)
            } else if canRender(table, snapshot: snapshot) {
                collapsed.append(table.range)
            } else {
                // Very wide tables remain readable/editable source instead of
                // squeezing columns into a few pixels or clipping cell text.
                collapsed.removeAll { intersects($0, table.range) }
            }
        }
        func concealed(_ candidates: [NSRange]) -> [NSRange] {
            let bounded = candidates.filter { candidate in
                candidate.location >= 0 && candidate.length > 0
                    && NSMaxRange(candidate) <= source.length
                    && (activeRange.map { !intersects(candidate, $0) } ?? true)
            }
            return mergedRanges(bounded)
        }
        return MarkdownLivePreviewRanges(
            collapsed: concealed(collapsed),
            transparent: concealed(transparent)
        )
    }

    static func canRender(
        _ table: MarkdownTable,
        snapshot: MarkdownLivePreviewSnapshot
    ) -> Bool {
        snapshot.mode == .livePreview
            && table.rows.allSatisfy { $0.cells.count <= table.alignments.count }
            && snapshot.tableWidth.isFinite
            && snapshot.tableWidth / CGFloat(max(1, table.alignments.count))
                >= max(52, snapshot.fontSize * 3)
    }

    static func conceals(
        _ range: NSRange,
        in text: NSString,
        snapshot: MarkdownLivePreviewSnapshot
    ) -> Bool {
        guard snapshot.mode == .livePreview,
              range.location >= 0, range.length > 0,
              NSMaxRange(range) <= text.length else { return false }
        guard snapshot.isEditing else { return true }
        return !intersects(
            range,
            activeParagraphRange(in: text, selection: snapshot.selection)
        )
    }

    static func activeParagraphRange(
        in text: NSString,
        selection: NSRange
    ) -> NSRange {
        guard text.length > 0 else {
            return NSRange(location: 0, length: 0)
        }
        let start = min(max(selection.location, 0), text.length)
        let rawEnd = selection.location.addingReportingOverflow(selection.length)
        let end = rawEnd.overflow
            ? text.length
            : min(max(start, rawEnd.partialValue), text.length)
        if start == text.length, isLineBreak(text.character(at: start - 1)) {
            return NSRange(location: text.length, length: 0)
        }
        let location = start == text.length ? text.length - 1 : start
        let lastLocation = end > start ? end - 1 : location
        let firstParagraph = text.paragraphRange(
            for: NSRange(location: location, length: 0)
        )
        let lastParagraph = text.paragraphRange(
            for: NSRange(location: lastLocation, length: 0)
        )
        return NSRange(
            location: firstParagraph.location,
            length: NSMaxRange(lastParagraph) - firstParagraph.location
        )
    }

    private static func isLineBreak(_ character: unichar) -> Bool {
        character == 10 || character == 13
            || character == 0x2028 || character == 0x2029
    }

    private static func state(
        for textView: MarkdownNativeTextView
    ) -> MarkdownLivePreviewViewState {
        if let state = objc_getAssociatedObject(
            textView,
            &markdownLivePreviewStateKey
        ) as? MarkdownLivePreviewViewState {
            return state
        }
        let state = MarkdownLivePreviewViewState()
        objc_setAssociatedObject(
            textView,
            &markdownLivePreviewStateKey,
            state,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return state
    }

    static func markerRanges(
        for span: MarkdownStyleSpan,
        in source: NSString
    ) -> [NSRange] {
        guard span.range.length > 0,
              span.range.location >= 0,
              NSMaxRange(span.range) <= source.length else { return [] }
        switch span.role {
        case .heading:
            return headingMarkerRanges(for: span.range, in: source)
        case .strong:
            return pairedMarkerRanges(for: span.range, length: 2)
        case .emphasis:
            return pairedMarkerRanges(for: span.range, length: 1)
        case .highlight, .strikethrough:
            return pairedMarkerRanges(for: span.range, length: 2)
        case .code:
            return inlineCodeMarkerRanges(for: span.range, in: source)
        case .link:
            return linkMarkerRanges(for: span.range, in: source)
        case .listMarker, .blockquote, .blockquoteMarker:
            return []
        }
    }

    private static func headingMarkerRanges(
        for range: NSRange,
        in source: NSString
    ) -> [NSRange] {
        var end = range.location
        let limit = NSMaxRange(range)
        while end < limit, source.character(at: end) == 35 {
            end += 1
        }
        while end < limit {
            let character = source.character(at: end)
            guard character == 32 || character == 9 else { break }
            end += 1
        }
        guard end > range.location, end < limit else { return [] }
        return [NSRange(location: range.location, length: end - range.location)]
    }

    private static func pairedMarkerRanges(
        for range: NSRange,
        length: Int
    ) -> [NSRange] {
        guard range.length >= length * 2 else { return [] }
        return [
            NSRange(location: range.location, length: length),
            NSRange(location: NSMaxRange(range) - length, length: length),
        ]
    }

    private static func inlineCodeMarkerRanges(
        for range: NSRange,
        in source: NSString
    ) -> [NSRange] {
        guard source.range(of: "\n", options: [], range: range).location
                == NSNotFound else { return [] }
        let marker = source.character(at: range.location)
        guard marker == 96 || marker == 126 else { return [] }
        var length = 1
        while length < range.length,
              source.character(at: range.location + length) == marker {
            length += 1
        }
        guard range.length >= length * 2 else { return [] }
        let closing = NSRange(
            location: NSMaxRange(range) - length,
            length: length
        )
        guard source.character(at: closing.location) == marker else { return [] }
        return [NSRange(location: range.location, length: length), closing]
    }

    private static func linkMarkerRanges(
        for range: NSRange,
        in source: NSString
    ) -> [NSRange] {
        guard source.character(at: range.location) == 91,
              let labelEnd = closingBracket(
                  after: range.location,
                  before: NSMaxRange(range),
                  in: source
              ), labelEnd + 1 < NSMaxRange(range),
              source.character(at: labelEnd + 1) == 40 else { return [] }
        return [
            NSRange(location: range.location, length: 1),
            NSRange(
                location: labelEnd,
                length: NSMaxRange(range) - labelEnd
            ),
        ]
    }

    private static func closingBracket(
        after opening: Int,
        before end: Int,
        in source: NSString
    ) -> Int? {
        var depth = 1
        var location = opening + 1
        while location < end {
            let character = source.character(at: location)
            if character == 92 {
                location += 2
                continue
            }
            if character == 91 { depth += 1 }
            if character == 93 {
                depth -= 1
                if depth == 0 { return location }
            }
            location += 1
        }
        return nil
    }

    private static func intersects(_ left: NSRange, _ right: NSRange) -> Bool {
        NSIntersectionRange(left, right).length > 0
    }

    private static func mergedRanges(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.filter { $0.length > 0 }.sorted {
            if $0.location == $1.location { return $0.length < $1.length }
            return $0.location < $1.location
        }
        var merged: [NSRange] = []
        for range in sorted {
            guard let previous = merged.last,
                  range.location <= NSMaxRange(previous) else {
                merged.append(range)
                continue
            }
            merged[merged.count - 1] = NSRange(
                location: previous.location,
                length: max(NSMaxRange(previous), NSMaxRange(range))
                    - previous.location
            )
        }
        return merged
    }
}
