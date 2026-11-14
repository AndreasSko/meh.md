import Foundation

/// Readwise's export API (https://readwise.io/api_deets): books with their
/// highlights. A new or missing optional field does not stop a sync. A
/// highlight that cannot be read makes its book incomplete: applying it
/// would look like that highlight was deleted, so the book waits instead.
public enum Readwise {
    public static let service = "readwise"

    /// What an import brings, such as "2 Books and 1 Article". Readwise's
    /// own picks are left out, as the import leaves them out by default.
    public static func describe(_ counts: [String: Int]) -> String {
        let names = [("books", "Book", "Books"), ("articles", "Article", "Articles"),
                     ("tweets", "Tweet", "Tweets"), ("podcasts", "Podcast", "Podcasts")]
        let parts = names.compactMap { key, one, many -> String? in
            guard let count = counts[key], count > 0 else { return nil }
            return "\(count) \(count == 1 ? one : many)"
        }
        return ListFormatter.localizedString(byJoining: parts)
    }

    public struct Book: Decodable, Equatable, Sendable {
        public let id: Int
        public let title: String?
        public let readableTitle: String?
        public let author: String?
        public let category: String?
        public let sourceURL: String?
        public let coverImageURL: String?
        public let readwiseURL: String?
        public let summary: String?
        public let documentNote: String?
        public let tags: [String]
        public let isDeleted: Bool
        public let highlights: [Highlight]
        /// Every highlight Readwise sent could be read.
        public let isComplete: Bool

        enum CodingKeys: String, CodingKey {
            case id = "user_book_id", title, readableTitle = "readable_title", author, category
            case sourceURL = "source_url", coverImageURL = "cover_image_url"
            case readwiseURL = "readwise_url", summary, documentNote = "document_note"
            case tags = "book_tags", isDeleted = "is_deleted", highlights
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(Int.self, forKey: .id)
            title = try? container.decodeIfPresent(String.self, forKey: .title)
            readableTitle = try? container.decodeIfPresent(String.self, forKey: .readableTitle)
            author = try? container.decodeIfPresent(String.self, forKey: .author)
            category = try? container.decodeIfPresent(String.self, forKey: .category)
            sourceURL = try? container.decodeIfPresent(String.self, forKey: .sourceURL)
            coverImageURL = try? container.decodeIfPresent(String.self, forKey: .coverImageURL)
            readwiseURL = try? container.decodeIfPresent(String.self, forKey: .readwiseURL)
            summary = try? container.decodeIfPresent(String.self, forKey: .summary)
            documentNote = try? container.decodeIfPresent(String.self, forKey: .documentNote)
            tags = ((try? container.decodeIfPresent([Tag].self, forKey: .tags)) ?? nil)?
                .map(\.name) ?? []
            isDeleted = ((try? container.decodeIfPresent(Bool.self, forKey: .isDeleted)) ?? nil) ?? false
            // Only a list counts: a missing or null list says nothing about
            // the highlights already in the note.
            let decoded = try? container.decode([Lenient<Highlight>].self, forKey: .highlights)
            highlights = decoded?.compactMap(\.value) ?? []
            isComplete = decoded?.allSatisfy { $0.value != nil } ?? false
        }

        public init(
            id: Int, title: String, author: String? = nil, category: String = "books",
            sourceURL: String? = nil, tags: [String] = [], isDeleted: Bool = false,
            highlights: [Highlight]
        ) {
            self.id = id
            self.title = title
            readableTitle = title
            self.author = author
            self.category = category
            self.sourceURL = sourceURL
            coverImageURL = nil
            readwiseURL = "https://readwise.io/bookreview/\(id)"
            summary = nil
            documentNote = nil
            self.tags = tags
            self.isDeleted = isDeleted
            self.highlights = highlights
            isComplete = true
        }
    }

    public struct Highlight: Decodable, Equatable, Sendable {
        public let id: Int
        public let text: String
        public let note: String?
        public let location: Int?
        public let locationType: String?
        public let url: String?
        public let readwiseURL: String?
        public let color: String?
        public let highlightedAt: Date?
        public let tags: [String]
        public let isDeleted: Bool
        public let isDiscard: Bool

        enum CodingKeys: String, CodingKey {
            case id, text, note, location, locationType = "location_type", url
            case readwiseURL = "readwise_url", color, highlightedAt = "highlighted_at", tags
            case isDeleted = "is_deleted", isDiscard = "is_discard"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(Int.self, forKey: .id)
            text = try container.decode(String.self, forKey: .text)
            note = try? container.decodeIfPresent(String.self, forKey: .note)
            location = try? container.decodeIfPresent(Int.self, forKey: .location)
            locationType = try? container.decodeIfPresent(String.self, forKey: .locationType)
            url = try? container.decodeIfPresent(String.self, forKey: .url)
            readwiseURL = try? container.decodeIfPresent(String.self, forKey: .readwiseURL)
            color = try? container.decodeIfPresent(String.self, forKey: .color)
            highlightedAt = (try? container.decodeIfPresent(String.self, forKey: .highlightedAt))
                .flatMap { $0 }.flatMap(Readwise.date)
            tags = ((try? container.decodeIfPresent([Tag].self, forKey: .tags)) ?? nil)?.map(\.name) ?? []
            isDeleted = ((try? container.decodeIfPresent(Bool.self, forKey: .isDeleted)) ?? nil) ?? false
            isDiscard = ((try? container.decodeIfPresent(Bool.self, forKey: .isDiscard)) ?? nil) ?? false
        }

        public init(
            id: Int, text: String, note: String? = nil, location: Int? = nil,
            locationType: String = "location",
            tags: [String] = [], highlightedAt: Date? = nil, isDeleted: Bool = false
        ) {
            self.id = id
            self.text = text
            self.note = note
            self.location = location
            self.locationType = location == nil ? nil : locationType
            url = nil
            readwiseURL = "https://readwise.io/open/\(id)"
            color = nil
            self.highlightedAt = highlightedAt
            self.tags = tags
            self.isDeleted = isDeleted
            isDiscard = false
        }
    }

    public struct ExportPage: Decodable, Sendable {
        /// Books in the whole export, not only this page.
        public let count: Int?
        public let results: [Book]
        public let nextPageCursor: String?

        enum CodingKeys: String, CodingKey {
            case count, results, nextPageCursor
        }

        public init(results: [Book], nextPageCursor: String?, count: Int? = nil) {
            self.count = count ?? results.count
            self.results = results
            self.nextPageCursor = nextPageCursor
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            count = (try? container.decodeIfPresent(Int.self, forKey: .count)) ?? nil
            // A book that cannot be read at all has no ID to wait for, so
            // the whole page fails and the sync tries again later.
            results = try container.decode([Book].self, forKey: .results)
            // A cursor that cannot be read must not look like the last page.
            nextPageCursor = try container.decodeIfPresent(String.self, forKey: .nextPageCursor)
        }
    }

    struct Tag: Decodable { let name: String }

    /// One unreadable entry is skipped instead of failing the whole page.
    struct Lenient<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

// MARK: - Client

public enum ReadwiseError: Error, Equatable, LocalizedError {
    case invalidToken
    case rateLimited(retryAfter: TimeInterval)
    case server(Int)
    case unreadableResponse

    public var errorDescription: String? {
        switch self {
        case .invalidToken: "Readwise did not accept the access token."
        case .rateLimited: "Readwise asked to wait a moment. Sync tries again later."
        case .server(let status): "Readwise could not be reached (\(status))."
        case .unreadableResponse: "Readwise sent a response meh.md could not read."
        }
    }
}

/// Where Readwise data comes from: the API, or fixtures in tests.
public protocol ReadwiseSource: Sendable {
    func checkToken() async throws
    /// One page of books. With `updatedAfter`, books only carry the
    /// highlights updated since then; with `ids`, every highlight.
    func export(
        updatedAfter: Date?, ids: [Int]?, includeDeleted: Bool, cursor: String?
    ) async throws -> Readwise.ExportPage
    /// How many books each category holds, for setup to say what it
    /// imports.
    func bookCounts() async throws -> [String: Int]
}

extension ReadwiseSource {
    /// Counts the first export page, which is all of a small library.
    public func bookCounts() async throws -> [String: Int] {
        let page = try await export(updatedAfter: nil, ids: nil, includeDeleted: false, cursor: nil)
        return page.results.reduce(into: [:]) { $0[ReadwiseRenderer.categoryKey($1.category), default: 0] += 1 }
    }
}

public struct ReadwiseClient: ReadwiseSource {
    public let token: String
    public let baseURL: URL
    let session: URLSession

    public init(
        token: String, baseURL: URL = URL(string: "https://readwise.io")!,
        session: URLSession = .shared
    ) {
        self.token = token
        self.baseURL = baseURL
        self.session = session
    }

    public func checkToken() async throws {
        let (_, response) = try await session.data(for: request("api/v2/auth/", query: []))
        try Self.check(response)
    }

    public func export(
        updatedAfter: Date?, ids: [Int]?, includeDeleted: Bool, cursor: String?
    ) async throws -> Readwise.ExportPage {
        var query: [URLQueryItem] = []
        if let updatedAfter {
            query.append(.init(name: "updatedAfter", value: ISO8601DateFormatter().string(from: updatedAfter)))
        }
        if let ids { query.append(.init(name: "ids", value: ids.map(String.init).joined(separator: ","))) }
        if includeDeleted { query.append(.init(name: "includeDeleted", value: "true")) }
        if let cursor { query.append(.init(name: "pageCursor", value: cursor)) }
        let (data, response) = try await session.data(for: request("api/v2/export/", query: query))
        try Self.check(response)
        do { return try JSONDecoder().decode(Readwise.ExportPage.self, from: data) }
        catch { throw ReadwiseError.unreadableResponse }
    }

    /// One small request per category: the books list reports its count.
    public func bookCounts() async throws -> [String: Int] {
        struct List: Decodable { let count: Int }
        var counts: [String: Int] = [:]
        for category in ["books", "articles", "tweets", "podcasts", "supplementals"] {
            let (data, response) = try await session.data(for: request("api/v2/books/", query: [
                .init(name: "category", value: category), .init(name: "page_size", value: "1"),
            ]))
            try Self.check(response)
            guard let list = try? JSONDecoder().decode(List.self, from: data) else {
                throw ReadwiseError.unreadableResponse
            }
            counts[category] = list.count
        }
        return counts
    }

    private func request(_ path: String, query: [URLQueryItem]) -> URLRequest {
        var components = URLComponents(
            url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ReadwiseError.unreadableResponse }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403: throw ReadwiseError.invalidToken
        case 429:
            let wait = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 60
            throw ReadwiseError.rateLimited(retryAfter: wait)
        default: throw ReadwiseError.server(http.statusCode)
        }
    }
}
