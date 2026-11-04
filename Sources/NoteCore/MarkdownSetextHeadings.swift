import Foundation

/// A paragraph underlined with `=` (level 1) or `-` (level 2), following
/// CommonMark setext headings. The editor and heading links share this rule.
public struct MarkdownSetextHeading: Equatable, Sendable {
    /// Indices into the caller's lines.
    public let paragraph: Range<Int>
    public let underline: Int
    public let level: Int
}

public enum MarkdownSetextHeadings {
    /// `lines` holds each line's content range without its line break.
    /// Excluded lines, such as code, frontmatter, or tables, end a paragraph.
    /// Only top-level paragraphs count: a line after a list item or quote is
    /// a lazy continuation of that container, as in CommonMark. With
    /// `timeSums`, a time calculator note has no underline headings: its `=`
    /// lines ask for sums, and a heading would end the sum above it.
    public static func find(
        in source: NSString,
        lines: [NSRange],
        timeSums: Bool = false,
        isExcluded: (Int) -> Bool
    ) -> [MarkdownSetextHeading] {
        enum State { case none, paragraph(Int), container }
        guard !timeSums else { return [] }
        var state = State.none
        var headings: [MarkdownSetextHeading] = []
        for index in lines.indices {
            if isExcluded(index) { state = .none; continue }
            let line = lines[index]
            let (start, indent) = contentStart(of: line, in: source)
            if start == NSMaxRange(line) { state = .none; continue }
            if case let .paragraph(first) = state,
               let level = underlineLevel(of: line, in: source) {
                headings.append(MarkdownSetextHeading(
                    paragraph: first..<index, underline: index, level: level
                ))
                state = .none
                continue
            }
            // An indented line continues a paragraph, but cannot start one.
            if indent >= 4 {
                if case .paragraph = state {} else { state = .container }
                continue
            }
            if isThematicBreak(line, in: source) || isATXHeading(start, line, source) {
                state = .none
            } else if isContainerStart(start, line, source) {
                state = .container
            } else if case .none = state {
                state = .paragraph(index)
            }
        }
        return headings
    }

    /// A line of `=` or `-` under a paragraph. A single `-` is an empty list
    /// item instead, so starting a list under a line doesn't flash a heading.
    public static func underlineLevel(of line: NSRange, in source: NSString) -> Int? {
        let (start, indent) = contentStart(of: line, in: source)
        guard indent <= 3, start < NSMaxRange(line) else { return nil }
        let marker = source.character(at: start)
        guard marker == equals || marker == hyphen else { return nil }
        var end = start
        while end < NSMaxRange(line), source.character(at: end) == marker { end += 1 }
        var trailing = end
        while trailing < NSMaxRange(line), isSpace(source.character(at: trailing)) {
            trailing += 1
        }
        guard trailing == NSMaxRange(line) else { return nil }
        if marker == equals { return 1 }
        return end - start >= 2 ? 2 : nil
    }

    /// Three or more `-`, `*`, or `_`, optionally separated by spaces.
    public static func isThematicBreak(_ line: NSRange, in source: NSString) -> Bool {
        let (start, indent) = contentStart(of: line, in: source)
        guard indent <= 3, start < NSMaxRange(line) else { return false }
        let marker = source.character(at: start)
        guard marker == hyphen || marker == asterisk || marker == underscore else {
            return false
        }
        var count = 0
        for location in start..<NSMaxRange(line) {
            let character = source.character(at: location)
            if character == marker {
                count += 1
            } else if !isSpace(character) {
                return false
            }
        }
        return count >= 3
    }

    /// Whether the lines from `location` are plain paragraph lines that end
    /// in an underline, so they could turn a paragraph right above them
    /// into a heading. A partial reparse uses this to decide when it has to
    /// look further. Long runs count as reaching one, to stay on the safe side.
    public static func paragraphReachesUnderline(
        from location: Int, in source: NSString, lineLimit: Int = 256
    ) -> Bool {
        var start = location
        for _ in 0..<lineLimit {
            guard start < source.length else { return false }
            var end = start
            while end < source.length, source.character(at: end) != lineFeed { end += 1 }
            var contentEnd = end
            if contentEnd > start, source.character(at: contentEnd - 1) == carriageReturn {
                contentEnd -= 1
            }
            let line = NSRange(location: start, length: contentEnd - start)
            let (content, indent) = contentStart(of: line, in: source)
            if content == contentEnd { return false }
            if underlineLevel(of: line, in: source) != nil { return true }
            if indent < 4 {
                let character = source.character(at: content)
                var fence = content
                while fence < contentEnd, source.character(at: fence) == character { fence += 1 }
                let isFence = (character == backtick || character == tilde) && fence - content >= 3
                if isFence || isThematicBreak(line, in: source)
                    || isATXHeading(content, line, source)
                    || isContainerStart(content, line, source) {
                    return false
                }
            }
            start = end + 1
        }
        return true
    }

    private static func isATXHeading(_ start: Int, _ line: NSRange, _ source: NSString) -> Bool {
        var end = start
        while end < NSMaxRange(line), source.character(at: end) == hash { end += 1 }
        return end > start && end - start <= 6 && isBoundary(end, line, source)
    }

    private static func isContainerStart(_ start: Int, _ line: NSRange, _ source: NSString) -> Bool {
        let character = source.character(at: start)
        if character == greaterThan { return true }
        if character == hyphen || character == plus || character == asterisk {
            return isBoundary(start + 1, line, source)
        }
        var end = start
        while end < NSMaxRange(line), end - start < 9,
              (zero...nine).contains(source.character(at: end)) { end += 1 }
        guard end > start, end < NSMaxRange(line) else { return false }
        let delimiter = source.character(at: end)
        return (delimiter == period || delimiter == closingParenthesis)
            && isBoundary(end + 1, line, source)
    }

    private static func isBoundary(_ location: Int, _ line: NSRange, _ source: NSString) -> Bool {
        location == NSMaxRange(line) || isSpace(source.character(at: location))
    }

    /// The first non-space location and its column; a tab advances to the
    /// next multiple of four.
    private static func contentStart(of line: NSRange, in source: NSString) -> (Int, Int) {
        var location = line.location
        var column = 0
        while location < NSMaxRange(line) {
            let character = source.character(at: location)
            if character == space { column += 1 }
            else if character == tab { column += 4 - column % 4 }
            else { break }
            location += 1
        }
        return (location, column)
    }

    private static func isSpace(_ character: unichar) -> Bool {
        character == space || character == tab
    }

    private static let tab: unichar = 9
    private static let lineFeed: unichar = 10
    private static let carriageReturn: unichar = 13
    private static let backtick: unichar = 96
    private static let tilde: unichar = 126
    private static let space: unichar = 32
    private static let hash: unichar = 35
    private static let closingParenthesis: unichar = 41
    private static let asterisk: unichar = 42
    private static let plus: unichar = 43
    private static let hyphen: unichar = 45
    private static let period: unichar = 46
    private static let zero: unichar = 48
    private static let nine: unichar = 57
    private static let equals: unichar = 61
    private static let greaterThan: unichar = 62
    private static let underscore: unichar = 95
}
