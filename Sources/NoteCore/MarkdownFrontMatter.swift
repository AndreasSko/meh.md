import Foundation

/// YAML front matter at the top of a note, read only to display it as
/// rows of properties. It understands `key: value` lines, flow lists such
/// as `[a, b]`, and lists of `- item` lines below a key. Anything else,
/// such as nested maps, multi-line text, or comments, returns nil, so the
/// editor shows that YAML exactly as written.
public struct MarkdownFrontMatter: Equatable, Sendable {
    public struct Property: Equatable, Sendable {
        /// The key as written, such as `author`.
        public let key: String
        /// From the start of the line up to the value, colon and spaces
        /// included; the whole line when there is no value.
        public let keyRange: NSRange
        /// The line, or for a block list the key line and its item lines,
        /// without the final line break.
        public let lines: NSRange
        /// A plain value without its quotes.
        public let value: NSRange?
        /// List items without their quotes.
        public let items: [NSRange]
        /// Characters that only shape the YAML: quotes, brackets, and the
        /// `- ` before a block list item.
        public let syntax: [NSRange]
        /// The commas and spaces between items of a flow list.
        public let separators: [NSRange]
        /// The lines of a block list below the key, without line breaks.
        public let itemLines: [NSRange]

        /// The key with a capital first letter, such as `Author`, and
        /// common abbreviations in capitals, such as `URL`.
        public var label: String {
            if let abbreviation = Self.abbreviations[key.lowercased()] { return abbreviation }
            return key.prefix(1).uppercased() + key.dropFirst()
        }

        static let abbreviations = [
            "url": "URL", "uri": "URI", "id": "ID", "isbn": "ISBN", "asin": "ASIN", "doi": "DOI",
        ]
    }

    /// From the opening `---` through the closing line and its line break.
    public let range: NSRange
    /// The opening and closing lines, with their line breaks.
    public let opening: NSRange
    public let closing: NSRange
    public let properties: [Property]

    /// Front matter longer than `limit` UTF-16 units is left as written.
    public static func parse(_ source: NSString, limit: Int = 16_384) -> MarkdownFrontMatter? {
        guard source.length >= 3, source.character(at: 0) == hyphen else { return nil }
        let opening = source.lineRange(for: NSRange(location: 0, length: 0))
        guard content(of: opening, in: source) == "---" else { return nil }
        var body: [NSRange] = []
        var location = NSMaxRange(opening)
        var closing: NSRange?
        while location < source.length, location <= limit {
            let line = source.lineRange(for: NSRange(location: location, length: 0))
            let text = content(of: line, in: source)
            if text == "---" || text == "..." {
                closing = line
                break
            }
            body.append(line)
            location = NSMaxRange(line)
        }
        guard let closing, NSMaxRange(closing) <= limit + 4,
              let properties = parseProperties(body, in: source) else { return nil }
        return MarkdownFrontMatter(
            range: NSRange(location: 0, length: NSMaxRange(closing)),
            opening: opening, closing: closing, properties: properties
        )
    }

    private static let hyphen: unichar = 45

    /// A line's text without its line break and trailing spaces.
    private static func content(of line: NSRange, in source: NSString) -> String {
        var text = source.substring(with: line)
        while let last = text.last, last == "\n" || last == "\r" || last == " " || last == "\t" {
            text.removeLast()
        }
        return text
    }

    private static func trimmedEnd(_ line: NSRange, in source: NSString) -> Int {
        var end = NSMaxRange(line)
        while end > line.location, [10, 13, 32, 9].contains(source.character(at: end - 1)) { end -= 1 }
        return end
    }

    private static func parseProperties(_ lines: [NSRange], in source: NSString) -> [Property]? {
        var properties: [Property] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let end = trimmedEnd(line, in: source)
            guard end > line.location else { return nil }
            let first = source.character(at: line.location)
            // Indented lines belong to a key; comments and complex keys are
            // left as written.
            guard ![32, 9, 35, 45, 91, 123, 39, 34, 63, 38, 42, 33, 124, 62, 37, 64, 96].contains(first)
            else { return nil }
            var colon = line.location
            while colon < end, source.character(at: colon) != 58 { colon += 1 }
            guard colon < end, colon > line.location else { return nil }
            let afterColon = colon + 1
            guard afterColon >= end || [32, 9].contains(source.character(at: afterColon)) else { return nil }
            let key = source.substring(with: NSRange(location: line.location, length: colon - line.location))
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return nil }
            var valueStart = afterColon
            while valueStart < end, [32, 9].contains(source.character(at: valueStart)) { valueStart += 1 }
            let lineContent = NSRange(location: line.location, length: end - line.location)

            if valueStart >= end {
                // A key alone may start a list of `- item` lines.
                var items: [NSRange] = []
                var syntax: [NSRange] = []
                var itemLines: [NSRange] = []
                var next = index + 1
                while next < lines.count {
                    let itemLine = lines[next]
                    let itemEnd = trimmedEnd(itemLine, in: source)
                    var start = itemLine.location
                    while start < itemEnd, [32, 9].contains(source.character(at: start)) { start += 1 }
                    guard start < itemEnd, source.character(at: start) == hyphen,
                          start + 1 < itemEnd, [32, 9].contains(source.character(at: start + 1))
                    else { break }
                    // An item at the left edge is valid YAML, but an item
                    // must at least not look like a new key.
                    var itemStart = start + 1
                    while itemStart < itemEnd, [32, 9].contains(source.character(at: itemStart)) { itemStart += 1 }
                    guard let item = scalar(NSRange(location: itemStart, length: itemEnd - itemStart),
                                            in: source, inFlow: false) else { return nil }
                    syntax.append(NSRange(location: itemLine.location, length: itemStart - itemLine.location))
                    syntax.append(contentsOf: item.quotes)
                    items.append(item.value)
                    itemLines.append(NSRange(location: itemLine.location, length: itemEnd - itemLine.location))
                    next += 1
                }
                if next < lines.count {
                    // Anything else indented below the key is a nested map.
                    let following = lines[next]
                    let character = source.character(at: following.location)
                    if character == 32 || character == 9 { return nil }
                }
                let lastLine = itemLines.last ?? lineContent
                properties.append(Property(
                    key: key, keyRange: lineContent,
                    lines: NSRange(location: line.location, length: NSMaxRange(lastLine) - line.location),
                    value: nil, items: items, syntax: syntax, separators: [], itemLines: itemLines
                ))
                index = next
                continue
            }

            let valueRange = NSRange(location: valueStart, length: end - valueStart)
            let keyRange = NSRange(location: line.location, length: valueStart - line.location)
            let opener = source.character(at: valueStart)
            if opener == 124 || opener == 62 || opener == 123 || opener == 38 || opener == 42 { return nil }
            if opener == 91 {
                guard let list = flowList(valueRange, in: source) else { return nil }
                properties.append(Property(
                    key: key, keyRange: keyRange, lines: lineContent, value: nil,
                    items: list.items, syntax: list.syntax, separators: list.separators, itemLines: []
                ))
            } else {
                guard let value = scalar(valueRange, in: source, inFlow: false) else { return nil }
                properties.append(Property(
                    key: key, keyRange: keyRange, lines: lineContent, value: value.value,
                    items: [], syntax: value.quotes, separators: [], itemLines: []
                ))
            }
            index += 1
        }
        return properties
    }

    /// A plain or quoted scalar; quotes come back separately so they can
    /// be hidden. A quoted value with escapes, such as `'O''Brien'`, keeps
    /// its quotes, since hiding them would show the escapes as the value.
    /// Nil for anything that is more than one value.
    private static func scalar(
        _ range: NSRange, in source: NSString, inFlow: Bool
    ) -> (value: NSRange, quotes: [NSRange])? {
        guard range.length > 0 else { return nil }
        let first = source.character(at: range.location)
        let last = source.character(at: NSMaxRange(range) - 1)
        if first == 34 || first == 39 {
            guard range.length >= 2, last == first else { return nil }
            // The closing quote must be the only one, so `"a" "b"` stays raw.
            var location = range.location + 1
            var escaped = false
            while location < NSMaxRange(range) - 1 {
                let character = source.character(at: location)
                if character == 92, first == 34 { escaped = true; location += 2; continue }
                if character == first {
                    guard first == 39, location + 1 < NSMaxRange(range) - 1,
                          source.character(at: location + 1) == 39 else { return nil }
                    escaped = true
                    location += 2
                    continue
                }
                location += 1
            }
            guard location == NSMaxRange(range) - 1 else { return nil }
            if escaped { return (range, []) }
            return (NSRange(location: range.location + 1, length: range.length - 2),
                    [NSRange(location: range.location, length: 1),
                     NSRange(location: NSMaxRange(range) - 1, length: 1)])
        }
        // Collections, block scalars, anchors, aliases, tags and reserved
        // characters are more than a plain value.
        if [91, 123, 124, 62, 38, 42, 33, 63, 37, 64, 96].contains(first) { return nil }
        let text = source.substring(with: range)
        // `- a` is a nested list, `a: b` a map, and ` #` starts a comment.
        if text == "-" || text.hasPrefix("- ") || text.hasPrefix("-\t")
            || text.contains(": ") || text.contains(":\t") || text.hasSuffix(":")
            || text.contains(" #") { return nil }
        return (range, [])
    }

    private static func flowList(
        _ range: NSRange, in source: NSString
    ) -> (items: [NSRange], syntax: [NSRange], separators: [NSRange])? {
        guard range.length >= 2, source.character(at: NSMaxRange(range) - 1) == 93 else { return nil }
        var syntax = [NSRange(location: range.location, length: 1),
                      NSRange(location: NSMaxRange(range) - 1, length: 1)]
        var items: [NSRange] = []
        var separators: [NSRange] = []
        let innerEnd = NSMaxRange(range) - 1
        var location = range.location + 1
        var quote: unichar?
        var itemStart = location
        func finishItem(at end: Int) -> Bool {
            var start = itemStart
            var stop = end
            while start < stop, [32, 9].contains(source.character(at: start)) { start += 1 }
            while stop > start, [32, 9].contains(source.character(at: stop - 1)) { stop -= 1 }
            guard stop > start,
                  let item = scalar(NSRange(location: start, length: stop - start), in: source, inFlow: true)
            else { return false }
            items.append(item.value)
            syntax.append(contentsOf: item.quotes)
            return true
        }
        while location < innerEnd {
            let character = source.character(at: location)
            if let open = quote {
                if character == 92, open == 34 { location += 2; continue }
                if character == open { quote = nil }
                location += 1
                continue
            }
            if character == 34 || character == 39 { quote = character }
            if [91, 93, 123, 125].contains(character) { return nil }
            if character == 44 {
                guard finishItem(at: location) else { return nil }
                var separatorEnd = location + 1
                while separatorEnd < innerEnd, [32, 9].contains(source.character(at: separatorEnd)) {
                    separatorEnd += 1
                }
                separators.append(NSRange(location: location, length: separatorEnd - location))
                itemStart = separatorEnd
                location = separatorEnd
                continue
            }
            location += 1
        }
        guard quote == nil else { return nil }
        let rest = source.substring(with: NSRange(location: itemStart, length: innerEnd - itemStart))
        if rest.trimmingCharacters(in: .whitespaces).isEmpty {
            // `[]` has no items; a trailing comma is not valid.
            guard separators.isEmpty else { return nil }
        } else if !finishItem(at: innerEnd) {
            return nil
        }
        return (items, syntax, separators)
    }
}
