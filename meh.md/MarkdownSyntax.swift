import Foundation

enum MarkdownStyleRole: Equatable {
    case heading(level: Int)
    case strong
    case emphasis
    case highlight
    case strikethrough
    case code
    case link
    case listMarker
    case blockquote
    case blockquoteMarker
}

struct MarkdownStyleSpan: Equatable {
    let range: NSRange
    let role: MarkdownStyleRole
}

struct MarkdownFontTraits: OptionSet, Equatable {
    let rawValue: Int

    static let bold = MarkdownFontTraits(rawValue: 1 << 0)
    static let italic = MarkdownFontTraits(rawValue: 1 << 1)
    static let monospaced = MarkdownFontTraits(rawValue: 1 << 2)
}

struct MarkdownFontRun: Equatable {
    let range: NSRange
    let traits: MarkdownFontTraits
    let headingLevel: Int?
}

enum MarkdownParagraphKind: Equatable {
    case heading(level: Int)
    case list
    case indented
    case blockquote
    case codeBlock
}

struct MarkdownParagraphRun: Equatable {
    let range: NSRange
    let kind: MarkdownParagraphKind
    let contentColumn: Int
    let contentPrefixRange: NSRange
}

enum MarkdownTableAlignment: Equatable {
    case left
    case center
    case right
}

struct MarkdownTableRow: Equatable {
    let range: NSRange
    /// Trimmed UTF-16 ranges into the original Markdown source.
    let cells: [NSRange]
}

struct MarkdownTable: Equatable {
    let range: NSRange
    let header: MarkdownTableRow
    let delimiterRange: NSRange
    let rows: [MarkdownTableRow]
    let alignments: [MarkdownTableAlignment]
}

struct MarkdownSyntaxResult: Equatable {
    let spans: [MarkdownStyleSpan]
    let fontRuns: [MarkdownFontRun]
    let paragraphRuns: [MarkdownParagraphRun]
    // Line boundaries with no open emphasis or fenced-code context. Unlike
    // visible spans, these account for unmatched delimiters as well.
    let restartOffsets: [Int]
    let canRestartAtEnd: Bool
    var tables: [MarkdownTable] = []
}

struct MarkdownSyntaxIncrementalResult: Equatable {
    let result: MarkdownSyntaxResult
    let invalidatedRange: NSRange
}

enum MarkdownSyntax {
    static func parse(_ text: String) -> MarkdownSyntaxResult {
        let source = text as NSString
        let fences = fencedCodeRanges(in: source)
        let fenced = fences.ranges
        let inline = inlineCodeRanges(in: source, excluding: fenced)
        let codeRanges = (fenced + inline).sorted { left, right in
            if left.location == right.location {
                return left.length > right.length
            }
            return left.location < right.location
        }
        var spans = codeRanges.map {
            MarkdownStyleSpan(range: $0, role: .code)
        }

        let lines = lineRanges(in: source)
        let tables = tableRanges(in: source, lines: lines, fenced: fenced)
        let tableLines = tables.flatMap { table in
            [table.header.range, table.delimiterRange] + table.rows.map(\.range)
        }
        var paragraphRuns = codeBlockParagraphs(
            in: fenced,
            lines: lines,
            source: source
        )
        appendLineSpans(
            in: source,
            excluding: codeRanges,
            tableLines: tableLines,
            spans: &spans,
            paragraphRuns: &paragraphRuns
        )
        appendLinkSpans(in: source, excluding: codeRanges, spans: &spans)
        let emphasis = appendEmphasisSpans(
            in: source,
            excluding: codeRanges,
            blockBoundaries: emphasisBlockBoundaries(
                in: source, lines: lines, spans: spans, fenced: fenced,
                tableLines: tableLines
            ),
            spans: &spans
        )
        appendPairedSpans(
            in: source,
            marker: ASCII.equals,
            role: .highlight,
            excluding: codeRanges,
            spans: &spans
        )
        appendPairedSpans(
            in: source,
            marker: ASCII.tilde,
            role: .strikethrough,
            excluding: codeRanges,
            spans: &spans
        )
        // Parse inline syntax independently in each source cell. Global
        // matches can otherwise cross a pipe or style the delimiter row.
        spans.removeAll { span in
            tableLines.contains { overlaps(span.range, $0) }
        }
        for table in tables {
            for row in [table.header] + table.rows {
                for cell in row.cells where cell.length > 0 {
                    let local = inlineSpans(in: source.substring(with: cell))
                    spans.append(contentsOf: local.map { span in
                        MarkdownStyleSpan(
                            range: offset(span.range, by: cell.location),
                            role: span.role
                        )
                    })
                }
            }
        }
        spans.sort { left, right in
            if left.range.location == right.range.location {
                return left.range.length > right.range.length
            }
            return left.range.location < right.range.location
        }
        let canRestartAtEnd = emphasis.atEnd && !fences.hasOpenFence
        var restartOffsets = emphasis.offsets
        if canRestartAtEnd, restartOffsets.last != source.length {
            restartOffsets.append(source.length)
        }
        var result = MarkdownSyntaxResult(
            spans: spans,
            fontRuns: fontRuns(for: spans),
            paragraphRuns: paragraphRuns,
            restartOffsets: restartOffsets,
            canRestartAtEnd: canRestartAtEnd
        )
        result.tables = tables
        return result
    }

    private static func inlineSpans(in text: String) -> [MarkdownStyleSpan] {
        let source = text as NSString
        let code = inlineCodeRanges(in: source, excluding: [])
        var spans = code.map { MarkdownStyleSpan(range: $0, role: .code) }
        appendLinkSpans(in: source, excluding: code, spans: &spans)
        _ = appendEmphasisSpans(
            in: source, excluding: code, blockBoundaries: [], spans: &spans
        )
        appendPairedSpans(
            in: source, marker: ASCII.equals, role: .highlight,
            excluding: code, spans: &spans
        )
        appendPairedSpans(
            in: source, marker: ASCII.tilde, role: .strikethrough,
            excluding: code, spans: &spans
        )
        return spans
    }

    static func spans(in text: String) -> [MarkdownStyleSpan] {
        parse(text).spans
    }

    static func fontRuns(in text: String) -> [MarkdownFontRun] {
        parse(text).fontRuns
    }

    /// Reparse from a cached neutral line boundary until the outgoing context
    /// is neutral again. Unchanged suffix syntax can then be reused exactly.
    /// Edits use post-edit UTF-16 coordinates, including coalesced edits.
    /// A large region without a safe boundary retains the full-parse fallback.
    static func incrementallyParse(
        _ text: String,
        previousText: String,
        previousResult: MarkdownSyntaxResult,
        editedRange: NSRange,
        changeInLength: Int
    ) -> MarkdownSyntaxIncrementalResult? {
        let source = text as NSString
        let previousSource = previousText as NSString
        let previousEditedLength = editedRange.length - changeInLength
        guard editedRange.location >= 0,
              editedRange.length >= 0,
              previousEditedLength >= 0,
              previousSource.length + changeInLength == source.length,
              NSMaxRange(editedRange) <= source.length,
              editedRange.location + previousEditedLength
                <= previousSource.length else { return nil }

        let previousEditedRange = NSRange(
            location: editedRange.location,
            length: previousEditedLength
        )
        // A new table can form when an edit changes either of two neighboring
        // lines, so inspect the edit and one line on each side in both versions.
        if hasNearbyPipe(around: editedRange, in: source)
            || hasNearbyPipe(around: previousEditedRange, in: previousSource) {
            return nil
        }
        let oldAffected = syntaxLineRange(
            containing: previousEditedRange, in: previousSource
        )
        let start = previousResult.restartOffsets.last(where: {
            $0 <= oldAffected.location
        }) ?? 0
        let ends = previousResult.restartOffsets.filter {
            $0 >= NSMaxRange(oldAffected) && $0 > start
        }
        // EOF is also a valid stopping point even when delimiters remain open:
        // there is then no unchanged suffix whose interpretation could differ.
        var candidates = ends
        if candidates.last != previousSource.length {
            candidates.append(previousSource.length)
        }
        var replacement: (old: NSRange, new: NSRange, syntax: MarkdownSyntaxResult)?
        var minimumEnd = start
        for oldEnd in candidates {
            guard oldEnd >= minimumEnd || oldEnd == previousSource.length else {
                continue
            }
            let newEnd = oldEnd + changeInLength
            guard newEnd >= start, newEnd <= source.length else { return nil }
            // Bound speculative work for edits affecting long-range context.
            // A full parse remains the correctness fallback for those cases.
            guard newEnd - start <= 65_536 else { return nil }
            let region = NSRange(location: start, length: newEnd - start)
            let local = parse(source.substring(with: region))
            // A distant fence edit can expose a table within this region.
            // Tables are not spliced into incremental results yet.
            guard local.tables.isEmpty else { return nil }
            if local.canRestartAtEnd || oldEnd == previousSource.length {
                replacement = (
                    NSRange(location: start, length: oldEnd - start),
                    region, local
                )
                break
            }
            // Grow geometrically instead of reparsing every larger prefix.
            minimumEnd = start + max(128, 2 * (oldEnd - start))
        }
        guard let replacement else { return nil }
        let previousLine = replacement.old
        let line = replacement.new
        let local = replacement.syntax
        let delta = changeInLength
        // A blank line after a pipe-free body row is a table boundary. Treat
        // touching either edge like overlap so edits can grow or shrink it.
        guard !previousResult.tables.contains(where: { table in
            table.range.location <= NSMaxRange(previousLine)
                && NSMaxRange(table.range) >= previousLine.location
        }) else { return nil }
        let tables = previousResult.tables.map { table in
            table.range.location > NSMaxRange(previousLine)
                ? offset(table, by: delta) : table
        }
        var spans = previousResult.spans.compactMap { span in
            splice(
                span,
                replacing: previousLine,
                delta: delta
            )
        }
        spans.append(contentsOf: local.spans.map {
            MarkdownStyleSpan(
                range: offset($0.range, by: line.location),
                role: $0.role
            )
        })
        spans.sort(by: spanOrdering)

        // Adjacent equal font runs may cross an otherwise neutral boundary.
        // Rebuild from cached spans so clipping never loses their other half.
        let fontRuns = fontRuns(for: spans)

        var paragraphs = previousResult.paragraphRuns.compactMap { paragraph in
            splice(
                paragraph,
                replacing: previousLine,
                delta: delta
            )
        }
        paragraphs.append(contentsOf: local.paragraphRuns.map {
            MarkdownParagraphRun(
                range: offset($0.range, by: line.location),
                kind: $0.kind,
                contentColumn: $0.contentColumn,
                contentPrefixRange: offset(
                    $0.contentPrefixRange,
                    by: line.location
                )
            )
        })
        paragraphs.sort(by: paragraphOrdering)

        var result = MarkdownSyntaxResult(
                spans: spans,
                fontRuns: fontRuns,
                paragraphRuns: paragraphs,
                restartOffsets: previousResult.restartOffsets.filter { $0 < start }
                    + local.restartOffsets.map { $0 + start }
                    + previousResult.restartOffsets.filter {
                        $0 > NSMaxRange(previousLine)
                    }.map { $0 + delta },
                canRestartAtEnd: NSMaxRange(previousLine) == previousSource.length
                    ? local.canRestartAtEnd : previousResult.canRestartAtEnd
            )
        result.tables = tables
        return MarkdownSyntaxIncrementalResult(
            result: result,
            invalidatedRange: line
        )
    }

    /// Matches ``lineRanges(in:)`` exactly. `NSString.lineRange(for:)` also
    /// recognizes Unicode separators that this Markdown parser treats as
    /// ordinary content, so it cannot define the incremental boundary.
    private static func syntaxLineRange(
        containing range: NSRange,
        in source: NSString
    ) -> NSRange {
        var start = range.location
        while start > 0, source.character(at: start - 1) != ASCII.lineFeed {
            start -= 1
        }
        var end = NSMaxRange(range)
        while end < source.length,
              source.character(at: end) != ASCII.lineFeed {
            end += 1
        }
        if end < source.length { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    private static func hasNearbyPipe(
        around range: NSRange,
        in source: NSString
    ) -> Bool {
        let affected = syntaxLineRange(containing: range, in: source)
        var start = affected.location
        var end = NSMaxRange(affected)
        if start > 0 {
            start = syntaxLineRange(
                containing: NSRange(location: start - 1, length: 0),
                in: source
            ).location
        }
        if end < source.length {
            end = NSMaxRange(syntaxLineRange(
                containing: NSRange(location: end, length: 0),
                in: source
            ))
        }
        return source.substring(with: NSRange(
            location: start, length: end - start
        )).contains("|")
    }

    private static func overlaps(_ left: NSRange, _ right: NSRange) -> Bool {
        left.location < NSMaxRange(right)
            && right.location < NSMaxRange(left)
    }

    private static func offset(_ range: NSRange, by delta: Int) -> NSRange {
        NSRange(location: range.location + delta, length: range.length)
    }

    private static func offset(
        _ row: MarkdownTableRow,
        by delta: Int
    ) -> MarkdownTableRow {
        MarkdownTableRow(
            range: offset(row.range, by: delta),
            cells: row.cells.map { offset($0, by: delta) }
        )
    }

    private static func offset(
        _ table: MarkdownTable,
        by delta: Int
    ) -> MarkdownTable {
        MarkdownTable(
            range: offset(table.range, by: delta),
            header: offset(table.header, by: delta),
            delimiterRange: offset(table.delimiterRange, by: delta),
            rows: table.rows.map { offset($0, by: delta) },
            alignments: table.alignments
        )
    }

    private static func splice(
        _ span: MarkdownStyleSpan,
        replacing replacedRange: NSRange,
        delta: Int
    ) -> MarkdownStyleSpan? {
        guard !overlaps(span.range, replacedRange) else { return nil }
        guard span.range.location >= NSMaxRange(replacedRange) else {
            return span
        }
        return MarkdownStyleSpan(
            range: offset(span.range, by: delta),
            role: span.role
        )
    }

    private static func splice(
        _ paragraph: MarkdownParagraphRun,
        replacing replacedRange: NSRange,
        delta: Int
    ) -> MarkdownParagraphRun? {
        guard !overlaps(paragraph.range, replacedRange) else { return nil }
        guard paragraph.range.location >= NSMaxRange(replacedRange) else {
            return paragraph
        }
        return MarkdownParagraphRun(
            range: offset(paragraph.range, by: delta),
            kind: paragraph.kind,
            contentColumn: paragraph.contentColumn,
            contentPrefixRange: offset(paragraph.contentPrefixRange, by: delta)
        )
    }

    private static func spanOrdering(
        _ left: MarkdownStyleSpan,
        _ right: MarkdownStyleSpan
    ) -> Bool {
        if left.range.location == right.range.location {
            return left.range.length > right.range.length
        }
        return left.range.location < right.range.location
    }

    private static func paragraphOrdering(
        _ left: MarkdownParagraphRun,
        _ right: MarkdownParagraphRun
    ) -> Bool {
        let leftIsCode = left.kind == .codeBlock
        let rightIsCode = right.kind == .codeBlock
        if leftIsCode != rightIsCode { return leftIsCode }
        return left.range.location < right.range.location
    }

    private static func fencedCodeRanges(
        in source: NSString
    ) -> (ranges: [NSRange], hasOpenFence: Bool) {
        let lines = lineRanges(in: source)
        var ranges: [NSRange] = []
        var hasOpenFence = false
        var lineIndex = 0
        while lineIndex < lines.count {
            let line = lines[lineIndex]
            guard let fence = openingFence(in: source, line: line) else {
                lineIndex += 1
                continue
            }

            var end = source.length
            var closingLineIndex: Int?
            if lineIndex + 1 < lines.count {
                for candidateIndex in (lineIndex + 1)..<lines.count {
                    let candidate = lines[candidateIndex]
                    if isClosingFence(
                        in: source,
                        line: candidate,
                        marker: fence.marker,
                        minimumLength: fence.length
                    ) {
                        end = NSMaxRange(candidate)
                        closingLineIndex = candidateIndex
                        break
                    }
                }
            }
            ranges.append(
                NSRange(location: line.location, length: end - line.location)
            )
            hasOpenFence = closingLineIndex == nil
            lineIndex = (closingLineIndex ?? (lines.count - 1)) + 1
        }
        return (ranges, hasOpenFence)
    }

    private static func inlineCodeRanges(
        in source: NSString,
        excluding excluded: [NSRange]
    ) -> [NSRange] {
        var ranges: [NSRange] = []
        var location = 0
        while location < source.length {
            if let range = containingRange(location, in: excluded) {
                location = NSMaxRange(range)
                continue
            }
            guard source.character(at: location) == ASCII.backtick,
                  !isEscaped(location, in: source) else {
                location += 1
                continue
            }

            let markerLength = repeatedLength(
                of: ASCII.backtick,
                at: location,
                in: source
            )
            let lineEnd = contentEndOfLine(containing: location, in: source)
            var closing = location + markerLength
            var matchedEnd: Int?
            while closing < lineEnd {
                guard source.character(at: closing) == ASCII.backtick else {
                    closing += 1
                    continue
                }
                let closingLength = repeatedLength(
                    of: ASCII.backtick,
                    at: closing,
                    in: source
                )
                if closingLength == markerLength {
                    matchedEnd = closing + closingLength
                    break
                }
                closing += closingLength
            }
            let end = matchedEnd ?? lineEnd
            ranges.append(
                NSRange(location: location, length: end - location)
            )
            location = max(end, location + markerLength)
        }
        return ranges
    }

    private static func appendLineSpans(
        in source: NSString,
        excluding codeRanges: [NSRange],
        tableLines: [NSRange],
        spans: inout [MarkdownStyleSpan],
        paragraphRuns: inout [MarkdownParagraphRun]
    ) {
        for line in lineRanges(in: source) {
            if tableLines.contains(where: { $0.location == line.location }) {
                continue
            }
            let contentEnd = contentEnd(for: line, in: source)
            guard !isContained(line.location, in: codeRanges) else {
                continue
            }
            var location = skipHorizontalWhitespace(
                from: line.location,
                before: contentEnd,
                in: source
            )
            guard location < contentEnd else { continue }
            let initialContentLocation = location
            let directIndentColumn = visualColumn(
                from: line.location,
                to: location,
                in: source
            )

            var listContentStart: Int?
            var quoteMarkers: [NSRange] = []
            var previousContainerWasList = false
            while location < contentEnd {
                if !previousContainerWasList,
                   let marker = listMarker(
                       at: location,
                       lineEnd: contentEnd,
                       in: source
                   ) {
                    spans.append(
                        MarkdownStyleSpan(range: marker, role: .listMarker)
                    )
                    location = skipHorizontalWhitespace(
                        from: NSMaxRange(marker),
                        before: contentEnd,
                        in: source
                    )
                    listContentStart = location
                    previousContainerWasList = true
                    continue
                }
                guard source.character(at: location) == ASCII.greaterThan,
                      !isEscaped(location, in: source) else { break }
                quoteMarkers.append(
                    NSRange(location: location, length: 1)
                )
                location = skipHorizontalWhitespace(
                    from: location + 1,
                    before: contentEnd,
                    in: source
                )
                previousContainerWasList = false
            }

            let paragraphRange = paragraphRange(for: line, in: source)
            var hasParagraphRole = false
            if !quoteMarkers.isEmpty {
                spans.append(
                    MarkdownStyleSpan(
                        range: NSRange(
                            location: line.location,
                            length: contentEnd - line.location
                        ),
                        role: .blockquote
                    )
                )
                for marker in quoteMarkers {
                    spans.append(
                        MarkdownStyleSpan(
                            range: marker,
                            role: .blockquoteMarker
                        )
                    )
                }
                paragraphRuns.append(
                    MarkdownParagraphRun(
                        range: paragraphRange,
                        kind: .blockquote,
                        contentColumn: visualColumn(
                            from: line.location,
                            to: location,
                            in: source
                        ),
                        contentPrefixRange: NSRange(
                            location: line.location,
                            length: location - line.location
                        )
                    )
                )
                hasParagraphRole = true
            } else if let listContentStart {
                paragraphRuns.append(
                    MarkdownParagraphRun(
                        range: paragraphRange,
                        kind: .list,
                        contentColumn: visualColumn(
                            from: line.location,
                            to: listContentStart,
                            in: source
                        ),
                        contentPrefixRange: NSRange(
                            location: line.location,
                            length: listContentStart - line.location
                        )
                    )
                )
                hasParagraphRole = true
            }

            let hasContainerPrefix = !quoteMarkers.isEmpty
                || listContentStart != nil
            if location < contentEnd,
               (hasContainerPrefix || directIndentColumn <= 3),
               source.character(at: location) == ASCII.hash {
                let markerLength = repeatedLength(
                    of: ASCII.hash,
                    at: location,
                    in: source
                )
                let markerEnd = location + markerLength
                if markerLength <= 6,
                   markerEnd == contentEnd
                    || isWhitespace(source.character(at: markerEnd)) {
                    spans.append(
                        MarkdownStyleSpan(
                            range: NSRange(
                                location: location,
                                length: contentEnd - location
                            ),
                            role: .heading(level: markerLength)
                        )
                    )
                    if !hasContainerPrefix {
                        paragraphRuns.append(
                            MarkdownParagraphRun(
                                range: paragraphRange,
                                kind: .heading(level: markerLength),
                                contentColumn: 0,
                                contentPrefixRange: NSRange(
                                    location: line.location,
                                    length: 0
                                )
                            )
                        )
                        hasParagraphRole = true
                    }
                }
            }

            if !hasParagraphRole, directIndentColumn > 0 {
                paragraphRuns.append(
                    MarkdownParagraphRun(
                        range: paragraphRange,
                        kind: .indented,
                        contentColumn: directIndentColumn,
                        contentPrefixRange: NSRange(
                            location: line.location,
                            length: initialContentLocation - line.location
                        )
                    )
                )
            }
        }
    }

    private static func appendPairedSpans(
        in source: NSString,
        marker: unichar,
        role: MarkdownStyleRole,
        excluding codeRanges: [NSRange],
        spans: inout [MarkdownStyleSpan]
    ) {
        var location = 0
        while location + 1 < source.length {
            if let range = containingRange(location, in: codeRanges) {
                location = NSMaxRange(range)
                continue
            }
            guard isExactPair(of: marker, at: location, in: source),
                  !isEscaped(location, in: source),
                  location + 2 < source.length,
                  !isWhitespace(source.character(at: location + 2)) else {
                location += 1
                continue
            }

            let lineEnd = contentEndOfLine(containing: location, in: source)
            var closing = location + 2
            var match: Int?
            while closing + 1 < lineEnd {
                if let range = containingRange(closing, in: codeRanges) {
                    closing = NSMaxRange(range)
                    continue
                }
                if isExactPair(of: marker, at: closing, in: source),
                   !isEscaped(closing, in: source),
                   !isWhitespace(source.character(at: closing - 1)) {
                    match = closing
                    break
                }
                closing += 1
            }
            guard let match else {
                location += 2
                continue
            }
            let end = match + 2
            spans.append(
                MarkdownStyleSpan(
                    range: NSRange(location: location, length: end - location),
                    role: role
                )
            )
            location = end
        }
    }

    private static func appendLinkSpans(
        in source: NSString,
        excluding codeRanges: [NSRange],
        spans: inout [MarkdownStyleSpan]
    ) {
        var location = 0
        while location < source.length {
            if let range = containingRange(location, in: codeRanges) {
                location = NSMaxRange(range)
                continue
            }
            guard source.character(at: location) == ASCII.openBracket,
                  !isEscaped(location, in: source) else {
                location += 1
                continue
            }

            let lineEnd = contentEndOfLine(containing: location, in: source)
            guard let labelEnd = matchingDelimiter(
                from: location,
                opening: ASCII.openBracket,
                closing: ASCII.closeBracket,
                before: lineEnd,
                in: source
            ), labelEnd + 1 < lineEnd,
                  source.character(at: labelEnd + 1)
                    == ASCII.openParenthesis else {
                location += 1
                continue
            }

            let destinationStart = labelEnd + 1
            let destinationEnd = matchingDelimiter(
                from: destinationStart,
                opening: ASCII.openParenthesis,
                closing: ASCII.closeParenthesis,
                before: lineEnd,
                in: source
            )
            let end = destinationEnd.map { $0 + 1 } ?? lineEnd
            spans.append(
                MarkdownStyleSpan(
                    range: NSRange(location: location, length: end - location),
                    role: .link
                )
            )
            location = max(end, location + 1)
        }
    }

    private struct EmphasisDelimiter {
        let marker: unichar
        let strength: Int
        let location: Int
    }

    /// Inline emphasis may cross a soft line break, but cannot match a
    /// delimiter in another paragraph or a separate supported block.
    private static func emphasisBlockBoundaries(
        in source: NSString,
        lines: [NSRange],
        spans: [MarkdownStyleSpan],
        fenced: [NSRange],
        tableLines: [NSRange]
    ) -> Set<Int> {
        var boundaries = Set(fenced.flatMap { [$0.location, NSMaxRange($0)] })
        for line in tableLines {
            boundaries.insert(line.location)
            boundaries.insert(NSMaxRange(line))
        }
        for line in lines {
            let end = contentEnd(for: line, in: source)
            if skipHorizontalWhitespace(from: line.location, before: end,
                                        in: source) == end {
                boundaries.insert(line.location)
            }
        }
        for span in spans {
            switch span.role {
            case .heading, .listMarker:
                let line = syntaxLineRange(containing: span.range, in: source)
                boundaries.insert(line.location)
                if case .heading = span.role {
                    // Reset before consuming the newline, so it becomes a
                    // neutral restart even if the heading has an open marker.
                    let end = NSMaxRange(line)
                    boundaries.insert(end > 0 && source.character(at: end - 1) == ASCII.lineFeed
                                      ? end - 1 : end)
                }
            default:
                break
            }
        }
        return boundaries
    }

    private static func appendEmphasisSpans(
        in source: NSString,
        excluding codeRanges: [NSRange],
        blockBoundaries: Set<Int>,
        spans: inout [MarkdownStyleSpan]
    ) -> (offsets: [Int], atEnd: Bool) {
        var restartOffsets = [0]
        var stack: [EmphasisDelimiter] = []
        var location = 0
        while location < source.length {
            if blockBoundaries.contains(location) {
                stack.removeAll(keepingCapacity: true)
            }
            if let range = containingRange(location, in: codeRanges) {
                location = NSMaxRange(range)
                if stack.isEmpty, location < source.length, location > 0,
                   source.character(at: location - 1) == ASCII.lineFeed {
                    restartOffsets.append(location)
                }
                continue
            }
            let marker = source.character(at: location)
            if marker == ASCII.lineFeed, stack.isEmpty {
                restartOffsets.append(location + 1)
            }
            guard marker == ASCII.asterisk || marker == ASCII.underscore,
                  !isEscaped(location, in: source) else {
                location += 1
                continue
            }

            let runLength = repeatedLength(of: marker, at: location, in: source)
            let previousIsWhitespace = location == 0
                || isWhitespace(source.character(at: location - 1))
            let next = location + runLength
            let nextIsWhitespace = next >= source.length
                || isWhitespace(source.character(at: next))
            let isInsideWord = marker == ASCII.underscore
                && location > 0 && next < source.length
                && isWordCharacter(at: location - 1, in: source)
                && isWordCharacter(at: next, in: source)
            let canOpen = !nextIsWhitespace && !isInsideWord
            let canClose = !previousIsWhitespace && !isInsideWord
            var remaining = runLength

            if canClose {
                for strength in delimiterStrengths(
                    for: runLength,
                    closing: true
                ) {
                    guard remaining >= strength,
                          let openerIndex = stack.lastIndex(where: {
                              $0.marker == marker && $0.strength == strength
                          }) else { continue }
                    let opener = stack.remove(at: openerIndex)
                    let closingEnd = location + (runLength - remaining)
                        + strength
                    spans.append(
                        MarkdownStyleSpan(
                            range: NSRange(
                                location: opener.location,
                                length: closingEnd - opener.location
                            ),
                            role: strength == 2 ? .strong : .emphasis
                        )
                    )
                    remaining -= strength
                }
            }

            if canOpen && remaining > 0 {
                let openerStart = location + (runLength - remaining)
                var offset = 0
                for strength in delimiterStrengths(
                    for: remaining,
                    closing: false
                ) {
                    stack.append(
                        EmphasisDelimiter(
                            marker: marker,
                            strength: strength,
                            location: openerStart + offset
                        )
                    )
                    offset += strength
                }
            }
            location += runLength
        }
        if blockBoundaries.contains(source.length) { stack.removeAll() }
        return (restartOffsets, stack.isEmpty)
    }

    private static func fontRuns(
        for spans: [MarkdownStyleSpan]
    ) -> [MarkdownFontRun] {
        let fontSpans = spans.filter { span in
            switch span.role {
            case .heading, .strong, .emphasis, .code:
                return true
            case .highlight, .strikethrough, .link, .listMarker,
                    .blockquote, .blockquoteMarker:
                return false
            }
        }
        let boundaries = Set(
            fontSpans.flatMap { span in
                [span.range.location, NSMaxRange(span.range)]
            }
        ).sorted()

        var runs: [MarkdownFontRun] = []
        var active: [MarkdownStyleSpan] = []
        var nextSpan = fontSpans.startIndex
        for (start, end) in zip(boundaries, boundaries.dropFirst()) {
            guard start < end else { continue }
            active.removeAll { NSMaxRange($0.range) <= start }
            while nextSpan < fontSpans.endIndex,
                  fontSpans[nextSpan].range.location <= start {
                active.append(fontSpans[nextSpan])
                nextSpan += 1
            }
            let range = NSRange(location: start, length: end - start)
            let style = fontStyle(for: active)
            guard !style.traits.isEmpty || style.headingLevel != nil else {
                continue
            }
            let run = MarkdownFontRun(
                range: range,
                traits: style.traits,
                headingLevel: style.headingLevel
            )

            if let previous = runs.last,
               previous.traits == run.traits,
               previous.headingLevel == run.headingLevel,
               NSMaxRange(previous.range) == run.range.location {
                runs[runs.count - 1] = MarkdownFontRun(
                    range: NSRange(
                        location: previous.range.location,
                        length: NSMaxRange(run.range) - previous.range.location
                    ),
                    traits: run.traits,
                    headingLevel: run.headingLevel
                )
            } else {
                runs.append(run)
            }
        }
        return runs
    }

    private static func fontStyle(
        for spans: [MarkdownStyleSpan]
    ) -> (traits: MarkdownFontTraits, headingLevel: Int?) {
        let codeRanges = spans.compactMap { span -> NSRange? in
            guard span.role == .code else { return nil }
            return span.range
        }
        var traits: MarkdownFontTraits = []
        var headingLevel: Int?
        for span in spans {
            let isSyntaxInsideCode = codeRanges.contains { codeRange in
                codeRange != span.range
                    && NSLocationInRange(span.range.location, codeRange)
                    && NSMaxRange(span.range) <= NSMaxRange(codeRange)
            }
            guard !isSyntaxInsideCode else { continue }

            switch span.role {
            case let .heading(level):
                traits.insert(.bold)
                headingLevel = min(headingLevel ?? level, level)
            case .strong:
                traits.insert(.bold)
            case .emphasis:
                traits.insert(.italic)
            case .code:
                traits.insert(.monospaced)
            case .highlight, .strikethrough, .link, .listMarker,
                    .blockquote, .blockquoteMarker:
                break
            }
        }
        return (traits, headingLevel)
    }

    private static func codeBlockParagraphs(
        in fencedRanges: [NSRange],
        lines: [NSRange],
        source: NSString
    ) -> [MarkdownParagraphRun] {
        var paragraphs: [MarkdownParagraphRun] = []
        var fenceIndex = fencedRanges.startIndex
        for line in lines {
            while fenceIndex < fencedRanges.endIndex,
                  NSMaxRange(fencedRanges[fenceIndex]) <= line.location {
                fenceIndex += 1
            }
            guard fenceIndex < fencedRanges.endIndex else { break }
            let fence = fencedRanges[fenceIndex]
            guard line.location >= fence.location,
                  line.location < NSMaxRange(fence) else { continue }
            paragraphs.append(MarkdownParagraphRun(
                range: paragraphRange(for: line, in: source),
                kind: .codeBlock,
                contentColumn: 0,
                contentPrefixRange: NSRange(
                    location: line.location,
                    length: 0
                )
            ))
        }
        return paragraphs
    }

    /// Recognizes top-level pipe tables. Container-nested tables remain raw
    /// Markdown until the editor has a container-aware block parser.
    private static func tableRanges(
        in source: NSString,
        lines: [NSRange],
        fenced: [NSRange]
    ) -> [MarkdownTable] {
        guard lines.count >= 2 else { return [] }
        var tables: [MarkdownTable] = []
        var index = 0
        while index + 1 < lines.count {
            let headerLine = lines[index]
            let delimiterLine = lines[index + 1]
            guard isTopLevelTableLine(headerLine, in: source),
                  !isNestedListContinuation(
                      at: index, lines: lines, source: source
                  ),
                  tableContentStart(delimiterLine, in: source) != nil,
                  !isContained(headerLine.location, in: fenced),
                  !isContained(delimiterLine.location, in: fenced),
                  let headerCells = tableCells(in: headerLine, source: source),
                  let delimiterCells = tableCells(
                      in: delimiterLine, source: source
                  ),
                  headerCells.cells.count == delimiterCells.cells.count,
                  headerCells.hasPipe || delimiterCells.hasPipe,
                  let alignments = delimiterAlignments(
                      delimiterCells.cells, in: source
                  ) else {
                index += 1
                continue
            }

            let header = MarkdownTableRow(
                range: completeLineRange(headerLine, in: source),
                cells: headerCells.cells
            )
            let delimiterRange = completeLineRange(delimiterLine, in: source)
            var rows: [MarkdownTableRow] = []
            index += 2
            while index < lines.count {
                let line = lines[index]
                guard isTopLevelTableLine(line, in: source),
                      !isContained(line.location, in: fenced),
                      let body = tableCells(in: line, source: source),
                      !body.cells.isEmpty else {
                    break
                }
                rows.append(MarkdownTableRow(
                    range: completeLineRange(line, in: source),
                    cells: body.cells
                ))
                index += 1
            }
            let end = rows.last.map { NSMaxRange($0.range) }
                ?? NSMaxRange(delimiterRange)
            tables.append(MarkdownTable(
                range: NSRange(
                    location: header.range.location,
                    length: end - header.range.location
                ),
                header: header,
                delimiterRange: delimiterRange,
                rows: rows,
                alignments: alignments
            ))
        }
        return tables
    }

    private static func isTopLevelTableLine(
        _ line: NSRange,
        in source: NSString
    ) -> Bool {
        let end = contentEnd(for: line, in: source)
        guard let location = tableContentStart(line, in: source),
              source.character(at: location) != ASCII.greaterThan,
              listMarker(at: location, lineEnd: end, in: source) == nil,
              !isHeadingLine(line, in: source),
              !isThematicBreakLine(line, in: source) else {
            return false
        }
        return true
    }

    private static func tableContentStart(
        _ line: NSRange, in source: NSString
    ) -> Int? {
        let end = contentEnd(for: line, in: source)
        var location = line.location
        while location < end, source.character(at: location) == ASCII.space {
            location += 1
        }
        guard location - line.location <= 3, location < end,
              source.character(at: location) != ASCII.tab else { return nil }
        return location
    }

    private static func isHeadingLine(
        _ line: NSRange,
        in source: NSString
    ) -> Bool {
        let end = contentEnd(for: line, in: source)
        let location = skipHorizontalWhitespace(
            from: line.location, before: end, in: source
        )
        guard location < end,
              source.character(at: location) == ASCII.hash else {
            return false
        }
        let count = repeatedLength(of: ASCII.hash, at: location, in: source)
        let after = location + count
        return count <= 6 && (after == end
            || isHorizontalWhitespace(source.character(at: after)))
    }

    private static func isThematicBreakLine(
        _ line: NSRange,
        in source: NSString
    ) -> Bool {
        let end = contentEnd(for: line, in: source)
        let start = skipHorizontalWhitespace(
            from: line.location, before: end, in: source
        )
        guard start < end else { return false }
        let marker = source.character(at: start)
        guard marker == ASCII.hyphen || marker == ASCII.asterisk
                || marker == ASCII.underscore else {
            return false
        }
        var count = 0
        for location in start..<end {
            let character = source.character(at: location)
            if character == marker {
                count += 1
            } else if !isHorizontalWhitespace(character) {
                return false
            }
        }
        return count >= 3
    }

    private static func isNestedListContinuation(
        at index: Int,
        lines: [NSRange],
        source: NSString
    ) -> Bool {
        let candidate = lines[index]
        let candidateIndent = skipHorizontalWhitespace(
            from: candidate.location,
            before: contentEnd(for: candidate, in: source),
            in: source
        ) - candidate.location
        guard candidateIndent > 0, index > 0 else { return false }
        for priorIndex in stride(from: index - 1, through: 0, by: -1) {
            let prior = lines[priorIndex]
            let end = contentEnd(for: prior, in: source)
            let content = skipHorizontalWhitespace(
                from: prior.location, before: end, in: source
            )
            if content == end { return false }
            let indent = content - prior.location
            if indent < candidateIndent {
                return listMarker(
                    at: content, lineEnd: end, in: source
                ) != nil
            }
        }
        return false
    }

    private static func tableCells(
        in line: NSRange,
        source: NSString
    ) -> (cells: [NSRange], hasPipe: Bool)? {
        let end = contentEnd(for: line, in: source)
        var start = skipHorizontalWhitespace(
            from: line.location, before: end, in: source
        )
        var contentEnd = end
        while contentEnd > start,
              isHorizontalWhitespace(source.character(at: contentEnd - 1)) {
            contentEnd -= 1
        }
        guard start < contentEnd else { return nil }

        var separators: [Int] = []
        for location in start..<contentEnd
        where source.character(at: location) == 124
            && !isEscaped(location, in: source) {
            separators.append(location)
        }
        let hasPipe = !separators.isEmpty
        if separators.first == start {
            start += 1
            separators.removeFirst()
        }
        if separators.last == contentEnd - 1 {
            contentEnd -= 1
            separators.removeLast()
        }
        var cells: [NSRange] = []
        var cellStart = start
        for separator in separators + [contentEnd] {
            var left = cellStart
            var right = separator
            while left < right,
                  isHorizontalWhitespace(source.character(at: left)) {
                left += 1
            }
            while right > left,
                  isHorizontalWhitespace(source.character(at: right - 1)) {
                right -= 1
            }
            cells.append(NSRange(location: left, length: right - left))
            cellStart = separator + 1
        }
        return (cells, hasPipe)
    }

    private static func delimiterAlignments(
        _ cells: [NSRange],
        in source: NSString
    ) -> [MarkdownTableAlignment]? {
        var result: [MarkdownTableAlignment] = []
        for cell in cells {
            let value = source.substring(with: cell)
            let left = value.hasPrefix(":")
            let right = value.hasSuffix(":")
            let dashes = value.trimmingCharacters(in: CharacterSet(
                charactersIn: ":"
            ))
            guard !dashes.isEmpty,
                  dashes.allSatisfy({ $0 == "-" }),
                  value.filter({ $0 == ":" }).count ==
                    (left ? 1 : 0) + (right ? 1 : 0) else {
                return nil
            }
            result.append(left && right ? .center : right ? .right : .left)
        }
        return result
    }

    private static func completeLineRange(
        _ line: NSRange,
        in source: NSString
    ) -> NSRange {
        let end = NSMaxRange(line)
        return NSRange(
            location: line.location,
            length: line.length + (end < source.length ? 1 : 0)
        )
    }

    private static func isHorizontalWhitespace(_ character: unichar) -> Bool {
        character == ASCII.space || character == ASCII.tab
    }

    private static func lineRanges(in source: NSString) -> [NSRange] {
        guard source.length > 0 else { return [] }
        var ranges: [NSRange] = []
        var start = 0
        while start < source.length {
            var end = start
            while end < source.length,
                  source.character(at: end) != ASCII.lineFeed {
                end += 1
            }
            ranges.append(NSRange(location: start, length: end - start))
            start = end + 1
        }
        return ranges
    }

    private static func openingFence(
        in source: NSString,
        line: NSRange
    ) -> (marker: unichar, length: Int)? {
        let end = contentEnd(for: line, in: source)
        var location = line.location
        while location < end,
              source.character(at: location) == ASCII.space,
              location - line.location < 4 {
            location += 1
        }
        guard location - line.location <= 3, location < end else { return nil }
        let marker = source.character(at: location)
        guard marker == ASCII.backtick || marker == ASCII.tilde else {
            return nil
        }
        let length = repeatedLength(of: marker, at: location, in: source)
        guard length >= 3 else { return nil }
        return (marker, length)
    }

    private static func isClosingFence(
        in source: NSString,
        line: NSRange,
        marker: unichar,
        minimumLength: Int
    ) -> Bool {
        let end = contentEnd(for: line, in: source)
        var location = line.location
        while location < end,
              source.character(at: location) == ASCII.space,
              location - line.location < 4 {
            location += 1
        }
        let length = repeatedLength(of: marker, at: location, in: source)
        guard location - line.location <= 3, length >= minimumLength else {
            return false
        }
        location += length
        while location < end,
              isWhitespace(source.character(at: location)) {
            location += 1
        }
        return location == end
    }

    private static func listMarker(
        at location: Int,
        lineEnd: Int,
        in source: NSString
    ) -> NSRange? {
        let character = source.character(at: location)
        if character == ASCII.hyphen || character == ASCII.plus
            || character == ASCII.asterisk {
            let end = location + 1
            guard end == lineEnd
                    || isWhitespace(source.character(at: end)) else {
                return nil
            }
            return NSRange(location: location, length: 1)
        }

        var end = location
        while end < lineEnd,
              source.character(at: end) >= ASCII.zero,
              source.character(at: end) <= ASCII.nine,
              end - location < 9 {
            end += 1
        }
        guard end > location, end < lineEnd,
              source.character(at: end) == ASCII.period else { return nil }
        let markerEnd = end + 1
        guard markerEnd == lineEnd
                || isWhitespace(source.character(at: markerEnd)) else {
            return nil
        }
        return NSRange(location: location, length: markerEnd - location)
    }

    private static func matchingDelimiter(
        from start: Int,
        opening: unichar,
        closing: unichar,
        before end: Int,
        in source: NSString
    ) -> Int? {
        var depth = 0
        var location = start
        while location < end {
            if isEscaped(location, in: source) {
                location += 1
                continue
            }
            let character = source.character(at: location)
            if character == opening {
                depth += 1
            } else if character == closing {
                depth -= 1
                if depth == 0 { return location }
            }
            location += 1
        }
        return nil
    }

    private static func delimiterStrengths(
        for length: Int,
        closing: Bool
    ) -> [Int] {
        var strengths = Array(repeating: 2, count: length / 2)
        if length.isMultiple(of: 2) { return strengths }
        if closing { strengths.insert(1, at: 0) }
        else { strengths.append(1) }
        return strengths
    }

    private static func repeatedLength(
        of character: unichar,
        at location: Int,
        in source: NSString
    ) -> Int {
        guard location < source.length,
              source.character(at: location) == character else { return 0 }
        var end = location + 1
        while end < source.length, source.character(at: end) == character {
            end += 1
        }
        return end - location
    }

    private static func isExactPair(
        of marker: unichar,
        at location: Int,
        in source: NSString
    ) -> Bool {
        guard repeatedLength(of: marker, at: location, in: source) == 2 else {
            return false
        }
        return location == 0 || source.character(at: location - 1) != marker
    }

    private static func containingRange(
        _ location: Int,
        in ranges: [NSRange]
    ) -> NSRange? {
        var low = ranges.startIndex
        var high = ranges.endIndex
        while low < high {
            let middle = low + (high - low) / 2
            let range = ranges[middle]
            if location < range.location {
                high = middle
            } else if location >= NSMaxRange(range) {
                low = middle + 1
            } else {
                return range
            }
        }
        return nil
    }

    private static func isContained(
        _ location: Int,
        in ranges: [NSRange]
    ) -> Bool {
        containingRange(location, in: ranges) != nil
    }

    private static func isEscaped(
        _ location: Int,
        in source: NSString
    ) -> Bool {
        var slashCount = 0
        var cursor = location
        while cursor > 0,
              source.character(at: cursor - 1) == ASCII.backslash {
            slashCount += 1
            cursor -= 1
        }
        return !slashCount.isMultiple(of: 2)
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func isWordCharacter(
        at location: Int,
        in source: NSString
    ) -> Bool {
        let range = source.rangeOfComposedCharacterSequence(at: location)
        return source.substring(with: range).unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
        }
    }

    private static func skipHorizontalWhitespace(
        from start: Int,
        before end: Int,
        in source: NSString
    ) -> Int {
        var location = start
        while location < end {
            let character = source.character(at: location)
            guard character == ASCII.space || character == ASCII.tab else {
                break
            }
            location += 1
        }
        return location
    }

    private static func paragraphRange(
        for line: NSRange,
        in source: NSString
    ) -> NSRange {
        let end = NSMaxRange(line)
        let includesLineFeed = end < source.length
            && source.character(at: end) == ASCII.lineFeed
        return NSRange(
            location: line.location,
            length: line.length + (includesLineFeed ? 1 : 0)
        )
    }

    private static func visualColumn(
        from start: Int,
        to end: Int,
        in source: NSString
    ) -> Int {
        var column = 0
        for location in start..<end {
            if source.character(at: location) == ASCII.tab {
                column += 4 - column % 4
            } else {
                column += 1
            }
        }
        return column
    }

    private static func contentEnd(for line: NSRange, in source: NSString) -> Int {
        var end = NSMaxRange(line)
        if end > line.location,
           source.character(at: end - 1) == ASCII.carriageReturn {
            end -= 1
        }
        return end
    }

    private static func contentEndOfLine(
        containing location: Int,
        in source: NSString
    ) -> Int {
        var end = location
        while end < source.length,
              source.character(at: end) != ASCII.lineFeed {
            end += 1
        }
        if end > location,
           source.character(at: end - 1) == ASCII.carriageReturn {
            return end - 1
        }
        return end
    }

}

private enum ASCII {
    static let tab: unichar = 9
    static let lineFeed: unichar = 10
    static let carriageReturn: unichar = 13
    static let space: unichar = 32
    static let hash: unichar = 35
    static let openParenthesis: unichar = 40
    static let closeParenthesis: unichar = 41
    static let asterisk: unichar = 42
    static let plus: unichar = 43
    static let hyphen: unichar = 45
    static let period: unichar = 46
    static let greaterThan: unichar = 62
    static let equals: unichar = 61
    static let zero: unichar = 48
    static let nine: unichar = 57
    static let openBracket: unichar = 91
    static let backslash: unichar = 92
    static let closeBracket: unichar = 93
    static let underscore: unichar = 95
    static let backtick: unichar = 96
    static let tilde: unichar = 126
}

extension String {
    func clampedSelection(_ selection: NSRange) -> NSRange {
        let utf16Length = (self as NSString).length
        guard selection.location != NSNotFound else {
            return NSRange(location: utf16Length, length: 0)
        }

        let location = min(max(0, selection.location), utf16Length)
        guard location < utf16Length else {
            return NSRange(location: utf16Length, length: 0)
        }
        guard selection.length > 0 else {
            let composedRange = (self as NSString)
                .rangeOfComposedCharacterSequence(at: location)
            return NSRange(location: composedRange.location, length: 0)
        }

        let (rawEnd, overflowed) = selection.location.addingReportingOverflow(
            selection.length
        )
        let end = min(max(location, overflowed ? utf16Length : rawEnd),
                      utf16Length)
        let rawRange = NSRange(location: location, length: end - location)
        return (self as NSString)
            .rangeOfComposedCharacterSequences(for: rawRange)
    }
}
