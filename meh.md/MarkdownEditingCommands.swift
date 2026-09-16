import Foundation

enum MarkdownEditingCommand: CaseIterable {
    case continueLine
    case indent
    case outdent
    case bold
    case italic
    case strikethrough
    case highlight
    case heading
    case link
    case inlineCode
    case codeBlock
}

struct MarkdownEditingChange: Equatable {
    let range: NSRange
    let replacement: String
    let selection: NSRange
}

enum MarkdownEditingRules {
    static func change(
        for command: MarkdownEditingCommand,
        text: String,
        selection: NSRange
    ) -> MarkdownEditingChange? {
        let source = text as NSString
        let selection = safeSelection(selection, in: source)

        switch command {
        case .continueLine:
            return continueLine(in: source, selection: selection)
        case .indent:
            return changeIndent(
                in: source,
                selection: selection,
                outdent: false
            )
        case .outdent:
            return changeIndent(
                in: source,
                selection: selection,
                outdent: true
            )
        case .bold:
            return emphasisChange(
                strength: 2,
                in: source,
                selection: selection
            )
        case .italic:
            return emphasisChange(
                strength: 1,
                in: source,
                selection: selection
            )
        case .strikethrough:
            return pairedInlineChange(
                marker: "~~",
                in: source,
                selection: selection
            )
        case .highlight:
            return pairedInlineChange(
                marker: "==",
                in: source,
                selection: selection
            )
        case .heading:
            return headingChange(in: source, selection: selection)
        case .link:
            return linkChange(in: source, selection: selection)
        case .inlineCode:
            return inlineCodeChange(in: source, selection: selection)
        case .codeBlock:
            return codeBlockChange(in: source, selection: selection)
        }
    }

    private static func continueLine(
        in source: NSString,
        selection: NSRange
    ) -> MarkdownEditingChange {
        guard selection.length == 0,
              !isInCode(selection, source: source) else {
            return insertion("\n", replacing: selection)
        }

        let line = contentLine(containing: selection.location, in: source)
        let prefix = containerPrefix(in: source, line: line)
        guard !prefix.containers.isEmpty || !prefix.indentation.isEmpty else {
            return insertion("\n", replacing: selection)
        }
        guard selection.location >= prefix.contentStart else {
            return insertion("\n", replacing: selection)
        }

        let content = NSRange(
            location: prefix.contentStart,
            length: NSMaxRange(line) - prefix.contentStart
        )
        if source.substring(with: content)
            .trimmingCharacters(in: .whitespaces).isEmpty,
           let innermost = prefix.containers.last {
            var indentation = prefix.indentation
            let remaining: String
            if innermost.isList, !indentation.isEmpty {
                indentation = removingIndentLevel(from: indentation)
                remaining = prefix.containers.map(\.source).joined()
            } else {
                remaining = prefix.containers.dropLast()
                    .map(\.source).joined()
            }
            let replacement = indentation + remaining
            return MarkdownEditingChange(
                range: line,
                replacement: replacement,
                selection: NSRange(
                    location: line.location + replacement.utf16.count,
                    length: 0
                )
            )
        }

        let continuation = prefix.indentation
            + prefix.containers.map(\.continuation).joined()
        return insertion("\n" + continuation, replacing: selection)
    }

    private static func insertion(
        _ replacement: String,
        replacing range: NSRange
    ) -> MarkdownEditingChange {
        MarkdownEditingChange(
            range: range,
            replacement: replacement,
            selection: NSRange(
                location: range.location + replacement.utf16.count,
                length: 0
            )
        )
    }

    private static func changeIndent(
        in source: NSString,
        selection: NSRange,
        outdent: Bool
    ) -> MarkdownEditingChange? {
        guard !isInCode(selection, source: source) else { return nil }
        let affected = affectedLines(for: selection, in: source)
        let lines = lines(in: affected, source: source)
        var edits: [SourceEdit] = []

        for line in lines {
            if outdent {
                let removal = indentationRemoval(at: line.location, in: source)
                if removal > 0 {
                    edits.append(
                        SourceEdit(
                            range: NSRange(location: line.location, length: removal),
                            replacement: ""
                        )
                    )
                }
            } else {
                let contentLine = contentLine(containing: line.location, in: source)
                let prefix = containerPrefix(in: source, line: contentLine)
                let content = NSRange(
                    location: prefix.contentStart,
                    length: NSMaxRange(contentLine) - prefix.contentStart
                )
                let isEmptyQuotedList = prefix.containers.contains(where: \.isList)
                    && prefix.containers.contains(where: \.isQuote)
                    && source.substring(with: content)
                        .trimmingCharacters(in: .whitespaces).isEmpty
                if isEmptyQuotedList {
                    let replacement = "  " + prefix.indentation
                        + prefix.containers
                            .filter { !$0.isQuote }
                            .map(\.source).joined()
                    edits.append(
                        SourceEdit(
                            range: NSRange(
                                location: contentLine.location,
                                length: prefix.contentStart - contentLine.location
                            ),
                            replacement: replacement
                        )
                    )
                } else {
                    edits.append(
                        SourceEdit(
                            range: NSRange(location: line.location, length: 0),
                            replacement: "  "
                        )
                    )
                }
            }
        }
        guard !edits.isEmpty else { return nil }
        return applying(edits, to: affected, selection: selection, source: source)
    }

    private static func headingChange(
        in source: NSString,
        selection: NSRange
    ) -> MarkdownEditingChange? {
        guard !isInCode(selection, source: source) else { return nil }
        let affected = affectedLines(for: selection, in: source)
        let candidates = lines(in: affected, source: source).compactMap { line in
            headingCandidate(
                in: line,
                source: source,
                allowEmpty: selection.length == 0
            )
        }
        guard !candidates.isEmpty else { return nil }
        let removeHeading = candidates.allSatisfy { $0.level == 2 }
        let edits = candidates.map { candidate in
            if removeHeading {
                return SourceEdit(range: candidate.markerRange, replacement: "")
            }
            return SourceEdit(range: candidate.markerRange, replacement: "## ")
        }
        return applying(edits, to: affected, selection: selection, source: source)
    }

    private static func pairedInlineChange(
        marker: String,
        in source: NSString,
        selection: NSRange
    ) -> MarkdownEditingChange? {
        guard !isInCode(selection, source: source) else { return nil }
        let markerLength = marker.utf16.count
        if selection.length == 0 {
            return MarkdownEditingChange(
                range: selection,
                replacement: marker + marker,
                selection: NSRange(
                    location: selection.location + markerLength,
                    length: 0
                )
            )
        }

        if let wrapped = wrappedSelection(
            selection,
            marker: marker,
            source: source
        ) {
            return unwrapping(wrapped, markerLength: markerLength, source: source)
        }
        let selected = source.substring(with: selection)
        if containsLineBreak(selected) {
            let replacement = transformLines(in: selected) { line in
                guard !line.isEmpty else { return line }
                if hasExactWrapper(line, marker: marker) {
                    return String(
                        line.dropFirst(marker.count).dropLast(marker.count)
                    )
                }
                return marker + line + marker
            }
            return MarkdownEditingChange(
                range: selection,
                replacement: replacement,
                selection: NSRange(
                    location: selection.location,
                    length: replacement.utf16.count
                )
            )
        }

        if hasExactWrapper(selected, marker: marker) {
            let inner = String(
                selected.dropFirst(marker.count).dropLast(marker.count)
            )
            return MarkdownEditingChange(
                range: selection,
                replacement: inner,
                selection: NSRange(
                    location: selection.location,
                    length: inner.utf16.count
                )
            )
        }

        let replacement = marker + selected + marker
        return MarkdownEditingChange(
            range: selection,
            replacement: replacement,
            selection: NSRange(
                location: selection.location + markerLength,
                length: selection.length
            )
        )
    }

    private static func emphasisChange(
        strength: Int,
        in source: NSString,
        selection: NSRange
    ) -> MarkdownEditingChange? {
        guard !isInCode(selection, source: source) else { return nil }
        if selection.length == 0 {
            let marker = String(repeating: "*", count: strength)
            return MarkdownEditingChange(
                range: selection,
                replacement: marker + marker,
                selection: NSRange(
                    location: selection.location + strength,
                    length: 0
                )
            )
        }

        if let change = emphasisChangeForSurroundingRun(
            strength: strength,
            source: source,
            selection: selection
        ) {
            return change
        }
        if let change = emphasisChangeForSelectedRun(
            strength: strength,
            source: source,
            selection: selection
        ) {
            return change
        }

        let marker = String(repeating: "*", count: strength)
        let selected = source.substring(with: selection)
        if containsLineBreak(selected) {
            let replacement = transformLines(in: selected) { line in
                line.isEmpty ? line : marker + line + marker
            }
            return MarkdownEditingChange(
                range: selection,
                replacement: replacement,
                selection: NSRange(
                    location: selection.location,
                    length: replacement.utf16.count
                )
            )
        }
        return MarkdownEditingChange(
            range: selection,
            replacement: marker + selected + marker,
            selection: NSRange(
                location: selection.location + strength,
                length: selection.length
            )
        )
    }

    private static func inlineCodeChange(
        in source: NSString,
        selection: NSRange
    ) -> MarkdownEditingChange? {
        if selection.length > 0,
           let span = inlineCodeSpan(containing: selection, in: source),
           let content = inlineCodeContent(in: span, source: source) {
            return MarkdownEditingChange(
                range: span,
                replacement: content,
                selection: NSRange(
                    location: span.location,
                    length: content.utf16.count
                )
            )
        }
        if selection.length == 0 {
            guard !isInCode(selection, source: source) else { return nil }
        } else {
            let containedInCode = MarkdownSyntax.spans(in: source as String)
                .contains { span in
                    guard span.role == .code,
                          selection.location >= span.range.location,
                          NSMaxRange(selection) <= NSMaxRange(span.range) else {
                        return false
                    }
                    return !isEntireUnclosedInlineSelection(
                        selection,
                        span: span.range,
                        source: source
                    )
                }
            guard !containedInCode else { return nil }
        }
        if selection.length == 0 {
            return MarkdownEditingChange(
                range: selection,
                replacement: "``",
                selection: NSRange(location: selection.location + 1, length: 0)
            )
        }

        let selected = source.substring(with: selection)
        if containsLineBreak(selected) {
            let replacement = transformLines(in: selected) { line in
                line.isEmpty ? line : inlineCodeWrapping(line)
            }
            return MarkdownEditingChange(
                range: selection,
                replacement: replacement,
                selection: NSRange(
                    location: selection.location,
                    length: replacement.utf16.count
                )
            )
        }
        let replacement = inlineCodeWrapping(selected)
        let markerLength = max(1, longestRun(of: 96, in: selected as NSString) + 1)
        let padding = needsCodePadding(selected) ? 1 : 0
        return MarkdownEditingChange(
            range: selection,
            replacement: replacement,
            selection: NSRange(
                location: selection.location + markerLength + padding,
                length: selection.length
            )
        )
    }

    private static func linkChange(
        in source: NSString,
        selection: NSRange
    ) -> MarkdownEditingChange? {
        guard !isInCode(selection, source: source) else { return nil }
        if let link = containingLink(selection, in: source) {
            return MarkdownEditingChange(
                range: NSRange(location: selection.location, length: 0),
                replacement: "",
                selection: link.destination
            )
        }
        guard !containsLineBreak(source.substring(with: selection)) else {
            return nil
        }
        let label = escapedLinkLabel(source.substring(with: selection))
        let replacement = "[\(label)](https://)"
        return MarkdownEditingChange(
            range: selection,
            replacement: replacement,
            selection: NSRange(
                location: selection.location + label.utf16.count + 3,
                length: 8
            )
        )
    }

    private static func codeBlockChange(
        in source: NSString,
        selection: NSRange
    ) -> MarkdownEditingChange {
        if let block = fencedBlock(containing: selection, in: source) {
            let content = source.substring(with: block.content)
            return MarkdownEditingChange(
                range: block.whole,
                replacement: content,
                selection: NSRange(
                    location: block.whole.location,
                    length: content.utf16.count
                )
            )
        }
        if selection.length == 0 {
            return MarkdownEditingChange(
                range: selection,
                replacement: "```\n\n```",
                selection: NSRange(location: selection.location + 4, length: 0)
            )
        }

        let selected = source.substring(with: selection)
        let fenceLength = max(
            3,
            longestRun(of: 96, in: selected as NSString) + 1
        )
        let fence = String(repeating: "`", count: fenceLength)
        let replacement = fence + "\n" + selected + "\n" + fence
        return MarkdownEditingChange(
            range: selection,
            replacement: replacement,
            selection: NSRange(
                location: selection.location + fenceLength + 1,
                length: selection.length
            )
        )
    }
}

private extension MarkdownEditingRules {
    struct SourceEdit {
        let range: NSRange
        let replacement: String
    }

    struct Container {
        enum Kind {
            case bullet
            case ordered(number: String, delimiter: String, spacing: String)
            case quote
        }

        let kind: Kind
        let source: String

        var isList: Bool {
            switch kind {
            case .bullet, .ordered:
                return true
            case .quote:
                return false
            }
        }

        var isQuote: Bool {
            if case .quote = kind { return true }
            return false
        }

        var continuation: String {
            switch kind {
            case .bullet, .quote:
                return source
            case let .ordered(number, delimiter, spacing):
                return incrementDecimal(number) + delimiter + spacing
            }
        }
    }

    struct ParsedPrefix {
        let indentation: String
        let containers: [Container]
        let contentStart: Int
    }

    struct HeadingCandidate {
        let markerRange: NSRange
        let level: Int?
    }

    struct LinkRange {
        let whole: NSRange
        let destination: NSRange
    }

    struct FencedBlock {
        let whole: NSRange
        let content: NSRange
    }

    static func safeSelection(_ range: NSRange, in source: NSString) -> NSRange {
        let rawStart = min(range.location, source.length)
        let available = source.length - rawStart
        let rawLength = min(range.length, available)
        let start = composedBoundary(
            at: rawStart,
            forward: false,
            in: source
        )
        guard rawLength > 0 else {
            return NSRange(location: start, length: 0)
        }
        let rawEnd = rawStart + rawLength
        let end = composedBoundary(at: rawEnd, forward: true, in: source)
        return NSRange(location: start, length: end - start)
    }

    static func composedBoundary(
        at location: Int,
        forward: Bool,
        in source: NSString
    ) -> Int {
        guard location > 0 else { return 0 }
        guard location < source.length else { return source.length }
        let composed = source.rangeOfComposedCharacterSequence(at: location)
        guard composed.location != location else { return location }
        return forward ? NSMaxRange(composed) : composed.location
    }

    static func contentLine(containing location: Int, in source: NSString) -> NSRange {
        var start = min(location, source.length)
        while start > 0, !isNewline(source.character(at: start - 1)) {
            start -= 1
        }
        var end = min(location, source.length)
        while end < source.length, !isNewline(source.character(at: end)) {
            end += 1
        }
        return NSRange(location: start, length: end - start)
    }

    static func affectedLines(for selection: NSRange, in source: NSString) -> NSRange {
        let first = contentLine(containing: selection.location, in: source)
        let selectionEnd = NSMaxRange(selection)
        let lastLocation: Int
        if selection.length > 0, selectionEnd > selection.location {
            lastLocation = selectionEnd - 1
        } else {
            lastLocation = selection.location
        }
        let last = contentLine(containing: lastLocation, in: source)
        let end = lineBreakEnd(after: NSMaxRange(last), in: source)
        return NSRange(location: first.location, length: end - first.location)
    }

    static func lines(in range: NSRange, source: NSString) -> [NSRange] {
        if range.length == 0 {
            return [range]
        }
        var result: [NSRange] = []
        var location = range.location
        let end = NSMaxRange(range)
        while location < end {
            let content = contentLine(containing: location, in: source)
            let fullEnd = min(lineBreakEnd(after: NSMaxRange(content), in: source), end)
            result.append(
                NSRange(location: content.location, length: fullEnd - content.location)
            )
            location = fullEnd
        }
        return result
    }

    static func lineBreakEnd(after contentEnd: Int, in source: NSString) -> Int {
        guard contentEnd < source.length else { return contentEnd }
        let character = source.character(at: contentEnd)
        if character == 13, contentEnd + 1 < source.length,
           source.character(at: contentEnd + 1) == 10 {
            return contentEnd + 2
        }
        return isNewline(character) ? contentEnd + 1 : contentEnd
    }

    static func containerPrefix(in source: NSString, line: NSRange) -> ParsedPrefix {
        let end = NSMaxRange(line)
        var location = line.location
        while location < end, isHorizontalWhitespace(source.character(at: location)) {
            location += 1
        }
        let indentation = source.substring(
            with: NSRange(location: line.location, length: location - line.location)
        )
        var containers: [Container] = []

        while location < end {
            let markerStart = location
            if source.character(at: location) == 62 {
                location += 1
                while location < end,
                      isHorizontalWhitespace(source.character(at: location)) {
                    location += 1
                }
                containers.append(
                    Container(
                        kind: .quote,
                        source: source.substring(
                            with: NSRange(
                                location: markerStart,
                                length: location - markerStart
                            )
                        )
                    )
                )
                continue
            }

            let marker = source.character(at: location)
            if marker == 42 || marker == 45 || marker == 43,
               location + 1 == end
                || isHorizontalWhitespace(source.character(at: location + 1)) {
                location += 1
                while location < end,
                      isHorizontalWhitespace(source.character(at: location)) {
                    location += 1
                }
                containers.append(
                    Container(
                        kind: .bullet,
                        source: source.substring(
                            with: NSRange(
                                location: markerStart,
                                length: location - markerStart
                            )
                        )
                    )
                )
                continue
            }

            var numberEnd = location
            while numberEnd < end, isDigit(source.character(at: numberEnd)) {
                numberEnd += 1
            }
            if numberEnd > location, numberEnd < end,
               source.character(at: numberEnd) == 46
                || source.character(at: numberEnd) == 41 {
                let delimiterEnd = numberEnd + 1
                if delimiterEnd == end
                    || isHorizontalWhitespace(source.character(at: delimiterEnd)) {
                    location = delimiterEnd
                    while location < end,
                          isHorizontalWhitespace(source.character(at: location)) {
                        location += 1
                    }
                    let number = source.substring(
                        with: NSRange(
                            location: markerStart,
                            length: numberEnd - markerStart
                        )
                    )
                    let delimiter = source.substring(
                        with: NSRange(location: numberEnd, length: 1)
                    )
                    let spacing = source.substring(
                        with: NSRange(
                            location: delimiterEnd,
                            length: location - delimiterEnd
                        )
                    )
                    containers.append(
                        Container(
                            kind: .ordered(
                                number: number,
                                delimiter: delimiter,
                                spacing: spacing
                            ),
                            source: source.substring(
                                with: NSRange(
                                    location: markerStart,
                                    length: location - markerStart
                                )
                            )
                        )
                    )
                    continue
                }
            }
            break
        }
        return ParsedPrefix(
            indentation: indentation,
            containers: containers,
            contentStart: location
        )
    }

    static func headingCandidate(
        in fullLine: NSRange,
        source: NSString,
        allowEmpty: Bool
    ) -> HeadingCandidate? {
        let line = contentLine(containing: fullLine.location, in: source)
        let prefix = containerPrefix(in: source, line: line)
        guard prefix.contentStart < NSMaxRange(line) else {
            guard allowEmpty else { return nil }
            return HeadingCandidate(
                markerRange: NSRange(location: prefix.contentStart, length: 0),
                level: nil
            )
        }
        var markerEnd = prefix.contentStart
        while markerEnd < NSMaxRange(line),
              source.character(at: markerEnd) == 35,
              markerEnd - prefix.contentStart < 6 {
            markerEnd += 1
        }
        let level = markerEnd - prefix.contentStart
        if level > 0,
           markerEnd == NSMaxRange(line)
            || isHorizontalWhitespace(source.character(at: markerEnd)) {
            var end = markerEnd
            if end < NSMaxRange(line), isHorizontalWhitespace(source.character(at: end)) {
                end += 1
            }
            return HeadingCandidate(
                markerRange: NSRange(
                    location: prefix.contentStart,
                    length: end - prefix.contentStart
                ),
                level: level
            )
        }
        return HeadingCandidate(
            markerRange: NSRange(location: prefix.contentStart, length: 0),
            level: nil
        )
    }

    static func emphasisChangeForSurroundingRun(
        strength: Int,
        source: NSString,
        selection: NSRange
    ) -> MarkdownEditingChange? {
        let before = repeatedLengthBackward(
            of: 42,
            before: selection.location,
            in: source
        )
        let after = repeatedLength(
            of: 42,
            at: NSMaxRange(selection),
            in: source
        )
        guard before > 0, before == after else { return nil }
        let next = toggledEmphasisRun(before, strength: strength)
        let selected = source.substring(with: selection)
        let markers = String(repeating: "*", count: next)
        let whole = NSRange(
            location: selection.location - before,
            length: before + selection.length + after
        )
        return MarkdownEditingChange(
            range: whole,
            replacement: markers + selected + markers,
            selection: NSRange(
                location: whole.location + next,
                length: selection.length
            )
        )
    }

    static func emphasisChangeForSelectedRun(
        strength: Int,
        source: NSString,
        selection: NSRange
    ) -> MarkdownEditingChange? {
        let selected = source.substring(with: selection) as NSString
        let opening = repeatedLength(of: 42, at: 0, in: selected)
        guard opening > 0 else { return nil }
        let closing = repeatedLengthBackward(
            of: 42,
            before: selected.length,
            in: selected
        )
        guard opening == closing, opening * 2 <= selected.length else {
            return nil
        }
        let contentRange = NSRange(
            location: opening,
            length: selected.length - opening - closing
        )
        let content = selected.substring(with: contentRange)
        let next = toggledEmphasisRun(opening, strength: strength)
        let markers = String(repeating: "*", count: next)
        return MarkdownEditingChange(
            range: selection,
            replacement: markers + content + markers,
            selection: NSRange(
                location: selection.location + next,
                length: content.utf16.count
            )
        )
    }

    static func toggledEmphasisRun(_ count: Int, strength: Int) -> Int {
        if strength == 1 {
            return count == 2 ? 3 : max(0, count - 1)
        }
        return count == 1 ? 3 : max(0, count - 2)
    }

    static func wrappedSelection(
        _ selection: NSRange,
        marker: String,
        source: NSString
    ) -> NSRange? {
        let length = marker.utf16.count
        guard selection.location >= length,
              NSMaxRange(selection) + length <= source.length else {
            return nil
        }
        let opening = NSRange(location: selection.location - length, length: length)
        let closing = NSRange(location: NSMaxRange(selection), length: length)
        guard source.substring(with: opening) == marker,
              source.substring(with: closing) == marker,
              isExactDelimiter(opening, marker: marker, source: source),
              isExactDelimiter(closing, marker: marker, source: source) else {
            return nil
        }
        return NSRange(
            location: opening.location,
            length: NSMaxRange(closing) - opening.location
        )
    }

    static func unwrapping(
        _ range: NSRange,
        markerLength: Int,
        source: NSString
    ) -> MarkdownEditingChange {
        let inner = NSRange(
            location: range.location + markerLength,
            length: range.length - markerLength * 2
        )
        let replacement = source.substring(with: inner)
        return MarkdownEditingChange(
            range: range,
            replacement: replacement,
            selection: NSRange(
                location: range.location,
                length: replacement.utf16.count
            )
        )
    }

    static func hasExactWrapper(_ text: String, marker: String) -> Bool {
        guard text.utf16.count >= marker.utf16.count * 2,
              text.hasPrefix(marker), text.hasSuffix(marker) else {
            return false
        }
        if marker == "*" {
            return !text.hasPrefix("**") && !text.hasSuffix("**")
        }
        return true
    }

    static func isExactDelimiter(
        _ range: NSRange,
        marker: String,
        source: NSString
    ) -> Bool {
        guard marker.allSatisfy({ $0 == marker.first }) else { return true }
        guard let character = marker.utf16.first else { return true }
        let before = range.location - 1
        let after = NSMaxRange(range)
        if before >= 0, source.character(at: before) == character { return false }
        if after < source.length, source.character(at: after) == character { return false }
        return true
    }

    static func containingLink(_ selection: NSRange, in source: NSString) -> LinkRange? {
        let line = contentLine(containing: selection.location, in: source)
        var opening = line.location
        while opening < NSMaxRange(line) {
            guard source.character(at: opening) == 91,
                  !isEscaped(opening, in: source),
                  let labelEnd = findClosingBracket(
                      after: opening,
                      in: line,
                      source: source
                  ),
                  labelEnd + 1 < NSMaxRange(line),
                  source.character(at: labelEnd + 1) == 40,
                  let destinationEnd = findClosingParenthesis(
                      after: labelEnd + 1,
                      in: line,
                      source: source
                  ) else {
                opening += 1
                continue
            }
            let whole = NSRange(
                location: opening,
                length: destinationEnd + 1 - opening
            )
            let startsInside = selection.location >= whole.location
                && (selection.location < NSMaxRange(whole)
                    || selection.length > 0
                        && selection.location == NSMaxRange(whole))
            if startsInside, NSMaxRange(selection) <= NSMaxRange(whole) {
                return LinkRange(
                    whole: whole,
                    destination: NSRange(
                        location: labelEnd + 2,
                        length: destinationEnd - labelEnd - 2
                    )
                )
            }
            opening = destinationEnd + 1
        }
        return nil
    }

    static func findClosingBracket(
        after opening: Int,
        in line: NSRange,
        source: NSString
    ) -> Int? {
        var depth = 1
        var location = opening + 1
        while location < NSMaxRange(line) {
            if !isEscaped(location, in: source) {
                if source.character(at: location) == 91 {
                    depth += 1
                } else if source.character(at: location) == 93 {
                    depth -= 1
                    if depth == 0 { return location }
                }
            }
            location += 1
        }
        return nil
    }

    static func findUnescaped(
        _ character: unichar,
        after location: Int,
        in line: NSRange,
        source: NSString
    ) -> Int? {
        var candidate = location + 1
        while candidate < NSMaxRange(line) {
            if source.character(at: candidate) == character,
               !isEscaped(candidate, in: source) {
                return candidate
            }
            candidate += 1
        }
        return nil
    }

    static func escapedLinkLabel(_ label: String) -> String {
        var result = ""
        for character in label {
            if character == "\\" || character == "[" || character == "]" {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }

    static func inlineCodeSpan(
        containing selection: NSRange,
        in source: NSString
    ) -> NSRange? {
        MarkdownSyntax.spans(in: source as String).first { span in
            guard span.role == .code,
                  selection.location >= span.range.location,
                  NSMaxRange(selection) <= NSMaxRange(span.range),
                  !containsLineBreak(source.substring(with: span.range)) else {
                return false
            }
            return inlineCodeContent(in: span.range, source: source) != nil
        }?.range
    }

    static func inlineCodeContent(
        in range: NSRange,
        source: NSString
    ) -> String? {
        let raw = source.substring(with: range) as NSString
        guard raw.length > 1, raw.character(at: 0) == 96 else { return nil }
        let markerLength = repeatedLength(of: 96, at: 0, in: raw)
        guard raw.length >= markerLength * 2 else { return nil }
        let closing = NSRange(
            location: raw.length - markerLength,
            length: markerLength
        )
        let marker = String(repeating: "`", count: markerLength)
        guard raw.substring(with: closing) == marker else { return nil }
        var content = raw.substring(
            with: NSRange(
                location: markerLength,
                length: raw.length - markerLength * 2
            )
        )
        if content.hasPrefix(" "), content.hasSuffix(" "),
           !content.allSatisfy({ $0 == " " }) {
            content.removeFirst()
            content.removeLast()
        }
        return content
    }

    static func isEntireUnclosedInlineSelection(
        _ selection: NSRange,
        span: NSRange,
        source: NSString
    ) -> Bool {
        guard selection == span,
              !containsLineBreak(source.substring(with: span)),
              source.character(at: span.location) == 96 else {
            return false
        }
        let markerLength = repeatedLength(
            of: 96,
            at: span.location,
            in: source
        )
        return markerLength < 3
            && inlineCodeContent(in: span, source: source) == nil
    }

    static func inlineCodeWrapping(_ content: String) -> String {
        let markerLength = max(
            1,
            longestRun(of: 96, in: content as NSString) + 1
        )
        let marker = String(repeating: "`", count: markerLength)
        let padding = needsCodePadding(content) ? " " : ""
        return marker + padding + content + padding + marker
    }

    static func needsCodePadding(_ content: String) -> Bool {
        guard let first = content.first, let last = content.last else {
            return false
        }
        return first == "`" || last == "`"
            || first.isWhitespace || last.isWhitespace
    }

    static func fencedBlock(
        containing selection: NSRange,
        in source: NSString
    ) -> FencedBlock? {
        for span in MarkdownSyntax.spans(in: source as String)
        where span.role == .code {
            let startsInside = selection.location >= span.range.location
                && (selection.location < NSMaxRange(span.range)
                    || selection.length > 0
                        && selection.location == NSMaxRange(span.range))
            guard startsInside,
                  NSMaxRange(selection) <= NSMaxRange(span.range),
                  let block = parseFencedBlock(span.range, in: source) else {
                continue
            }
            return block
        }
        return nil
    }

    static func parseFencedBlock(
        _ range: NSRange,
        in source: NSString
    ) -> FencedBlock? {
        let openingLine = contentLine(containing: range.location, in: source)
        var markerStart = openingLine.location
        while markerStart < NSMaxRange(openingLine),
              markerStart - openingLine.location < 4,
              source.character(at: markerStart) == 32 {
            markerStart += 1
        }
        guard markerStart < NSMaxRange(openingLine) else { return nil }
        let marker = source.character(at: markerStart)
        guard marker == 96 || marker == 126 else { return nil }
        let markerLength = repeatedLength(
            of: marker,
            at: markerStart,
            in: source
        )
        guard markerLength >= 3 else { return nil }

        let contentStart = lineBreakEnd(after: NSMaxRange(openingLine), in: source)
        var location = contentStart
        while location < NSMaxRange(range) {
            let line = contentLine(containing: location, in: source)
            if isClosingFence(
                line: line,
                marker: marker,
                minimumLength: markerLength,
                source: source
            ) {
                var contentEnd = line.location
                if contentEnd > contentStart,
                   source.character(at: contentEnd - 1) == 10 {
                    contentEnd -= 1
                    if contentEnd > contentStart,
                       source.character(at: contentEnd - 1) == 13 {
                        contentEnd -= 1
                    }
                } else if contentEnd > contentStart,
                          source.character(at: contentEnd - 1) == 13 {
                    contentEnd -= 1
                }
                return FencedBlock(
                    whole: NSRange(
                        location: range.location,
                        length: NSMaxRange(line) - range.location
                    ),
                    content: NSRange(
                        location: contentStart,
                        length: contentEnd - contentStart
                    )
                )
            }
            let next = lineBreakEnd(after: NSMaxRange(line), in: source)
            guard next > location else { break }
            location = next
        }
        return nil
    }

    static func findClosingParenthesis(
        after opening: Int,
        in line: NSRange,
        source: NSString
    ) -> Int? {
        var depth = 1
        var location = opening + 1
        while location < NSMaxRange(line) {
            if !isEscaped(location, in: source) {
                if source.character(at: location) == 40 {
                    depth += 1
                } else if source.character(at: location) == 41 {
                    depth -= 1
                    if depth == 0 { return location }
                }
            }
            location += 1
        }
        return nil
    }

    static func isInCode(_ selection: NSRange, source: NSString) -> Bool {
        let spans = MarkdownSyntax.spans(in: source as String).filter {
            $0.role == .code
        }
        if selection.length == 0 {
            return spans.contains {
                guard selection.location >= $0.range.location else {
                    return false
                }
                if let block = parseFencedBlock($0.range, in: source),
                   selection.location >= NSMaxRange(block.whole) {
                    return false
                }
                return selection.location < NSMaxRange($0.range)
                    || selection.location == NSMaxRange($0.range)
                        && isOpenEndedCode($0.range, in: source)
            }
        }
        return spans.contains {
            NSIntersectionRange(selection, $0.range).length > 0
        }
    }

    static func isOpenEndedCode(_ range: NSRange, in source: NSString) -> Bool {
        guard range.length > 0 else { return false }
        let firstLine = contentLine(containing: range.location, in: source)
        var markerStart = firstLine.location
        while markerStart < NSMaxRange(firstLine),
              markerStart - firstLine.location < 4,
              source.character(at: markerStart) == 32 {
            markerStart += 1
        }
        if markerStart < NSMaxRange(firstLine) {
            let marker = source.character(at: markerStart)
            let openingLength = repeatedLength(
                of: marker,
                at: markerStart,
                in: source
            )
            if (marker == 96 || marker == 126), openingLength >= 3 {
                return parseFencedBlock(range, in: source) == nil
            }
        }

        let text = source.substring(with: range) as NSString
        let marker = text.character(at: 0)
        guard marker == 96 else { return false }
        let markerLength = repeatedLength(of: marker, at: 0, in: text)
        guard text.length >= markerLength * 2 else { return true }
        let closing = NSRange(
            location: text.length - markerLength,
            length: markerLength
        )
        return text.substring(with: closing)
            != String(repeating: "`", count: markerLength)
    }

    static func isClosingFence(
        line: NSRange,
        marker: unichar,
        minimumLength: Int,
        source: NSString
    ) -> Bool {
        var location = line.location
        while location < NSMaxRange(line),
              location - line.location < 4,
              source.character(at: location) == 32 {
            location += 1
        }
        let markerLength = repeatedLength(
            of: marker,
            at: location,
            in: source
        )
        guard markerLength >= minimumLength else { return false }
        location += markerLength
        while location < NSMaxRange(line),
              isHorizontalWhitespace(source.character(at: location)) {
            location += 1
        }
        return location == NSMaxRange(line)
    }

    static func repeatedLength(
        of character: unichar,
        at location: Int,
        in source: NSString
    ) -> Int {
        var end = location
        while end < source.length, source.character(at: end) == character {
            end += 1
        }
        return end - location
    }

    static func repeatedLengthBackward(
        of character: unichar,
        before location: Int,
        in source: NSString
    ) -> Int {
        var start = location
        while start > 0, source.character(at: start - 1) == character {
            start -= 1
        }
        return location - start
    }

    static func longestRun(of character: unichar, in source: NSString) -> Int {
        var longest = 0
        var location = 0
        while location < source.length {
            guard source.character(at: location) == character else {
                location += 1
                continue
            }
            let length = repeatedLength(of: character, at: location, in: source)
            longest = max(longest, length)
            location += length
        }
        return longest
    }

    static func applying(
        _ edits: [SourceEdit],
        to range: NSRange,
        selection: NSRange,
        source: NSString
    ) -> MarkdownEditingChange {
        let edits = edits.sorted { $0.range.location < $1.range.location }
        let replacement = NSMutableString()
        var location = range.location
        for edit in edits {
            if edit.range.location > location {
                replacement.append(
                    source.substring(
                        with: NSRange(
                            location: location,
                            length: edit.range.location - location
                        )
                    )
                )
            }
            replacement.append(edit.replacement)
            location = NSMaxRange(edit.range)
        }
        if location < NSMaxRange(range) {
            replacement.append(
                source.substring(
                    with: NSRange(
                        location: location,
                        length: NSMaxRange(range) - location
                    )
                )
            )
        }
        let mappedStart = mapped(selection.location, through: edits)
        let mappedEnd = mapped(NSMaxRange(selection), through: edits)
        return MarkdownEditingChange(
            range: range,
            replacement: replacement as String,
            selection: NSRange(
                location: mappedStart,
                length: max(0, mappedEnd - mappedStart)
            )
        )
    }

    static func mapped(_ original: Int, through edits: [SourceEdit]) -> Int {
        var delta = 0
        for edit in edits {
            guard original >= edit.range.location else { break }
            let replacementLength = edit.replacement.utf16.count
            if original <= NSMaxRange(edit.range) {
                return edit.range.location + delta + replacementLength
            }
            delta += replacementLength - edit.range.length
        }
        return original + delta
    }

    static func indentationRemoval(at location: Int, in source: NSString) -> Int {
        guard location < source.length else { return 0 }
        if source.character(at: location) == 9 { return 1 }
        var count = 0
        while count < 2, location + count < source.length,
              source.character(at: location + count) == 32 {
            count += 1
        }
        return count
    }

    static func removingIndentLevel(from indentation: String) -> String {
        if indentation.hasSuffix("\t") {
            return String(indentation.dropLast())
        }
        if indentation.hasSuffix("  ") {
            return String(indentation.dropLast(2))
        }
        if indentation.hasSuffix(" ") {
            return String(indentation.dropLast())
        }
        return indentation
    }

    static func incrementDecimal(_ number: String) -> String {
        var digits = Array(number.utf8)
        var carry: UInt8 = 1
        var index = digits.count
        while index > 0, carry > 0 {
            index -= 1
            let value = digits[index] - 48 + carry
            digits[index] = 48 + value % 10
            carry = value / 10
        }
        if carry > 0 { digits.insert(49, at: 0) }
        return String(decoding: digits, as: UTF8.self)
    }

    static func transformLines(
        in text: String,
        transform: (String) -> String
    ) -> String {
        let source = text as NSString
        var result = ""
        var start = 0
        var location = 0
        while location < source.length {
            guard isNewline(source.character(at: location)) else {
                location += 1
                continue
            }
            result += transform(
                source.substring(
                    with: NSRange(location: start, length: location - start)
                )
            )
            if source.character(at: location) == 13,
               location + 1 < source.length,
               source.character(at: location + 1) == 10 {
                result += "\r\n"
                location += 2
            } else {
                result += source.substring(
                    with: NSRange(location: location, length: 1)
                )
                location += 1
            }
            start = location
        }
        result += transform(
            source.substring(
                with: NSRange(location: start, length: source.length - start)
            )
        )
        return result
    }

    static func containsLineBreak(_ text: String) -> Bool {
        text.utf16.contains(10) || text.utf16.contains(13)
    }

    static func isEscaped(_ location: Int, in source: NSString) -> Bool {
        var precedingBackslashes = 0
        var cursor = location
        while cursor > 0, source.character(at: cursor - 1) == 92 {
            precedingBackslashes += 1
            cursor -= 1
        }
        return precedingBackslashes % 2 == 1
    }

    static func isHorizontalWhitespace(_ character: unichar) -> Bool {
        character == 32 || character == 9
    }

    static func isDigit(_ character: unichar) -> Bool {
        character >= 48 && character <= 57
    }

    static func isNewline(_ character: unichar) -> Bool {
        character == 10 || character == 13
    }
}
