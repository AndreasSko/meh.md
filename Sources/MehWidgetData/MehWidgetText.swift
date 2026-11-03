import Foundation

/// Short labels for when a note last changed, such as "2 min" or "Mon".
public enum MehWidgetTime {
    public static func label(
        for date: Date, now: Date, compact: Bool,
        calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 60 * 60 {
            let minutes = Int(seconds / 60)
            return compact ? "\(minutes)m" : "\(minutes) min"
        }
        if calendar.isDate(date, inSameDayAs: now) || seconds < 6 * 60 * 60 {
            let hours = Int(seconds / 3_600)
            return compact ? "\(hours)h" : "\(hours) h"
        }
        let style = Date.FormatStyle(locale: locale, calendar: calendar)
        if seconds < 6 * 24 * 60 * 60 {
            return date.formatted(style.weekday(.abbreviated))
        }
        return date.formatted(style.day().month(.abbreviated))
    }

    /// When a label next changes, so the widget can refresh the times
    /// without asking the app.
    public static func refreshDates(from now: Date) -> [Date] {
        let minutes = stride(from: 1, through: 59, by: 1).map {
            now.addingTimeInterval(TimeInterval($0 * 60))
        }
        let hours = stride(from: 1, through: 12, by: 1).map {
            now.addingTimeInterval(TimeInterval($0 * 3_600))
        }
        return [now] + minutes + hours
    }
}

/// The few Markdown blocks a widget draws: enough to recognize a note,
/// not a second editor.
public enum MehWidgetMarkdown {
    public enum Block: Equatable, Sendable {
        case heading(String)
        case task(String, done: Bool)
        case bullet(String)
        case numbered(String, number: String)
        case quote(String)
        case paragraph(String)
    }

    public enum Span: Equatable, Sendable {
        case text(String)
        case highlight(String)
        case link(String)
    }

    public static func blocks(from text: String) -> [Block] {
        var blocks: [Block] = []
        var inCode = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inCode.toggle()
                continue
            }
            if line.isEmpty || isRule(line) { continue }
            if inCode {
                blocks.append(.paragraph(line))
                continue
            }
            blocks.append(block(for: line))
        }
        return blocks
    }

    private static func block(for line: String) -> Block {
        if let heading = line.firstMatch(of: /^#{1,6}\s+(.*)$/) {
            return .heading(String(heading.1))
        }
        if let task = line.firstMatch(of: /^[-*+]\s+\[([ xX])\]\s*(.*)$/) {
            return .task(String(task.2), done: task.1 != " ")
        }
        if let bullet = line.firstMatch(of: /^[-*+]\s+(.*)$/) {
            return .bullet(String(bullet.1))
        }
        if let item = line.firstMatch(of: /^(\d{1,9})[.)]\s+(.*)$/) {
            return .numbered(String(item.2), number: String(item.1))
        }
        if let quote = line.firstMatch(of: /^>\s?(.*)$/) {
            return .quote(String(quote.1))
        }
        return .paragraph(line)
    }

    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { !$0.isWhitespace }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else {
            return false
        }
        return marks.allSatisfy { $0 == first }
    }

    /// Splits `==highlights==` and `[[links]]` from the rest, which keeps
    /// its own inline Markdown such as emphasis.
    public static func spans(in text: String) -> [Span] {
        var spans: [Span] = []
        var rest = Substring(text)
        while let match = rest.firstMatch(of: /==(.+?)==|\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/) {
            if match.range.lowerBound > rest.startIndex {
                spans.append(.text(String(rest[rest.startIndex..<match.range.lowerBound])))
            }
            if let highlight = match.1 {
                spans.append(.highlight(String(highlight)))
            } else if let target = match.2 {
                spans.append(.link(String(match.3 ?? target)))
            }
            rest = rest[match.range.upperBound...]
        }
        if !rest.isEmpty { spans.append(.text(String(rest))) }
        return spans
    }
}
