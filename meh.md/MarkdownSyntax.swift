import Foundation

enum MarkdownStyleRole: Equatable {
    case heading(level: Int)
    case strong
    case emphasis
    case code
    case link
    case listMarker
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
}

enum MarkdownSyntax {
    static func spans(in text: String) -> [MarkdownStyleSpan] {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var spans: [MarkdownStyleSpan] = []

        matches(
            pattern: #"(?m)^(#{1,6})(?=\s).*$"#,
            in: text,
            range: fullRange
        ).forEach { match in
            let markerRange = match.range(at: 1)
            spans.append(
                MarkdownStyleSpan(
                    range: match.range,
                    role: .heading(level: markerRange.length)
                )
            )
        }

        appendMatches(
            pattern: #"\*\*(?=\S).+?(?<=\S)\*\*|__(?=\S).+?(?<=\S)__"#,
            role: .strong,
            text: text,
            range: fullRange,
            spans: &spans
        )
        appendMatches(
            pattern: #"(?<!\*)\*(?!\*)(?=\S).+?(?<=\S)\*(?!\*)|(?<!_)_(?!_)(?=\S).+?(?<=\S)_(?!_)"#,
            role: .emphasis,
            text: text,
            range: fullRange,
            spans: &spans
        )
        appendMatches(
            pattern: #"`[^`\n]+`"#,
            role: .code,
            text: text,
            range: fullRange,
            spans: &spans
        )
        appendMatches(
            pattern: #"\[[^\]\n]+\]\([^\s)]+(?:\s+\"[^\"]*\")?\)"#,
            role: .link,
            text: text,
            range: fullRange,
            spans: &spans
        )

        matches(
            pattern: #"(?m)^\s*([-+*]|\d+\.)\s+"#,
            in: text,
            range: fullRange
        ).forEach { match in
            spans.append(
                MarkdownStyleSpan(
                    range: match.range(at: 1),
                    role: .listMarker
                )
            )
        }

        return spans.sorted {
            if $0.range.location == $1.range.location {
                return $0.range.length > $1.range.length
            }
            return $0.range.location < $1.range.location
        }
    }

    static func fontRuns(in text: String) -> [MarkdownFontRun] {
        let fontSpans = spans(in: text).filter { span in
            switch span.role {
            case .heading, .strong, .emphasis, .code:
                return true
            case .link, .listMarker:
                return false
            }
        }
        let boundaries = Set(
            fontSpans.flatMap { span in
                [span.range.location, NSMaxRange(span.range)]
            }
        ).sorted()

        var runs: [MarkdownFontRun] = []
        for (start, end) in zip(boundaries, boundaries.dropFirst()) {
            guard start < end else { continue }
            let coveredRange = NSRange(location: start, length: end - start)
            let coveringSpans = fontSpans.filter { span in
                span.range.location <= start && NSMaxRange(span.range) >= end
            }
            let traits = fontTraits(for: coveringSpans)
            guard !traits.isEmpty else { continue }

            if let previous = runs.last,
               previous.traits == traits,
               NSMaxRange(previous.range) == coveredRange.location {
                runs[runs.count - 1] = MarkdownFontRun(
                    range: NSRange(
                        location: previous.range.location,
                        length: NSMaxRange(coveredRange)
                            - previous.range.location
                    ),
                    traits: traits
                )
            } else {
                runs.append(
                    MarkdownFontRun(range: coveredRange, traits: traits)
                )
            }
        }
        return runs
    }

    private static func fontTraits(
        for spans: [MarkdownStyleSpan]
    ) -> MarkdownFontTraits {
        let codeRanges = spans.compactMap { span -> NSRange? in
            guard span.role == .code else { return nil }
            return span.range
        }
        var traits: MarkdownFontTraits = []

        for span in spans {
            let isSyntaxInsideCode = codeRanges.contains { codeRange in
                codeRange != span.range
                    && NSLocationInRange(span.range.location, codeRange)
                    && NSMaxRange(span.range) <= NSMaxRange(codeRange)
            }
            guard !isSyntaxInsideCode else { continue }

            switch span.role {
            case .heading, .strong:
                traits.insert(.bold)
            case .emphasis:
                traits.insert(.italic)
            case .code:
                traits.insert(.monospaced)
            case .link, .listMarker:
                break
            }
        }
        return traits
    }

    private static func appendMatches(
        pattern: String,
        role: MarkdownStyleRole,
        text: String,
        range: NSRange,
        spans: inout [MarkdownStyleSpan]
    ) {
        matches(pattern: pattern, in: text, range: range).forEach { match in
            spans.append(MarkdownStyleSpan(range: match.range, role: role))
        }
    }

    private static func matches(
        pattern: String,
        in text: String,
        range: NSRange
    ) -> [NSTextCheckingResult] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            assertionFailure("Invalid built-in Markdown expression")
            return []
        }

        return expression.matches(in: text, range: range)
    }
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
