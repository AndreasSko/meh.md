import Foundation

/// Plain text for one-line previews of a note, such as Recents rows,
/// widgets and search results.
///
/// It only deletes Markdown syntax (and folds whitespace), so a range in
/// the source, such as a search match, can be carried over to the result.
/// Code keeps its punctuation, and markers without a partner stay as text.
public enum MarkdownExcerpt {
    public static func plain(
        _ markdown: String,
        keeping range: NSRange? = nil
    ) -> (text: String, range: NSRange?) {
        let source = Array(markdown.utf16)
        var keep = [Bool](repeating: true, count: source.count)
        var output = source
        var inFence = false

        var lineStart = 0
        while lineStart <= source.count {
            var lineEnd = lineStart
            while lineEnd < source.count, source[lineEnd] != newline { lineEnd += 1 }
            let isFence = startsFence(source, lineStart, lineEnd)
            if isFence {
                inFence.toggle()
                delete(&keep, lineStart, lineEnd)
            } else if !inFence {
                cleanLine(source, lineStart, lineEnd, &keep, &output)
            }
            lineStart = lineEnd + 1
        }

        // Fold whitespace runs, including line breaks, into single spaces.
        var lastKeptIsSpace = true
        for index in source.indices where keep[index] {
            if isWhitespace(output[index]) {
                if lastKeptIsSpace {
                    keep[index] = false
                } else {
                    output[index] = space
                    lastKeptIsSpace = true
                }
            } else {
                lastKeptIsSpace = false
            }
        }
        if let last = source.indices.last(where: { keep[$0] }), output[last] == space {
            keep[last] = false
        }

        var kept: [UInt16] = []
        kept.reserveCapacity(source.count)
        // keptBefore[i]: kept units before source index i.
        var keptBefore = [Int](repeating: 0, count: source.count + 1)
        for index in source.indices {
            keptBefore[index] = kept.count
            if keep[index] { kept.append(output[index]) }
        }
        keptBefore[source.count] = kept.count

        let text = String(decoding: kept, as: UTF16.self)
        guard let range, range.location != NSNotFound,
              NSMaxRange(range) <= source.count else { return (text, nil) }
        let start = keptBefore[range.location]
        let end = keptBefore[NSMaxRange(range)]
        return (text, end > start ? NSRange(location: start, length: end - start) : nil)
    }

    // MARK: Lines

    private static func cleanLine(
        _ source: [UInt16], _ start: Int, _ end: Int,
        _ keep: inout [Bool], _ output: inout [UInt16]
    ) {
        var index = start
        while index < end, isWhitespace(source[index]) { index += 1 }

        if isTableSeparator(source, index, end) {
            delete(&keep, start, end)
            return
        }

        // Block markers can nest: "> - [ ] task", "## heading".
        var progressed = true
        while progressed, index < end {
            progressed = false
            if source[index] == greaterThan {
                let next = index + 1
                let length = next < end && source[next] == space ? 2 : 1
                delete(&keep, index, index + length)
                index += length
                progressed = true
            } else if let length = headingMarker(source, index, end) {
                delete(&keep, index, index + length)
                index += length
                progressed = true
            } else if let length = listMarker(source, index, end) {
                delete(&keep, index, index + length)
                index += length
                if let task = taskMarker(source, index, end) {
                    delete(&keep, index, index + task)
                    index += task
                }
                progressed = true
            }
            while index < end, isWhitespace(source[index]) { index += 1 }
        }

        if index < end, source[index] == pipe {
            for position in index..<end where source[position] == pipe {
                output[position] = space
            }
        }

        cleanInline(source, index, end, &keep)
    }

    private static func cleanInline(
        _ source: [UInt16], _ start: Int, _ end: Int, _ keep: inout [Bool]
    ) {
        var index = start
        while index < end {
            let unit = source[index]

            if unit == backtick {
                var ticks = 0
                while index + ticks < end, source[index + ticks] == backtick { ticks += 1 }
                if let close = find(source, run: backtick, count: ticks, from: index + ticks, to: end) {
                    delete(&keep, index, index + ticks)
                    delete(&keep, close, close + ticks)
                    index = close + ticks
                } else {
                    index += ticks
                }
                continue
            }

            if unit == openBracket, index + 1 < end, source[index + 1] == openBracket,
               let close = find(source, sequence: [closeBracket, closeBracket], from: index + 2, to: end) {
                delete(&keep, index, index + 2)
                if let bar = firstIndex(of: pipe, in: source, from: index + 2, to: close) {
                    delete(&keep, index + 2, bar + 1)
                }
                delete(&keep, close, close + 2)
                index = close + 2
                continue
            }

            if unit == openBracket || (unit == bang && index + 1 < end && source[index + 1] == openBracket) {
                let textStart = index + (unit == bang ? 2 : 1)
                // Only the first `]` can end the text; `[1] and [site](…)`
                // must not pair the first `[` with the second link.
                if let middle = firstIndex(of: closeBracket, in: source, from: textStart, to: end),
                   middle + 1 < end, source[middle + 1] == openParen,
                   let close = firstIndex(of: closeParen, in: source, from: middle + 2, to: end) {
                    delete(&keep, index, textStart)
                    delete(&keep, middle, close + 1)
                    cleanInline(source, textStart, middle, &keep)
                    index = close + 1
                    continue
                }
            }

            if let length = delimiterLength(source, index, end),
               let close = closingDelimiter(source, index, length, end) {
                delete(&keep, index, index + length)
                delete(&keep, close, close + length)
                cleanInline(source, index + length, close, &keep)
                index = close + length
                continue
            }

            index += 1
        }
    }

    // MARK: Markers

    private static func startsFence(_ source: [UInt16], _ start: Int, _ end: Int) -> Bool {
        var index = start
        while index < end, index - start < 4, source[index] == space { index += 1 }
        guard index + 2 < end else { return false }
        let unit = source[index]
        guard unit == backtick || unit == tilde else { return false }
        return source[index + 1] == unit && source[index + 2] == unit
    }

    private static func isTableSeparator(_ source: [UInt16], _ start: Int, _ end: Int) -> Bool {
        guard start < end else { return false }
        var dashes = 0
        for index in start..<end {
            switch source[index] {
            case dash: dashes += 1
            case pipe, colon, space, tab: continue
            default: return false
            }
        }
        return dashes >= 3 && source[start..<end].contains(pipe)
    }

    private static func headingMarker(_ source: [UInt16], _ start: Int, _ end: Int) -> Int? {
        var index = start
        while index < end, source[index] == hash, index - start < 6 { index += 1 }
        let level = index - start
        guard level > 0 else { return nil }
        if index == end { return level }
        return source[index] == space ? level + 1 : nil
    }

    private static func listMarker(_ source: [UInt16], _ start: Int, _ end: Int) -> Int? {
        guard start < end else { return nil }
        let unit = source[start]
        if unit == dash || unit == asterisk || unit == plus {
            return start + 1 < end && source[start + 1] == space ? 2 : nil
        }
        var index = start
        while index < end, isDigit(source[index]), index - start < 9 { index += 1 }
        guard index > start, index + 1 < end,
              source[index] == period || source[index] == closeParen,
              source[index + 1] == space else { return nil }
        return index + 2 - start
    }

    private static func taskMarker(_ source: [UInt16], _ start: Int, _ end: Int) -> Int? {
        guard start + 2 < end, source[start] == openBracket, source[start + 2] == closeBracket else {
            return nil
        }
        let mark = source[start + 1]
        guard mark == space || mark == lowerX || mark == upperX else { return nil }
        return start + 3 < end && source[start + 3] == space ? 4 : 3
    }

    /// `**`, `__`, `~~`, `==`, `*` or `_` that can open emphasis here.
    private static func delimiterLength(_ source: [UInt16], _ index: Int, _ end: Int) -> Int? {
        let unit = source[index]
        let doubled = index + 1 < end && source[index + 1] == unit
        let length: Int
        switch unit {
        case asterisk, underscore: length = doubled ? 2 : 1
        case tilde, equals: guard doubled else { return nil }; length = 2
        default: return nil
        }
        let after = index + length
        guard after < end, !isWhitespace(source[after]) else { return nil }
        if unit == underscore, index > 0, isWordCharacter(source[index - 1]) { return nil }
        return length
    }

    private static func closingDelimiter(
        _ source: [UInt16], _ open: Int, _ length: Int, _ end: Int
    ) -> Int? {
        let unit = source[open]
        var index = open + length + 1
        while index + length <= end {
            if (0..<length).allSatisfy({ source[index + $0] == unit }),
               !isWhitespace(source[index - 1]),
               index + length == end || source[index + length] != unit {
                if unit == underscore, index + length < end,
                   isWordCharacter(source[index + length]) {
                    index += 1
                    continue
                }
                return index
            }
            index += 1
        }
        return nil
    }

    // MARK: Helpers

    private static func delete(_ keep: inout [Bool], _ start: Int, _ end: Int) {
        guard start < end else { return }
        for index in start..<end { keep[index] = false }
    }

    private static func find(
        _ source: [UInt16], sequence: [UInt16], from start: Int, to end: Int
    ) -> Int? {
        guard start + sequence.count <= end else { return nil }
        for index in start...(end - sequence.count)
        where (0..<sequence.count).allSatisfy({ source[index + $0] == sequence[$0] }) {
            return index
        }
        return nil
    }

    private static func find(
        _ source: [UInt16], run unit: UInt16, count: Int, from start: Int, to end: Int
    ) -> Int? {
        var index = start
        while index < end {
            guard source[index] == unit else { index += 1; continue }
            var length = 0
            while index + length < end, source[index + length] == unit { length += 1 }
            if length == count { return index }
            index += length
        }
        return nil
    }

    private static func firstIndex(
        of unit: UInt16, in source: [UInt16], from start: Int, to end: Int
    ) -> Int? {
        guard start < end else { return nil }
        return (start..<end).first { source[$0] == unit }
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == space || unit == tab || unit == newline || unit == carriageReturn
    }

    private static func isDigit(_ unit: UInt16) -> Bool { unit >= 48 && unit <= 57 }

    private static func isWordCharacter(_ unit: UInt16) -> Bool {
        isDigit(unit) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit > 127
    }

    private static let space = UInt16(UInt8(ascii: " "))
    private static let tab = UInt16(UInt8(ascii: "\t"))
    private static let newline = UInt16(UInt8(ascii: "\n"))
    private static let carriageReturn = UInt16(UInt8(ascii: "\r"))
    private static let hash = UInt16(UInt8(ascii: "#"))
    private static let greaterThan = UInt16(UInt8(ascii: ">"))
    private static let dash = UInt16(UInt8(ascii: "-"))
    private static let asterisk = UInt16(UInt8(ascii: "*"))
    private static let plus = UInt16(UInt8(ascii: "+"))
    private static let underscore = UInt16(UInt8(ascii: "_"))
    private static let tilde = UInt16(UInt8(ascii: "~"))
    private static let equals = UInt16(UInt8(ascii: "="))
    private static let backtick = UInt16(UInt8(ascii: "`"))
    private static let pipe = UInt16(UInt8(ascii: "|"))
    private static let colon = UInt16(UInt8(ascii: ":"))
    private static let period = UInt16(UInt8(ascii: "."))
    private static let bang = UInt16(UInt8(ascii: "!"))
    private static let openBracket = UInt16(UInt8(ascii: "["))
    private static let closeBracket = UInt16(UInt8(ascii: "]"))
    private static let openParen = UInt16(UInt8(ascii: "("))
    private static let closeParen = UInt16(UInt8(ascii: ")"))
    private static let lowerX = UInt16(UInt8(ascii: "x"))
    private static let upperX = UInt16(UInt8(ascii: "X"))
}
