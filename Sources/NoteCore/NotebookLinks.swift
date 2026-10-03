import Foundation

public enum NotebookLinkKind: String, Sendable, Equatable {
    case wiki, markdown
}

public struct NotebookLinkOccurrence: Sendable, Equatable {
    public let range: NSRange
    public let destinationRange: NSRange
    public let destination: String
    public let label: String?
    public let kind: NotebookLinkKind
    public let isEmbed: Bool

    public init(range: NSRange, destinationRange: NSRange, destination: String,
                label: String?, kind: NotebookLinkKind, isEmbed: Bool) {
        self.range = range
        self.destinationRange = destinationRange
        self.destination = destination
        self.label = label
        self.kind = kind
        self.isEmbed = isEmbed
    }
}

/// A local, rebuildable interpretation of literal Markdown, using UTF-16 ranges.
/// Incomplete occurrences are opt-in for paint-only typing styles; consumers
/// resolving, indexing, or rewriting links must use the complete default.
public enum NotebookLinkParser {
    public static func parse(_ text: String, includingIncomplete: Bool = false,
                             allowFrontmatter: Bool = true) -> [NotebookLinkOccurrence] {
        let source = text as NSString
        let units = Array(text.utf16)
        let blocked = excludedUnits(text, allowFrontmatter: allowFrontmatter)
        var result: [NotebookLinkOccurrence] = []
        var i = 0
        func escaped(_ offset: Int) -> Bool {
            var cursor = offset - 1
            var count = 0
            while cursor >= 0 && units[cursor] == 92 { count += 1; cursor -= 1 }
            return count % 2 == 1
        }
        func available(_ offset: Int) -> Bool {
            offset < units.count && !blocked[offset]
        }
        while i < units.count {
            guard available(i), units[i] == 91, !escaped(i) else { i += 1; continue }
            let embed = i > 0 && units[i - 1] == 33 && !escaped(i - 1)
            let start = embed ? i - 1 : i
            if available(i + 1), units[i + 1] == 91 {
                var end = i + 2
                var pipe: Int?
                while end < units.count, units[end] != 10 {
                    if !blocked[end] && !escaped(end) {
                        if units[end] == 124 && pipe == nil { pipe = end }
                        if units[end] == 93, available(end + 1), units[end + 1] == 93 { break }
                    }
                    end += 1
                }
                if available(end + 1), units[end] == 93, units[end + 1] == 93 {
                    let destinationRange = NSRange(location: i + 2, length: (pipe ?? end) - i - 2)
                    let destination = source.substring(with: destinationRange)
                    if !destination.trimmingCharacters(in: .whitespaces).isEmpty {
                        result.append(.init(
                            range: NSRange(location: start, length: end + 2 - start),
                            destinationRange: destinationRange, destination: destination,
                            label: pipe.map { source.substring(with: NSRange(location: $0 + 1, length: end - $0 - 1)) },
                            kind: .wiki, isEmbed: embed
                        ))
                    }
                    i = end + 2
                    continue
                }
            }
            // Inline Markdown links: nested label brackets and destination parentheses.
            var closing = i + 1
            var depth = 1
            while closing < units.count, units[closing] != 10 {
                if !blocked[closing] && !escaped(closing) {
                    if units[closing] == 91 { depth += 1 }
                    if units[closing] == 93 { depth -= 1; if depth == 0 { break } }
                }
                closing += 1
            }
            guard depth == 0, available(closing + 1), units[closing + 1] == 40 else { i += 1; continue }
            var cursor = closing + 2
            while available(cursor), units[cursor] == 32 || units[cursor] == 9 { cursor += 1 }
            let angled = available(cursor) && units[cursor] == 60
            if angled { cursor += 1 }
            let destinationStart = cursor
            var parentheses = 0
            while available(cursor), units[cursor] != 10 {
                let unit = units[cursor]
                if !escaped(cursor) {
                    if angled && unit == 62 { break }
                    if !angled {
                        if unit == 40 { parentheses += 1 }
                        if unit == 41 { if parentheses == 0 { break }; parentheses -= 1 }
                        if parentheses == 0 && (unit == 32 || unit == 9) { break }
                    }
                }
                cursor += 1
            }
            let destinationEnd = cursor
            if angled {
                guard available(cursor), units[cursor] == 62 else { i += 1; continue }
                cursor += 1
            }
            while available(cursor), units[cursor] == 32 || units[cursor] == 9 { cursor += 1 }
            if available(cursor), [UInt16(34), 39, 40].contains(units[cursor]) {
                let quote = units[cursor] == 40 ? UInt16(41) : units[cursor]
                cursor += 1
                while available(cursor), units[cursor] != 10 {
                    if units[cursor] == quote && !escaped(cursor) { break }
                    cursor += 1
                }
                guard available(cursor), units[cursor] == quote else { i += 1; continue }
                cursor += 1
                while available(cursor), units[cursor] == 32 || units[cursor] == 9 { cursor += 1 }
            }
            let complete = available(cursor) && units[cursor] == 41
            let atLineEnd = cursor == units.count || (cursor < units.count && units[cursor] == 10)
            guard complete || (includingIncomplete && atLineEnd) else { i += 1; continue }
            let upper = complete ? cursor + 1 : cursor
            let destinationRange = NSRange(location: destinationStart, length: destinationEnd - destinationStart)
            result.append(.init(
                range: NSRange(location: start, length: upper - start),
                destinationRange: destinationRange, destination: source.substring(with: destinationRange),
                label: source.substring(with: NSRange(location: i + 1, length: closing - i - 1)),
                kind: .markdown, isEmbed: embed
            ))
            i = upper
        }
        return result
    }

    /// Split on a literal fragment separator; escaped hashes belong to paths.
    public static func literalDestinationParts(_ destination: String) -> (path: String, fragment: String?) {
        var escaped = false
        for index in destination.indices {
            let character = destination[index]
            if character == "#" && !escaped {
                return (String(destination[..<index]), String(destination[destination.index(after: index)...]))
            }
            if character == "\\" { escaped.toggle() } else { escaped = false }
        }
        return (destination, nil)
    }

    /// Locate an existing heading or block without changing the source text.
    public static func targetRange(for fragment: String, in text: String) -> NSRange? {
        let entries = headingEntries(in: text)
        func exactHeading(_ title: String) -> NSRange? {
            entries.first {
                plainHeading($0.title).compare(title,
                    options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }?.range
        }
        // Resolver fragments are already decoded. Prefer their literal title
        // before decoding direct encoded-fragment callers a second time.
        if !fragment.hasPrefix("^"), let range = exactHeading(fragment) { return range }
        let fragment = fragment.removingPercentEncoding ?? fragment
        let wanted = fragment.hasPrefix("#") ? String(fragment.dropFirst()) : fragment
        let source = text as NSString
        let blocked = excludedUnits(text)
        var lines: [(String, NSRange)] = []
        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length), options: .byLines) { line, range, _, _ in
            lines.append((line ?? "", range))
        }
        if wanted.hasPrefix("^") {
            let marker = wanted
            return lines.first { line, range in
                guard range.location < blocked.count, !blocked[range.location] else { return false }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed == marker || trimmed.hasSuffix(" " + marker)
            }?.1
        }
        // A literal hash can belong to a heading title. Only interpret it as
        // a hierarchy separator when no complete title matches.
        if let range = exactHeading(wanted) { return range }
        let parts = wanted.split(separator: "#").map(String.init)
        var hierarchy: [(level: Int, title: String)] = []
        for entry in entries {
            let title = entry.title
            let level = entry.level
            let range = entry.range
            hierarchy.removeAll { $0.level >= level }
            hierarchy.append((level, title))
            if parts.count == 1, headingMatches(title, parts[0]) { return range }
            if parts.count <= hierarchy.count {
                let suffix = hierarchy.suffix(parts.count)
                if zip(suffix, parts).allSatisfy({ headingMatches($0.0.title, $0.1) }) { return range }
            }
        }
        return nil
    }

    /// Heading completion uses the same exclusions and hierarchy as navigation.
    /// Include short titles and nested paths so duplicate headings can be chosen.
    public static func headings(in text: String) -> [String] {
        var hierarchy: [(level: Int, title: String)] = []
        var result: [String] = []
        for entry in headingEntries(in: text) {
            let title = plainHeading(entry.title)
            guard !title.isEmpty else { continue }
            hierarchy.removeAll { $0.level >= entry.level }
            hierarchy.append((entry.level, title))
            if !result.contains(title) { result.append(title) }
            let path = hierarchy.map(\.title).joined(separator: "#")
            if hierarchy.count > 1, !result.contains(path) { result.append(path) }
        }
        return result
    }

    /// Read simple Obsidian aliases from YAML frontmatter. This intentionally
    /// supports string block lists, single-line flow lists, and string scalars;
    /// YAML anchors, tags, multiline scalars, and nested properties are ignored.
    public static func aliases(in text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: {
                  let line = $0.trimmingCharacters(in: .whitespaces)
                  return line == "---" || line == "..."
              }) else { return [] }
        var result: [String] = []
        var collecting = false
        for line in lines[1..<end] {
            if line.hasPrefix("aliases:") {
                let value = stripYAMLComment(String(line.dropFirst(8))).trimmingCharacters(in: .whitespaces)
                collecting = value.isEmpty
                if value.hasPrefix("["), value.hasSuffix("]") {
                    let content = String(value.dropFirst().dropLast())
                    result.append(contentsOf: splitYAMLFlow(content).compactMap(aliasScalar))
                } else if !value.isEmpty, let alias = aliasScalar(value) { result.append(alias) }
            } else if collecting {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                if trimmed.hasPrefix("- "), let alias = aliasScalar(String(trimmed.dropFirst(2))) {
                    result.append(alias)
                } else { collecting = false }
            }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }

    private static func splitYAMLFlow(_ text: String) -> [String] {
        var quote: Character?
        var escaped = false
        var current = ""
        var result: [String] = []
        for character in text {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\", quote == "\"" { current.append(character); escaped = true; continue }
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" { quote = character }
            else if character == "," { result.append(current); current = ""; continue }
            current.append(character)
        }
        guard quote == nil else { return [] }
        result.append(current)
        return result
    }

    private static func stripYAMLComment(_ text: String) -> String {
        var quote: Character?
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if escaped { escaped = false; continue }
            if character == "\\", quote == "\"" { escaped = true; continue }
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" { quote = character }
            else if character == "#", index == text.startIndex || text[text.index(before: index)].isWhitespace {
                return String(text[..<index])
            }
        }
        return text
    }

    private static func aliasScalar(_ value: String) -> String? {
        let value = stripYAMLComment(value).trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
            let decoded = value.dropFirst().dropLast().replacingOccurrences(of: "''", with: "'")
            return decoded.isEmpty ? nil : decoded
        }
        if value.hasPrefix("\""), value.hasSuffix("\""),
           let data = value.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String {
            return decoded.isEmpty ? nil : decoded
        }
        guard !["null", "~", "true", "false"].contains(value.lowercased()),
              !"&*!|>{[\"'".contains(value.first!), !value.contains(": ") else { return nil }
        return value
    }

    private static func headingEntries(in text: String) -> [(title: String, level: Int, range: NSRange)] {
        let source = text as NSString
        let blocked = excludedUnits(text)
        var lines: [(String, NSRange)] = []
        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length), options: .byLines) { line, range, _, _ in
            lines.append((line ?? "", range))
        }
        var result: [(title: String, level: Int, range: NSRange)] = []
        for (index, entry) in lines.enumerated() {
            let (line, range) = entry
            guard range.location < blocked.count, !blocked[range.location] else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            var title: String?
            var level = 1
            if trimmed.hasPrefix("#") {
                let prefix = trimmed.prefix(while: { $0 == "#" })
                if prefix.count <= 6, trimmed.dropFirst(prefix.count).first?.isWhitespace == true {
                    level = prefix.count
                    title = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression)
                }
            } else if index + 1 < lines.count {
                let underline = lines[index + 1].0.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty, !underline.isEmpty,
                   !blocked[lines[index + 1].1.location],
                   (underline.allSatisfy { $0 == "=" } || underline.allSatisfy { $0 == "-" }) {
                    level = underline.first == "=" ? 1 : 2
                    title = trimmed
                }
            }
            guard let title else { continue }
            result.append((title, level, range))
        }
        return result
    }

    private static func plainHeading(_ title: String) -> String {
        let source = NSMutableString(string: title)
        for link in parse(title).reversed() {
            source.replaceCharacters(in: link.range, with: link.label ?? link.destination)
        }
        var plain = source as String
        for pattern in [#"\*\*(.+?)\*\*"#, #"__(.+?)__"#, #"\*(.+?)\*"#, #"(?<!\w)_(.+?)_(?!\w)"#, #"`+(.+?)`+"#] {
            plain = plain.replacingOccurrences(of: pattern, with: "$1", options: .regularExpression)
        }
        return plain.trimmingCharacters(in: .whitespaces)
    }

    private static func headingMatches(_ title: String, _ destination: String) -> Bool {
        let plain = plainHeading(title)
        if plain.compare(destination, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame { return true }
        let slug = plain.lowercased().replacingOccurrences(of: #"[^\p{L}\p{N}\s_-]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
        return slug == destination.lowercased()
    }

    /// Neutral boundaries for incremental editor parsing. A substring must
    /// never restart inside frontmatter or a multiline HTML comment.
    public static func incrementalContext(
        in text: String, allowFrontmatter: Bool = true
    ) -> (ranges: [NSRange], hasOpenComment: Bool) {
        var ranges: [NSRange] = []
        var open = false
        _ = excludedUnits(text, allowFrontmatter: allowFrontmatter,
                          contextRanges: &ranges, hasOpenComment: &open)
        return (ranges, open)
    }

    private static func excludedUnits(_ text: String, allowFrontmatter: Bool = true) -> [Bool] {
        var ranges: [NSRange] = []
        var open = false
        return excludedUnits(text, allowFrontmatter: allowFrontmatter,
                             contextRanges: &ranges, hasOpenComment: &open)
    }

    private static func excludedUnits(
        _ text: String, allowFrontmatter: Bool,
        contextRanges: inout [NSRange], hasOpenComment: inout Bool
    ) -> [Bool] {
        let source = text as NSString
        let units = Array(text.utf16)
        var blocked = Array(repeating: false, count: units.count)
        func mark(_ range: NSRange) {
            for offset in range.location..<min(NSMaxRange(range), blocked.count) { blocked[offset] = true }
        }
        var fence: (Character, Int)?
        var frontmatter = false
        var firstLine = true
        var frontmatterEnd = 0
        let firstLineEnd = source.lineRange(for: NSRange(location: 0, length: 0)).length
        let startsFrontmatter = allowFrontmatter && source.substring(to: firstLineEnd)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "---"
        let remainder = startsFrontmatter && source.length > firstLineEnd
            ? source.substring(from: firstLineEnd) : ""
        let hasFrontmatterEnd = remainder.components(separatedBy: .newlines).contains {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return line == "---" || line == "..."
        }
        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length), options: .byLines) { line, _, enclosing, _ in
            let value = line ?? ""
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if allowFrontmatter && firstLine && trimmed == "---" && hasFrontmatterEnd { frontmatter = true; mark(enclosing); firstLine = false; return }
            firstLine = false
            if frontmatter {
                mark(enclosing)
                if trimmed == "---" || trimmed == "..." {
                    frontmatter = false
                    frontmatterEnd = NSMaxRange(enclosing)
                }
                return
            }
            let indentation = value.prefix(while: { $0 == " " }).count
            let marker = trimmed.first
            let run = marker.map { m in trimmed.prefix(while: { $0 == m }).count } ?? 0
            if let open = fence {
                mark(enclosing)
                if indentation <= 3, marker == open.0, run >= open.1,
                   trimmed.dropFirst(run).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
                return
            }
            if indentation <= 3, (marker == "`" || marker == "~"), run >= 3 {
                fence = (marker!, run); mark(enclosing); return
            }
            if indentation >= 4 || value.hasPrefix("\t") { mark(enclosing) }
        }
        if frontmatterEnd > 0 {
            contextRanges.append(NSRange(location: 0, length: frontmatterEnd))
        }
        // Scan inline code and comments together: comment examples in code
        // cannot hide subsequent prose, and backticks in comments are literal.
        func escaped(_ offset: Int) -> Bool {
            var previous = offset - 1
            var count = 0
            while previous >= 0 && units[previous] == 92 { count += 1; previous -= 1 }
            return count % 2 == 1
        }
        var cursor = 0
        while cursor < units.count {
            guard !blocked[cursor], !escaped(cursor) else { cursor += 1; continue }
            if cursor + 3 < units.count, units[cursor] == 60,
               units[cursor + 1] == 33, units[cursor + 2] == 45, units[cursor + 3] == 45 {
                let end = source.range(of: "-->", range: NSRange(location: cursor + 4, length: source.length - cursor - 4))
                let upper = end.location == NSNotFound ? source.length : NSMaxRange(end)
                let range = NSRange(location: cursor, length: upper - cursor)
                contextRanges.append(range)
                hasOpenComment = end.location == NSNotFound
                mark(range); cursor = upper
                continue
            }
            guard units[cursor] == 96 else { cursor += 1; continue }
            var run = 1
            while cursor + run < units.count && units[cursor + run] == 96 { run += 1 }
            var end = cursor + run
            var found: Int?
            while end < units.count && !blocked[end] {
                // A code span cannot bridge separate paragraphs.
                if units[end] == 10 {
                    var next = end + 1
                    while next < units.count && [UInt16(32), 9, 13].contains(units[next]) { next += 1 }
                    if next < units.count && units[next] == 10 { break }
                }
                if units[end] == 96 {
                    var closingRun = 1
                    while end + closingRun < units.count && units[end + closingRun] == 96 { closingRun += 1 }
                    if closingRun == run { found = end + run; break }
                    end += closingRun
                } else { end += 1 }
            }
            if let found { mark(NSRange(location: cursor, length: found - cursor)); cursor = found }
            else { cursor += run }
        }
        return blocked
    }
}

/// An observed earlier location of the same stable note identity. These
/// metadata aliases do not change Markdown or take priority over current paths.
public struct NotebookLinkLocation: Sendable, Equatable, Codable {
    public let name: String
    public let path: String
    public let rootID: UUID?
    public let rootPath: String?

    public init(name: String, path: String, rootID: UUID? = nil,
                rootPath: String? = nil) {
        self.name = name; self.path = path
        self.rootID = rootID; self.rootPath = rootPath
    }
}

public struct NotebookLinkNote: Sendable, Equatable {
    public let id: UUID
    public let name: String
    /// Notebook-relative containing folder path, without the filename.
    public let path: String
    public let rootID: UUID?
    public let rootPath: String?

    public let formerLocations: [NotebookLinkLocation]

    public init(id: UUID, name: String, path: String, rootID: UUID? = nil,
                rootPath: String? = nil,
                formerLocations: [NotebookLinkLocation] = []) {
        self.id = id; self.name = name; self.path = path
        self.rootID = rootID; self.rootPath = rootPath
        self.formerLocations = formerLocations
    }

    var location: NotebookLinkLocation {
        NotebookLinkLocation(name: name, path: path, rootID: rootID,
                             rootPath: rootPath)
    }

    public var fullPath: String { path.isEmpty ? name : path + "/" + name }
}

/// Generates a local destination for a resolved note identity. Callers should
/// resolve the result against their corpus before applying it. `fragment` is
/// literal source text after the first `#`, so existing escaping is preserved.
public enum NotebookLinkDestination {
    public static func make(
        target: NotebookLinkNote,
        source: NotebookLinkNote,
        kind: NotebookLinkKind,
        fragment: String? = nil,
        includeExtension: Bool = true
    ) -> String? {
        let filename: String
        if includeExtension {
            filename = target.name
        } else {
            let name = target.name
            filename = name.lowercased().hasSuffix(".markdown")
                ? String(name.dropLast(9))
                : name.lowercased().hasSuffix(".md") ? String(name.dropLast(3)) : name
        }
        let sourceFolders = components(source.path)
        let targetFolders = components(target.path)
        let path: String
        if kind == .wiki {
            if source.rootID != nil, source.rootID == target.rootID,
               let rootPath = target.rootPath,
               rootPath.isEmpty || target.fullPath.hasPrefix(rootPath + "/") {
                let rooted = Array(targetFolders.dropFirst(components(rootPath).count))
                path = rooted.isEmpty ? filename : (rooted + [filename]).joined(separator: "/")
            } else if source.rootID == nil, target.rootID == nil {
                path = (targetFolders + [filename]).joined(separator: "/")
            } else {
                // Dot paths explicitly select source-relative resolution across
                // imported scopes and avoid colliding notebook-root suffixes.
                path = relativePath(sourceFolders, targetFolders, filename)
            }
        } else {
            path = relativePath(sourceFolders, targetFolders, filename)
        }
        let escaped = kind == .markdown ? encodePath(path) : escapeWikiPath(path)
        let suffix = fragment.map { kind == .markdown ? encodeFragment($0) : $0 }
        return escaped + (suffix.map { "#\($0)" } ?? "")
    }

    /// Encode freshly selected heading text for a wiki destination. Existing
    /// literal fragments (including exports) should be passed to `make` intact.
    public static func wikiHeadingFragment(_ heading: String) -> String {
        escapeWikiPath(heading)
    }

    private static func components(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    private static func relativePath(
        _ sourceFolders: [String], _ targetFolders: [String], _ filename: String
    ) -> String {
        var common = 0
        while common < sourceFolders.count && common < targetFolders.count
            && sourceFolders[common] == targetFolders[common] { common += 1 }
        let relative = Array(repeating: "..", count: sourceFolders.count - common)
            + Array(targetFolders.dropFirst(common)) + [filename]
        let joined = relative.joined(separator: "/")
        return joined.hasPrefix("../") ? joined : "./" + joined
    }

    private static func encodePath(_ path: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: safe) ?? String($0) }
            .joined(separator: "/")
    }

    private static func escapeWikiPath(_ path: String) -> String {
        var result = ""
        for character in path {
            if character == "%" { result += "%25" }
            else if "\\#|[]".contains(character) { result.append("\\"); result.append(character) }
            else { result.append(character) }
        }
        return result
    }

    /// Keep existing percent escapes and escaped punctuation intact, while
    /// making newly typed heading spaces and delimiters safe in Markdown.
    private static func encodeFragment(_ fragment: String) -> String {
        var result = ""
        var escaped = false
        for character in fragment {
            if escaped { result.append(character); escaped = false; continue }
            if character == "\\" { result.append(character); escaped = true; continue }
            if character.isWhitespace || "()<>".contains(character) {
                result += String(character).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? String(character)
            } else { result.append(character) }
        }
        return result
    }
}

public enum NotebookLinkResolution: Sendable, Equatable {
    case resolved(noteID: UUID, fragment: String?)
    case missing(destination: String)
    case ambiguous([UUID])
    case external(URL)
    case unsupported
}

public enum NotebookLinkResolver {
    public static func path(of occurrence: NotebookLinkOccurrence) -> String {
        let literal = occurrence.destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = unescaped(NotebookLinkParser.literalDestinationParts(literal).path)
        return path.removingPercentEncoding ?? path
    }

    public static func fragment(of occurrence: NotebookLinkOccurrence) -> String? {
        let literal = occurrence.destination.trimmingCharacters(in: .whitespacesAndNewlines)
        return NotebookLinkParser.literalDestinationParts(literal).fragment
            .map { unescaped($0) }.map { $0.removingPercentEncoding ?? $0 }
    }

    public static func resolve(_ occurrence: NotebookLinkOccurrence, sourceID: UUID,
                               notes: [NotebookLinkNote]) -> NotebookLinkResolution {
        Lookup(notes: notes).resolve(occurrence, sourceID: sourceID)
    }

    /// Resolve only current locations when validating a newly authored
    /// destination. Navigation and indexing should use `resolve` so earlier
    /// relationships cannot be silently redirected by a reused path.
    public static func resolveCurrent(_ occurrence: NotebookLinkOccurrence, sourceID: UUID,
                                      notes: [NotebookLinkNote]) -> NotebookLinkResolution {
        Lookup(notes: notes).resolveCurrent(occurrence, sourceID: sourceID)
    }

    /// A frozen catalog lookup for resolving many occurrences. Paths and
    /// scope-relative wiki suffixes are normalized once, rather than once
    /// per link. Historical source variants retain the same conservative
    /// ambiguity rules as one-off navigation.
    public struct Lookup: Sendable {
        private struct Scope: Hashable, Sendable {
            let rootID: UUID?
            let rootPath: String?
        }

        private struct Location: Sendable {
            let value: NotebookLinkLocation
            let fullPath: String
            let normalizedFullPath: String?
            let scope: Scope
            let ownWikiPath: String?

            init(_ value: NotebookLinkLocation) {
                self.value = value
                fullPath = value.path.isEmpty ? value.name : value.path + "/" + value.name
                normalizedFullPath = NotebookLinkResolver.normalized(fullPath)
                scope = Scope(rootID: value.rootID,
                              rootPath: value.rootPath.flatMap { $0.isEmpty ? nil : $0 })
                if let rootPath = scope.rootPath {
                    ownWikiPath = fullPath.hasPrefix(rootPath + "/")
                        ? NotebookLinkResolver.normalized(String(fullPath.dropFirst(rootPath.count + 1)))
                        : nil
                } else {
                    ownWikiPath = normalizedFullPath
                }
            }
        }

        private struct Source: Sendable {
            let current: Location
            let variants: [Location]
        }

        private struct Entry: Sendable {
            let id: UUID
            let location: Location
        }

        private struct Destination {
            let raw: String
            let path: String
            let fragment: String?
            let ext: String
            let usesRelativePaths: Bool
            let wantedWikiPath: String?

            init(_ occurrence: NotebookLinkOccurrence) {
                let literal = occurrence.destination.trimmingCharacters(in: .whitespacesAndNewlines)
                raw = NotebookLinkResolver.unescaped(literal)
                path = NotebookLinkResolver.path(of: occurrence)
                fragment = NotebookLinkResolver.fragment(of: occurrence)
                ext = (path as NSString).pathExtension.lowercased()
                usesRelativePaths = occurrence.kind == .markdown
                    || path.hasPrefix("./") || path.hasPrefix("../")
                wantedWikiPath = usesRelativePaths ? nil : NotebookLinkResolver.normalized(
                    path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            }
        }

        private let sources: [UUID: Source]
        private let currentPaths: [String: Set<UUID>]
        private let historicalPaths: [String: Set<UUID>]
        private let currentWiki: [Scope: [String: Set<UUID>]]
        private let historicalWiki: [Scope: [String: Set<UUID>]]
        private let hasHistory: Bool

        public init(notes: [NotebookLinkNote]) {
            var sources: [UUID: Source] = [:]
            var currentEntries: [Entry] = []
            var historicalEntries: [Entry] = []
            for note in notes {
                let current = Location(note.location)
                let variants = [current] + note.formerLocations.map(Location.init)
                // One-off resolution has always used the first source with
                // this identity, while target matching deduplicates IDs.
                if sources[note.id] == nil {
                    sources[note.id] = Source(current: current, variants: variants)
                }
                currentEntries.append(Entry(id: note.id, location: current))
                historicalEntries += variants.map { Entry(id: note.id, location: $0) }
            }
            self.sources = sources
            hasHistory = notes.contains { !$0.formerLocations.isEmpty }
            currentPaths = Self.pathLookup(currentEntries)
            currentWiki = Self.wikiLookup(currentEntries,
                scopes: Set(currentEntries.map { $0.location.scope }))
            if hasHistory {
                historicalPaths = Self.pathLookup(historicalEntries)
                historicalWiki = Self.wikiLookup(historicalEntries,
                    scopes: Set(historicalEntries.map { $0.location.scope }))
            } else {
                historicalPaths = [:]
                historicalWiki = [:]
            }
        }

        public func resolve(_ occurrence: NotebookLinkOccurrence,
                            sourceID: UUID) -> NotebookLinkResolution {
            resolve(occurrence, sourceID: sourceID, includeHistory: true)
        }

        public func resolveCurrent(_ occurrence: NotebookLinkOccurrence,
                                   sourceID: UUID) -> NotebookLinkResolution {
            resolve(occurrence, sourceID: sourceID, includeHistory: false)
        }

        private func resolve(_ occurrence: NotebookLinkOccurrence, sourceID: UUID,
                             includeHistory: Bool) -> NotebookLinkResolution {
            guard !occurrence.isEmbed else { return .unsupported }
            let destination = Destination(occurrence)
            let externalURL = URL(string: destination.raw).flatMap {
                $0.scheme == nil ? nil : $0
            }
            // Explicit Markdown URLs keep their external meaning. A wiki
            // destination may instead be a valid colon-containing note name.
            if occurrence.kind == .markdown, let url = externalURL {
                return .external(url)
            }
            func finish(_ result: NotebookLinkResolution) -> NotebookLinkResolution {
                guard occurrence.kind == .wiki, let url = externalURL,
                      let scheme = url.scheme?.lowercased(),
                      ["http", "https", "mailto"].contains(scheme) else { return result }
                switch result {
                case .resolved, .ambiguous: return result
                default: return .external(url)
                }
            }
            guard let source = sources[sourceID] else { return finish(.unsupported) }
            if destination.path.isEmpty {
                return .resolved(noteID: sourceID, fragment: destination.fragment)
            }
            if occurrence.kind == .markdown, !destination.ext.isEmpty,
               destination.ext != "md", destination.ext != "markdown" {
                return .unsupported
            }
            let currentIDs = candidates(destination, source: source.current,
                                        paths: currentPaths, wiki: currentWiki)
            let current = resolution(currentIDs, destination: destination)
            // Dotted wiki titles remain valid historical note names. A wiki
            // miss with a non-Markdown extension must still consult history.
            if !includeHistory || !hasHistory
                || current == .unsupported && occurrence.kind == .markdown {
                return finish(current)
            }
            var ids = Set<UUID>()
            for variant in source.variants {
                var candidates = candidates(destination, source: variant,
                                            paths: historicalPaths, wiki: historicalWiki)
                // Historical resolution excludes all source aliases, then
                // admits only this selected source location for self links.
                candidates.remove(sourceID)
                if matchesSelf(destination, source: variant) { candidates.insert(sourceID) }
                ids.formUnion(candidates)
            }
            return finish(ids.isEmpty ? current : resolution(ids, destination: destination))
        }

        private func candidates(_ destination: Destination, source: Location,
                                paths: [String: Set<UUID>],
                                wiki: [Scope: [String: Set<UUID>]]) -> Set<UUID> {
            if destination.usesRelativePaths {
                return relativeDestinations(destination.path, source: source)
                    .reduce(into: Set<UUID>()) { result, path in
                        result.formUnion(paths[path] ?? [])
                    }
            }
            guard let wanted = destination.wantedWikiPath else { return [] }
            return wiki[source.scope]?[wanted] ?? []
        }

        private func matchesSelf(_ destination: Destination, source: Location) -> Bool {
            if destination.usesRelativePaths {
                return source.normalizedFullPath.map {
                    relativeDestinations(destination.path, source: source).contains($0)
                } ?? false
            }
            guard let wanted = destination.wantedWikiPath,
                  let ownPath = source.ownWikiPath else { return false }
            return ownPath == wanted || ownPath.hasSuffix("/" + wanted)
        }

        private func relativeDestinations(_ path: String, source: Location) -> Set<String> {
            let explicitRelative = path.hasPrefix("./") || path.hasPrefix("../")
            let relative = source.value.path.isEmpty ? path : source.value.path + "/" + path
            let rootRelative = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let root = source.scope.rootPath.map { $0 + "/" + rootRelative } ?? rootRelative
            var destinations = Set<String>()
            if !path.hasPrefix("/"), let relative = NotebookLinkResolver.normalized(relative) {
                destinations.insert(relative)
            }
            if !explicitRelative, let root = NotebookLinkResolver.normalized(root) {
                destinations.insert(root)
            }
            return destinations
        }

        private func resolution(_ ids: Set<UUID>, destination: Destination)
            -> NotebookLinkResolution {
            if ids.count == 1, let id = ids.first {
                return .resolved(noteID: id, fragment: destination.fragment)
            }
            if ids.count > 1 {
                return .ambiguous(ids.sorted { $0.uuidString < $1.uuidString })
            }
            if !destination.usesRelativePaths && destination.wantedWikiPath == nil {
                return .missing(destination: destination.raw)
            }
            if !destination.ext.isEmpty, destination.ext != "md", destination.ext != "markdown" {
                return .unsupported
            }
            return .missing(destination: destination.raw)
        }

        private static func pathLookup(_ entries: [Entry]) -> [String: Set<UUID>] {
            var result: [String: Set<UUID>] = [:]
            for entry in entries {
                if let path = entry.location.normalizedFullPath {
                    result[path, default: []].insert(entry.id)
                }
            }
            return result
        }

        private static func wikiLookup(_ entries: [Entry], scopes: Set<Scope>)
            -> [Scope: [String: Set<UUID>]] {
            let scopesByRoot = Dictionary(grouping: scopes, by: \.rootID)
            var result: [Scope: [String: Set<UUID>]] = [:]
            for entry in entries {
                for scope in scopesByRoot[entry.location.scope.rootID] ?? [] {
                    let path: String?
                    if let rootPath = scope.rootPath {
                        guard entry.location.fullPath.hasPrefix(rootPath + "/") else { continue }
                        path = NotebookLinkResolver.normalized(String(
                            entry.location.fullPath.dropFirst(rootPath.count + 1)))
                    } else {
                        path = entry.location.normalizedFullPath
                    }
                    guard let path else { continue }
                    result[scope, default: [:]][path, default: []].insert(entry.id)
                    for slash in path.indices where path[slash] == "/" {
                        let suffix = String(path[path.index(after: slash)...])
                        result[scope, default: [:]][suffix, default: []].insert(entry.id)
                    }
                }
            }
            return result
        }
    }

    private static func normalized(_ path: String) -> String? {
        var parts: [String] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { guard !parts.isEmpty else { return nil }; parts.removeLast() }
            else { parts.append(String(part).precomposedStringWithCanonicalMapping) }
        }
        guard !parts.isEmpty else { return "" }
        let ext = (parts[parts.count - 1] as NSString).pathExtension.lowercased()
        if ext == "md" || ext == "markdown" { parts[parts.count - 1] = (parts[parts.count - 1] as NSString).deletingPathExtension }
        return parts.joined(separator: "/")
    }

    private static func unescaped(_ value: String) -> String {
        value.replacingOccurrences(of: ##"\\([!\"#$%&'()*+,\-./:;<=>?@\[\\\]^_`{|}~])"##, with: "$1", options: .regularExpression)
    }
}

public struct NotebookBacklink: Sendable, Equatable {
    public let sourceID: UUID
    public let occurrence: NotebookLinkOccurrence
    public let snippet: String

    public init(sourceID: UUID, occurrence: NotebookLinkOccurrence, snippet: String) {
        self.sourceID = sourceID; self.occurrence = occurrence; self.snippet = snippet
    }
}

public struct NotebookLinkIndex: Sendable {
    private let incoming: [UUID: [NotebookBacklink]]

    public init(texts: [UUID: String], notes: [NotebookLinkNote]) {
        var incoming: [UUID: [NotebookBacklink]] = [:]
        let lookup = NotebookLinkResolver.Lookup(notes: notes)
        for sourceID in texts.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let text = texts[sourceID] else { continue }
            for occurrence in NotebookLinkParser.parse(text) {
                guard case .resolved(let destinationID, _) = lookup.resolve(occurrence, sourceID: sourceID), destinationID != sourceID else { continue }
                let source = text as NSString
                let lineRange = source.lineRange(for: occurrence.range)
                let line = source.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
                incoming[destinationID, default: []].append(.init(sourceID: sourceID, occurrence: occurrence, snippet: String(line.prefix(200))))
            }
        }
        self.incoming = incoming
    }

    public func backlinks(to noteID: UUID) -> [NotebookBacklink] { incoming[noteID] ?? [] }
}
