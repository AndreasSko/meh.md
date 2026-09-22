import Foundation

public struct NotebookSearchRevision: Hashable, Sendable {
    public struct OpenNote: Hashable, Sendable {
        public let id: UUID
        public let revision: Data

        public init(id: UUID, revision: Data) {
            self.id = id
            self.revision = revision
        }
    }

    public let notebookID: UUID?
    public let catalogHeads: Set<String>
    public let bodyGeneration: UInt64
    public let openNotes: [OpenNote]

    public init(
        notebookID: UUID?,
        catalogHeads: Set<String>,
        bodyGeneration: UInt64,
        openNotes: [OpenNote]
    ) {
        self.notebookID = notebookID
        self.catalogHeads = catalogHeads
        self.bodyGeneration = bodyGeneration
        self.openNotes = openNotes
    }
}

public struct NotebookSearchCorpus: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let id: UUID
        public let title: String
        /// The containing folders, from the notebook root to the parent.
        public let path: String
        public let text: String

        public init(id: UUID, title: String, path: String, text: String) {
            self.id = id
            self.title = title
            self.path = path
            self.text = text
        }
    }

    public let notebookID: UUID
    public let entries: [Entry]
    public let unavailableCount: Int

    public init(notebookID: UUID, entries: [Entry], unavailableCount: Int) {
        self.notebookID = notebookID
        self.entries = entries
        self.unavailableCount = unavailableCount
    }

    /// Literal, case-insensitive, accent-sensitive search. A note is returned
    /// once, ranked by exact, prefix, and other title matches before body-only
    /// matches. Ties are deterministic.
    public func search(_ query: String) -> [NotebookSearchResult] {
        guard !query.isEmpty else { return [] }
        var results: [NotebookSearchResult] = []
        for entry in entries {
            if Task.isCancelled { return [] }
            if let result = NotebookSearchResult(entry: entry, query: query) {
                results.append(result)
            }
        }
        return results.sorted()
    }
}

public struct NotebookSearchResult: Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let path: String
    public let excerpt: String
    public let titleMatchRange: NSRange?
    public let excerptMatchRange: NSRange?
    /// The match range in the original Markdown body's UTF-16 coordinate space.
    public let bodyMatchRange: NSRange?
    public let matchesTitle: Bool

    fileprivate let rank: Int

    public init(
        id: UUID,
        title: String,
        path: String,
        excerpt: String,
        titleMatchRange: NSRange?,
        excerptMatchRange: NSRange?,
        bodyMatchRange: NSRange?,
        matchesTitle: Bool
    ) {
        self.id = id
        self.title = title
        self.path = path
        self.excerpt = excerpt
        self.titleMatchRange = titleMatchRange
        self.excerptMatchRange = excerptMatchRange
        self.bodyMatchRange = bodyMatchRange
        self.matchesTitle = matchesTitle
        rank = matchesTitle ? 2 : 3
    }

    fileprivate init?(entry: NotebookSearchCorpus.Entry, query: String) {
        let titleRange = entry.title.range(
            of: query,
            options: [.caseInsensitive],
            locale: Self.locale
        )
        let bodyRange = entry.text.range(
            of: query,
            options: [.caseInsensitive],
            locale: Self.locale
        )
        guard titleRange != nil || bodyRange != nil else { return nil }

        id = entry.id
        title = entry.title
        path = entry.path
        titleMatchRange = titleRange.map { NSRange($0, in: entry.title) }
        bodyMatchRange = bodyRange.map { NSRange($0, in: entry.text) }
        matchesTitle = titleRange != nil

        if let bodyMatchRange {
            let snippet = Self.snippet(in: entry.text, around: bodyMatchRange)
            excerpt = snippet.text
            excerptMatchRange = snippet.matchRange
        } else {
            excerpt = Self.preview(of: entry.text)
            excerptMatchRange = nil
        }

        if entry.title.compare(query, options: [.caseInsensitive], locale: Self.locale) == .orderedSame {
            rank = 0
        } else if let titleRange, titleRange.lowerBound == entry.title.startIndex {
            rank = 1
        } else if titleRange != nil {
            rank = 2
        } else {
            rank = 3
        }
    }

    private static let locale = Locale(identifier: "en_US_POSIX")

    private static func preview(of text: String) -> String {
        let source = text as NSString
        guard source.length > 0 else { return "" }
        let length = min(source.length, 160)
        let range = source.rangeOfComposedCharacterSequences(
            for: NSRange(location: 0, length: length)
        )
        return source.substring(with: range)
            + (NSMaxRange(range) < source.length ? "…" : "")
    }

    private static func snippet(
        in text: String,
        around match: NSRange
    ) -> (text: String, matchRange: NSRange) {
        let source = text as NSString
        let context = 70
        let proposedStart = max(0, match.location - context)
        let proposedEnd = min(source.length, NSMaxRange(match) + context)
        let range = source.rangeOfComposedCharacterSequences(
            for: NSRange(
                location: proposedStart,
                length: proposedEnd - proposedStart
            )
        )
        let start = range.location
        let end = NSMaxRange(range)
        let prefix = start > 0 ? "…" : ""
        let suffix = end < source.length ? "…" : ""
        return (
            prefix + source.substring(with: NSRange(location: start, length: end - start)) + suffix,
            NSRange(
                location: match.location - start + (prefix as NSString).length,
                length: match.length
            )
        )
    }

    private static func comparisonKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive], locale: locale)
    }
}

extension NotebookSearchResult: Comparable {
    public static func < (left: Self, right: Self) -> Bool {
        if left.rank != right.rank { return left.rank < right.rank }
        let title = comparisonKey(left.title).compare(comparisonKey(right.title))
        if title != .orderedSame { return title == .orderedAscending }
        let path = comparisonKey(left.path).compare(comparisonKey(right.path))
        if path != .orderedSame { return path == .orderedAscending }
        return left.id.uuidString < right.id.uuidString
    }
}
