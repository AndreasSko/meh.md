import Foundation

/// A part of the note a text rule sees at once: a paragraph, a heading, a
/// list item or a quote. Code blocks, tables, rules and front matter are
/// never passed to rules.
nonisolated struct MarkdownTextRuleBlock: Sendable, Equatable {
    struct Line: Sendable, Equatable {
        /// UTF-16 offset in the block.
        let start: Int
        let text: String
    }

    /// Where the block is in the note, in UTF-16.
    let range: NSRange
    let kind: MarkdownTextRuleManifest.BlockKind
    /// A heading's level, or how deep a list item is (1 is the outermost).
    let level: Int
    /// The text the rule sees. In plain input, Markdown markers, code and
    /// links are replaced with U+FFFC, one for each UTF-16 unit.
    let text: String
    /// The note's text in this block, unmasked, to check that decorations
    /// don't split a character.
    let original: String
    let lines: [Line]
    /// Code, links and task boxes, relative to the block. Decorations
    /// can't cover them.
    let protected: [NSRange]

    /// What a result depends on, besides the rule's own state. The text
    /// compares by UTF-16 unit: Swift's `String` equality treats `é` and
    /// `e` + accent as equal, but their offsets differ.
    struct Key: Hashable, Sendable {
        let kind: MarkdownTextRuleManifest.BlockKind
        let level: Int
        let text: [UInt16]
        let original: [UInt16]
        let protected: [NSRange]
    }

    var key: Key {
        Key(kind: kind, level: level, text: Array(text.utf16),
            original: Array(original.utf16), protected: protected)
    }
}

enum MarkdownTextRuleBlocks {
    nonisolated static let mask: unichar = 0xFFFC

    /// The blocks in a note, in order, for one input form.
    static func blocks(
        in text: String, result: MarkdownSyntaxResult, input: MarkdownTextRuleManifest.Input
    ) -> [MarkdownTextRuleBlock] {
        let source = text as NSString
        let length = source.length
        guard length > 0 else { return [] }
        let spans = result.spans.sorted { $0.range.location < $1.range.location }
        var runs: [Int: MarkdownParagraphRun] = [:]
        for run in result.paragraphRuns { runs[run.range.location] = run }
        let excluded = merged(result.tables.map(\.range) + [frontMatter(in: source)].compactMap { $0 })

        // Ranges in the whole note: what plain input blanks out, and what
        // decorations may not cover.
        var masked: [NSRange] = []
        var protected: [NSRange] = []
        // Level and end of each heading, by its first line. A heading
        // underlined with `===` can take more than one line.
        var headings: [Int: (level: Int, end: Int)] = [:]
        var markers: Set<Int> = []
        var rules: Set<Int> = []
        for span in spans {
            switch span.role {
            case .code, .link:
                masked.append(span.range)
                protected.append(span.range)
            case .taskMarker:
                masked.append(span.range)
                protected.append(span.range)
            case .listMarker:
                masked.append(span.range)
                markers.insert(source.lineRange(for: span.range).location)
            case .blockquoteMarker:
                masked.append(span.range)
            case .heading(let level):
                headings[source.lineRange(for: NSRange(location: span.range.location, length: 0))
                    .location] = (level, NSMaxRange(span.range))
                masked.append(contentsOf: MarkdownLivePreview.markerRanges(for: span, in: source))
            case .rule:
                rules.insert(source.lineRange(for: span.range).location)
            default:
                masked.append(contentsOf: MarkdownLivePreview.markerRanges(for: span, in: source))
            }
        }
        masked = merged(masked)
        protected = merged(protected)

        var blocks: [MarkdownTextRuleBlock] = []
        var current: (kind: MarkdownTextRuleManifest.BlockKind, level: Int, range: NSRange)?
        func close() {
            guard let block = current else { return }
            current = nil
            blocks.append(make(block.kind, level: block.level, range: block.range,
                               source: source,
                               masked: input == .plain ? intersecting(masked, block.range) : [],
                               protected: intersecting(protected, block.range)))
        }
        var lineStart = 0
        var excludedIndex = 0
        while lineStart < length {
            let line = source.lineRange(for: NSRange(location: lineStart, length: 0))
            lineStart = NSMaxRange(line)
            var content = line
            while content.length > 0,
                  isLineBreak(source.character(at: NSMaxRange(content) - 1)) { content.length -= 1 }
            while excludedIndex < excluded.count,
                  NSMaxRange(excluded[excludedIndex]) <= line.location { excludedIndex += 1 }
            let isExcluded = excludedIndex < excluded.count
                && NSIntersectionRange(excluded[excludedIndex], line).length > 0
            let run = runs[line.location]
            if isExcluded || run?.kind == .codeBlock || rules.contains(line.location)
                || isBlank(source, content) {
                close()
                continue
            }
            if let heading = headings[line.location] {
                close()
                var lastLine = line
                if heading.end > NSMaxRange(line) {
                    lastLine = source.lineRange(for: NSRange(location: heading.end - 1, length: 0))
                    lineStart = NSMaxRange(lastLine)
                }
                var range = NSRange(location: line.location,
                                    length: NSMaxRange(lastLine) - line.location)
                while range.length > 0,
                      isLineBreak(source.character(at: NSMaxRange(range) - 1)) { range.length -= 1 }
                current = (.heading, heading.level, range)
                close()
                continue
            }
            let kind: MarkdownTextRuleManifest.BlockKind
            var level = 1
            switch run?.kind {
            case .list:
                kind = .listItem
                level = 1 + indentColumns(source, line.location) / 2
                if !markers.contains(line.location), let open = current, open.kind == .listItem {
                    current?.range = NSUnionRange(open.range, content)
                    continue
                }
                close()
            case .blockquote:
                kind = .quote
            case .indented where current?.kind == .listItem:
                if let open = current { current?.range = NSUnionRange(open.range, content) }
                continue
            default:
                kind = .paragraph
            }
            if let open = current, open.kind == kind, kind != .listItem {
                current?.range = NSUnionRange(open.range, content)
            } else {
                close()
                current = (kind, level, content)
            }
        }
        close()
        return blocks
    }

    private static func make(
        _ kind: MarkdownTextRuleManifest.BlockKind, level: Int, range: NSRange,
        source: NSString, masked: [NSRange], protected: [NSRange]
    ) -> MarkdownTextRuleBlock {
        var units = [unichar](repeating: 0, count: range.length)
        source.getCharacters(&units, range: range)
        let original = String(utf16CodeUnits: units, count: units.count)
        let originalUnits = units
        for mask in masked {
            let overlap = NSIntersectionRange(mask, range)
            guard overlap.length > 0 else { continue }
            for index in overlap.location..<NSMaxRange(overlap) {
                units[index - range.location] = Self.mask
            }
        }
        let text = String(utf16CodeUnits: units, count: units.count)
        // Lines end where the note's own lines do: LF, CR, CRLF or a Unicode
        // line separator.
        var lines: [MarkdownTextRuleBlock.Line] = []
        var start = 0
        var index = 0
        while index <= units.count {
            // Boundaries come from the note itself: masked code may hide a CR.
            guard index == units.count || isLineBreak(originalUnits[index]) else {
                index += 1
                continue
            }
            lines.append(.init(start: start, text: String(utf16CodeUnits: Array(units[start..<index]),
                                                          count: index - start)))
            if index + 1 < units.count, originalUnits[index] == 13,
               originalUnits[index + 1] == 10 { index += 1 }
            index += 1
            start = index
        }
        let local = protected.compactMap { item -> NSRange? in
            let overlap = NSIntersectionRange(item, range)
            return overlap.length > 0
                ? NSRange(location: overlap.location - range.location, length: overlap.length)
                : nil
        }
        return MarkdownTextRuleBlock(range: range, kind: kind, level: level, text: text,
                                     original: original, lines: lines, protected: local)
    }

    /// YAML front matter: `---` on the first line, up to the next `---` or
    /// `...` line.
    static func frontMatter(in source: NSString) -> NSRange? {
        guard source.hasPrefix("---") else { return nil }
        let first = source.lineRange(for: NSRange(location: 0, length: 0))
        guard source.substring(with: first).trimmingCharacters(in: .whitespacesAndNewlines) == "---"
        else { return nil }
        var location = NSMaxRange(first)
        while location < source.length {
            let line = source.lineRange(for: NSRange(location: location, length: 0))
            let text = source.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            if text == "---" || text == "..." {
                return NSRange(location: 0, length: NSMaxRange(line))
            }
            location = NSMaxRange(line)
        }
        return nil
    }

    /// The sorted, merged ranges that overlap `range`.
    private static func intersecting(_ ranges: [NSRange], _ range: NSRange) -> [NSRange] {
        var low = 0
        var high = ranges.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(ranges[middle]) <= range.location { low = middle + 1 } else { high = middle }
        }
        var end = low
        while end < ranges.count, ranges[end].location < NSMaxRange(range) { end += 1 }
        return Array(ranges[low..<end])
    }

    private static func indentColumns(_ source: NSString, _ location: Int) -> Int {
        var columns = 0
        var index = location
        while index < source.length {
            switch source.character(at: index) {
            case 32: columns += 1
            case 9: columns += 4 - columns % 4
            default: return columns
            }
            index += 1
        }
        return columns
    }

    private static func isBlank(_ source: NSString, _ range: NSRange) -> Bool {
        for index in range.location..<NSMaxRange(range) {
            let character = source.character(at: index)
            if character != 32 && character != 9 { return false }
        }
        return true
    }

    /// The characters `NSString.lineRange` ends a line at.
    private static func isLineBreak(_ character: unichar) -> Bool {
        character == 10 || character == 13 || character == 0x85 || character == 0x2028
            || character == 0x2029
    }

    nonisolated static func merged(_ ranges: [NSRange]) -> [NSRange] {
        ranges.filter { $0.length > 0 }.sorted { $0.location < $1.location }
            .reduce(into: []) { result, range in
                if let last = result.last, range.location <= NSMaxRange(last) {
                    result[result.count - 1] = NSUnionRange(last, range)
                } else {
                    result.append(range)
                }
            }
    }
}
