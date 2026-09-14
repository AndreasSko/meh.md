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

struct MarkdownSyntaxResult: Equatable {
    let spans: [MarkdownStyleSpan]
    let fontRuns: [MarkdownFontRun]
    let paragraphRuns: [MarkdownParagraphRun]
}

enum MarkdownSyntax {
    static func parse(_ text: String) -> MarkdownSyntaxResult {
        let source = text as NSString
        let fenced = fencedCodeRanges(in: source)
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
        var paragraphRuns = codeBlockParagraphs(
            in: fenced,
            lines: lines,
            source: source
        )
        appendLineSpans(
            in: source,
            excluding: codeRanges,
            spans: &spans,
            paragraphRuns: &paragraphRuns
        )
        appendLinkSpans(in: source, excluding: codeRanges, spans: &spans)
        appendEmphasisSpans(
            in: source,
            excluding: codeRanges,
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
        spans.sort { left, right in
            if left.range.location == right.range.location {
                return left.range.length > right.range.length
            }
            return left.range.location < right.range.location
        }
        return MarkdownSyntaxResult(
            spans: spans,
            fontRuns: fontRuns(for: spans),
            paragraphRuns: paragraphRuns
        )
    }

    static func spans(in text: String) -> [MarkdownStyleSpan] {
        parse(text).spans
    }

    static func fontRuns(in text: String) -> [MarkdownFontRun] {
        parse(text).fontRuns
    }

    private static func fencedCodeRanges(in source: NSString) -> [NSRange] {
        let lines = lineRanges(in: source)
        var ranges: [NSRange] = []
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
            lineIndex = (closingLineIndex ?? (lines.count - 1)) + 1
        }
        return ranges
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
        spans: inout [MarkdownStyleSpan],
        paragraphRuns: inout [MarkdownParagraphRun]
    ) {
        for line in lineRanges(in: source) {
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

    private static func appendEmphasisSpans(
        in source: NSString,
        excluding codeRanges: [NSRange],
        spans: inout [MarkdownStyleSpan]
    ) {
        var stack: [EmphasisDelimiter] = []
        var location = 0
        while location < source.length {
            if let range = containingRange(location, in: codeRanges) {
                location = NSMaxRange(range)
                continue
            }
            let marker = source.character(at: location)
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
