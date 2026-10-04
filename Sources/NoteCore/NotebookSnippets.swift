import Foundation

/// A registered note or folder that contributes Markdown snippets.
public struct NotebookSnippetSource: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: NotebookItemKind
    public let name: String
    /// Full notebook-relative path, including the source's name.
    public let path: String
}

/// A folder component in a snippet's category path.
public struct NotebookSnippetCategory: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
}

/// A note body available for insertion as a Markdown snippet.
public struct NotebookSnippet: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let path: String
    /// Folder ancestry in root-to-leaf order. IDs remain stable across moves.
    public let categories: [NotebookSnippetCategory]
}

public enum NotebookSnippetError: Error, Equatable, LocalizedError {
    case sourceUnavailable

    public var errorDescription: String? {
        "This snippet source is no longer available."
    }
}

/// A variable that can be expanded when a Markdown snippet is inserted.
public enum NotebookSnippetVariable: String, CaseIterable, Identifiable, Sendable {
    case date = "date"
    case shortDate = "date:short"
    case longDate = "date:long"
    case isoDate = "date:iso"
    case time = "time"
    case title = "title"

    public var id: String { rawValue }

    /// The literal spelling stored in a snippet source.
    public var token: String { "{{\(rawValue)}}" }

    public func value(
        title: String,
        date: Date = Date(),
        timeZone: TimeZone = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        guard self != .title else { return title }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        switch self {
        case .date:
            formatter.dateStyle = .short
            formatter.timeStyle = .none
        case .shortDate:
            return Self.shortDateValue(date: date, timeZone: timeZone, locale: locale)
        case .longDate:
            formatter.dateStyle = .long
            formatter.timeStyle = .none
        case .isoDate:
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = "yyyy-MM-dd"
        case .time:
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        case .title:
            return title
        }
        return formatter.string(from: date)
    }

    static func shortDateValue(
        date: Date,
        timeZone: TimeZone,
        locale: Locale,
        preferredFormat: String? = nil
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .short
        formatter.timeStyle = .none

        if let preferredFormat {
            formatter.dateFormat = preferredFormat
        }
        let format = preferredFormat ?? formatter.dateFormat ?? ""
        if let yearlessFormat = yearlessDateFormat(from: format) {
            formatter.dateFormat = yearlessFormat
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMdd")
        }
        return formatter.string(from: date)
    }

    private enum DatePatternPart {
        case field(Character, String)
        case literal(String)
    }

    private static func yearlessDateFormat(from format: String) -> String? {
        guard let parts = datePatternParts(format) else { return nil }
        let yearSymbols: Set<Character> = ["y", "Y", "u", "U", "r"]
        let eras: Set<Character> = ["G"]
        let months: Set<Character> = ["M", "L"]
        let days: Set<Character> = ["d", "D"]
        let yearRelated = parts.indices.filter { index in
            guard case let .field(symbol, _) = parts[index] else { return false }
            return yearSymbols.contains(symbol) || eras.contains(symbol)
        }
        let dateFields = parts.indices.filter { index in
            guard case let .field(symbol, _) = parts[index] else { return false }
            return months.contains(symbol) || days.contains(symbol)
        }
        guard !yearRelated.isEmpty, !dateFields.isEmpty,
              dateFields.contains(where: { index in
                  if case let .field(symbol, _) = parts[index] { return months.contains(symbol) }
                  return false
              }),
              dateFields.contains(where: { index in
                  if case let .field(symbol, _) = parts[index] { return days.contains(symbol) }
                  return false
              }) else { return nil }

        let supportedFields = yearSymbols.union(eras).union(months).union(days)
        guard parts.allSatisfy({ part in
            if case let .field(symbol, _) = part { return supportedFields.contains(symbol) }
            return true
        }) else { return nil }

        let firstYearPart = yearRelated[0]
        let lastYearPart = yearRelated[yearRelated.count - 1]
        let firstDateField = dateFields[0]
        let lastDateField = dateFields[dateFields.count - 1]
        var removedIndices = Set(yearRelated)
        removedIndices.formUnion((firstYearPart...lastYearPart).filter { index in
            if case .literal = parts[index] { return true }
            return false
        })

        let precedingLiteral = firstYearPart > 0 ? firstYearPart - 1 : nil
        let followingLiteral = lastYearPart + 1 < parts.count ? lastYearPart + 1 : nil
        if firstYearPart < firstDateField {
            if let followingLiteral, case .literal = parts[followingLiteral] {
                removedIndices.insert(followingLiteral)
            }
        } else if firstYearPart > lastDateField {
            if let followingLiteral,
               case let .literal(value) = parts[followingLiteral], value.contains("年") {
                removedIndices.insert(followingLiteral)
            } else if let precedingLiteral,
                      case .literal = parts[precedingLiteral] {
                removedIndices.insert(precedingLiteral)
            }
        } else if let precedingLiteral, case .literal = parts[precedingLiteral] {
            removedIndices.insert(precedingLiteral)
        }

        let result = parts.enumerated().compactMap { index, part -> String? in
            guard !removedIndices.contains(index) else { return nil }
            switch part {
            case let .field(_, value), let .literal(value): return value
            }
        }.joined()
        return result.isEmpty ? nil : result
    }

    private static func datePatternParts(_ format: String) -> [DatePatternPart]? {
        let characters = Array(format)
        var parts: [DatePatternPart] = []
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if character == "'" {
                var quoted = "'"
                index += 1
                guard index < characters.count else { return nil }
                if characters[index] == "'" {
                    quoted.append("'")
                    index += 1
                    parts.append(.literal(quoted))
                    continue
                }
                var closed = false
                while index < characters.count {
                    quoted.append(characters[index])
                    if characters[index] == "'" {
                        if index + 1 < characters.count, characters[index + 1] == "'" {
                            quoted.append("'")
                            index += 2
                            continue
                        }
                        index += 1
                        closed = true
                        break
                    }
                    index += 1
                }
                guard closed else { return nil }
                parts.append(.literal(quoted))
            } else if isDatePatternLetter(character) {
                let symbol = character
                var value = String(character)
                index += 1
                while index < characters.count, characters[index] == symbol {
                    value.append(characters[index])
                    index += 1
                }
                parts.append(.field(symbol, value))
            } else {
                var literal = String(character)
                index += 1
                while index < characters.count,
                      characters[index] != "'",
                      !isDatePatternLetter(characters[index]) {
                    literal.append(characters[index])
                    index += 1
                }
                parts.append(.literal(literal))
            }
        }
        return parts
    }

    private static func isDatePatternLetter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else { return false }
        return (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }
}

/// The active variable completion around an editor caret.
public struct NotebookSnippetVariableCompletion: Equatable, Sendable {
    public let range: NSRange
    public let query: String
    public let suggestions: [NotebookSnippetVariable]

    /// Finds a same-line `{{` query near an empty editor selection.
    ///
    /// The bounded UTF-16 scan keeps completion work local to the caret even
    /// when the document contains many megabytes of Markdown.
    public static func detect(
        in text: String,
        selection: NSRange
    ) -> NotebookSnippetVariableCompletion? {
        let source = text as NSString
        let length = source.length
        guard selection.length == 0,
              selection.location != NSNotFound,
              selection.location >= 0,
              selection.location <= length else { return nil }

        let caret = selection.location
        if caret > 0, caret < length {
            let before = source.character(at: caret - 1)
            let after = source.character(at: caret)
            guard !(0xD800...0xDBFF).contains(before),
                  !(0xDC00...0xDFFF).contains(after) else { return nil }
        }
        let scanStart = max(0, caret - 160)
        let scanRange = NSRange(location: scanStart, length: caret - scanStart)
        let prefix = source.substring(with: scanRange) as NSString
        let newline = prefix.range(of: "\n", options: .backwards)
        let lineStart = newline.location == NSNotFound ? 0 : NSMaxRange(newline)
        let linePrefix = NSRange(location: lineStart, length: prefix.length - lineStart)
        let opening = prefix.range(of: "{{", options: .backwards, range: linePrefix)
        guard opening.location != NSNotFound else { return nil }

        let afterOpening = NSRange(
            location: opening.location + opening.length,
            length: prefix.length - opening.location - opening.length)
        guard prefix.range(of: "}}", options: [], range: afterOpening).location == NSNotFound else {
            return nil
        }

        let queryRange = NSRange(location: afterOpening.location, length: afterOpening.length)
        let query = prefix.substring(with: queryRange)
        guard !query.contains(where: { $0.isNewline }) else { return nil }
        let absoluteStart = scanStart + opening.location
        var replacementLength = caret - absoluteStart
        let suggestions = NotebookSnippetVariable.allCases.filter {
            $0.rawValue.hasPrefix(query)
        }
        guard !suggestions.isEmpty else { return nil }

        let lookaheadLength = min(160, length - caret)
        let lookahead = source.substring(
            with: NSRange(location: caret, length: lookaheadLength)) as NSString
        if lookahead.hasPrefix("}}") {
            replacementLength += 2
        } else if lookahead.length > 0 {
            let followingText = lookahead as String
            if followingText.first?.isWhitespace != true {
                let continuationLength = suggestions.compactMap { variable -> Int? in
                    let continuation = String(variable.rawValue.dropFirst(query.count))
                    guard !continuation.isEmpty,
                          lookahead.hasPrefix(continuation + "}}") else { return nil }
                    return continuation.utf16.count + 2
                }.min()
                guard let continuationLength else { return nil }
                replacementLength += continuationLength
            }
        }
        return NotebookSnippetVariableCompletion(
            range: NSRange(location: absoluteStart, length: replacementLength),
            query: query,
            suggestions: suggestions)
    }
}

/// Expands insertion-time variables while leaving stored Markdown untouched.
public enum NotebookSnippetText {
    public static func expand(
        text: String,
        title: String,
        date: Date = Date(),
        timeZone: TimeZone = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        var result = ""
        var cursor = text.startIndex
        while let start = text[cursor...].range(of: "{{") {
            guard let end = text[start.upperBound...].range(of: "}}") else {
                result.append(contentsOf: text[cursor...])
                return result
            }
            // A stray opener must not consume a later valid variable. Search
            // backwards so overlapping openers in triple braces count too.
            let opening = text[start.lowerBound..<end.lowerBound]
                .range(of: "{{", options: .backwards) ?? start
            result.append(contentsOf: text[cursor..<opening.lowerBound])
            let key = String(text[opening.upperBound..<end.lowerBound])
            if let variable = NotebookSnippetVariable(rawValue: key) {
                result.append(contentsOf: variable.value(
                    title: title, date: date, timeZone: timeZone, locale: locale))
            } else {
                result.append(contentsOf: text[opening.lowerBound..<end.upperBound])
            }
            cursor = end.upperBound
        }
        result.append(contentsOf: text[cursor...])
        return result
    }
}

struct NotebookSnippetMetadata {
    var sources: Set<UUID> = []

    func projection(_ placements: [NotebookPlacement])
        -> (sources: [NotebookSnippetSource], snippets: [NotebookSnippet]) {
        guard !sources.isEmpty else { return ([], []) }
        let active = placements.filter { !$0.isInTrash && !$0.item.isPermanentlyDeleted }
        let byID = Dictionary(uniqueKeysWithValues: active.map { ($0.item.id, $0) })

        func ancestry(_ placement: NotebookPlacement) -> [NotebookPlacement] {
            var result: [NotebookPlacement] = []
            var parent = placement.parentID
            var seen: Set<UUID> = [placement.item.id]
            while let id = parent, seen.insert(id).inserted, let folder = byID[id] {
                result.append(folder)
                parent = folder.parentID
            }
            return result.reversed()
        }

        func path(_ placement: NotebookPlacement) -> String {
            (ancestry(placement).map(\.displayName) + [placement.displayName])
                .joined(separator: "/")
        }

        let sourceRows = active.filter { sources.contains($0.item.id) }.map {
            NotebookSnippetSource(id: $0.item.id, kind: $0.item.kind,
                                  name: $0.displayName, path: path($0))
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        let snippets = active.compactMap { placement -> NotebookSnippet? in
            guard placement.item.kind == .note else { return nil }
            let parents = ancestry(placement)
            let registeredRoot = parents.firstIndex { sources.contains($0.item.id) }
            guard sources.contains(placement.item.id) || registeredRoot != nil else { return nil }
            let categories = registeredRoot.map { index in
                parents[index...].map {
                    NotebookSnippetCategory(id: $0.item.id, name: $0.displayName)
                }
            } ?? []
            return NotebookSnippet(id: placement.item.id, name: placement.displayName,
                                  path: path(placement), categories: categories)
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return (sourceRows, snippets)
    }
}
