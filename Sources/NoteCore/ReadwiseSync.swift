import Foundation

/// Turns Readwise books into integration items with a Jinja template. The
/// built-in layout has no title heading: the note's name already shows it.
/// Each pass of the template's `{% for highlight in highlights %}` loop is
/// one highlight block; the text before the loop is the header and the
/// text after it the footer. A template without that loop makes the whole
/// note one block.
public struct ReadwiseRenderer: Sendable {
    /// Raise this whenever the built-in layout or the rendering changes, so
    /// an older syncing device pauses instead of writing the old layout.
    public static let version = 2

    public static let defaultTemplate = """
        ---
        {% if author %}author: {{ author | yaml }}
        {% endif %}{% if url %}url: {{ url }}
        {% endif %}{% if document_tags %}tags: {{ document_tags | yaml }}
        {% endif %}---
        {% for highlight in highlights %}
        {{ highlight_text | blockquote }}
        {% if block_id %}
        {{ block_id }}
        {% endif %}
        {% if highlight_note %}{{ highlight_note | emphasis }} · {% endif %}{% for tag in highlight_tags %}#{{ tag | hashtag }} · {% endfor %}[{{ highlight_location_label }}]({{ highlight_url }})
        {% endfor %}

        """

    public struct Options: Equatable, Sendable {
        public var blockIDs: Bool
        public var timeZone: TimeZone

        public init(blockIDs: Bool = true, timeZone: TimeZone = .current) {
            self.blockIDs = blockIDs
            self.timeZone = timeZone
        }
    }

    let template: JinjaTemplate
    /// The template text, which decides whether notes need rendering again.
    public let source: String
    let header: [JinjaTemplate.Node]
    let loop: (variable: String, body: [JinjaTemplate.Node])?
    let footer: [JinjaTemplate.Node]
    public let options: Options

    public init(template source: String = Self.defaultTemplate, options: Options = Options()) throws {
        template = try JinjaTemplate(source)
        self.source = source
        self.options = options
        let index = template.nodes.firstIndex {
            if case .loop(_, .variable(["highlights"]), _, _) = $0 { return true }
            return false
        }
        if let index, case .loop(let variable, _, let body, _) = template.nodes[index] {
            header = Array(template.nodes[..<index])
            loop = (variable, body)
            footer = Array(template.nodes[(index + 1)...])
        } else {
            header = template.nodes
            loop = nil
            footer = []
        }
    }

    public func item(for book: Readwise.Book) throws -> NotebookIntegrationItem {
        let title = book.readableTitle ?? book.title ?? "Untitled"
        let highlights = book.highlights
            .filter { !$0.isDeleted && !$0.isDiscard }
            .sorted { ($0.location ?? .max, $0.id) < ($1.location ?? .max, $1.id) }
        let category = Self.categoryKey(book.category)
        var values = Self.values(book, title: title)
        values["highlights"] = .list(highlights.map {
            .dict(Self.highlightValues($0, blockID: options.blockIDs ? "^rw-\($0.id)" : nil))
        })
        let context = JinjaTemplate.Context(timeZone: options.timeZone, aliases: ["highlights": "highlight_"])
        let budget = JinjaTemplate.Budget()
        var blocks: [NotebookIntegrationBlock] = []
        if let loop {
            var scope = JinjaTemplate.Scope(values: values)
            blocks.append(.init(key: NotebookIntegrationBlock.headerKey, text: Self.tidy(
                try JinjaTemplate.render(header, &scope, context, budget: budget))))
            for highlight in highlights {
                let blockID = options.blockIDs ? "^rw-\(highlight.id)" : ""
                var inner = scope
                let fields = Self.highlightValues(highlight, blockID: blockID)
                inner.values[loop.variable] = .dict(fields)
                for (key, value) in fields { inner.values["highlight_" + key] = value }
                inner.values["block_id"] = .string(blockID)
                var text = Self.tidy(
                    try JinjaTemplate.render(loop.body, &inner, context, budget: budget, depth: 1))
                // A template may leave a highlight out on purpose.
                guard !text.isEmpty else { continue }
                // A template that leaves the ID out gets it added, so
                // Highlight Links always has a target.
                if options.blockIDs, !text.contains(blockID) { text = Self.addBlockID(blockID, to: text) }
                blocks.append(.init(key: "rw-\(highlight.id)", text: text))
            }
            let end = Self.tidy(try JinjaTemplate.render(footer, &scope, context, budget: budget))
            if !end.isEmpty { blocks.append(.init(key: "footer", text: end)) }
        } else {
            let text = Self.tidy(try template.render(values, context: context))
            blocks.append(.init(key: NotebookIntegrationBlock.headerKey, text: text))
        }
        return NotebookIntegrationItem(
            key: String(book.id), name: NotebookIntegrationItem.noteName(for: title),
            folder: .init(key: category, name: Self.folderName(category)),
            blocks: blocks, isRemoved: book.isDeleted, url: book.readwiseURL.flatMap(URL.init))
    }

    /// A highlight's fields, as `highlight.text` or `highlight_text`.
    static let highlightFields: Set<String> = [
        "id", "text", "note", "location", "location_label", "location_url", "url", "color", "tags",
        "highlighted_at",
    ]

    /// Names a template can read. Loop variables and `set` add their own.
    static let knownNames = Set([
        "title", "full_title", "author", "category", "url", "source_url", "image_url",
        "readwise_url", "summary", "document_note", "document_tags", "highlights", "block_id",
    ] + highlightFields.map { "highlight_" + $0 })

    /// Checks a template before it is used: it must parse, read only known
    /// names, and render a sample book.
    public static func validate(_ source: String) throws {
        let renderer = try ReadwiseRenderer(template: source)
        if let name = renderer.template.unknownVariables(
            known: knownNames, lists: ["highlights": highlightFields.union(["block_id"])]).first
        {
            throw JinjaTemplateError(message: "Unknown variable \(name)", line: 0)
        }
        _ = try renderer.item(for: Readwise.Book(
            id: 1, title: "Sample", author: "Someone", sourceURL: "https://example.com",
            tags: ["sample"], highlights: [
                .init(id: 1, text: "First", note: "A note", location: 1, tags: ["tag"],
                      highlightedAt: Date(timeIntervalSince1970: 0)),
                .init(id: 2, text: "Second", location: 2),
            ]))
    }

    static func values(_ book: Readwise.Book, title: String) -> [String: JinjaValue] {
        func string(_ value: String?) -> JinjaValue { value.map { .string($0) } ?? .none }
        return [
            "title": .string(title), "full_title": string(book.title),
            "author": string(book.author), "category": string(book.category),
            "url": string(book.sourceURL), "source_url": string(book.sourceURL),
            "image_url": string(book.coverImageURL), "readwise_url": string(book.readwiseURL),
            "summary": string(book.summary), "document_note": string(book.documentNote),
            "document_tags": .list(book.tags.map { .string($0) }),
        ]
    }

    static func highlightValues(_ highlight: Readwise.Highlight, blockID: String?) -> [String: JinjaValue] {
        func string(_ value: String?) -> JinjaValue { value.map { .string($0) } ?? .none }
        var values: [String: JinjaValue] = [
            "id": .string(String(highlight.id)), "text": .string(highlight.text),
            "note": string(highlight.note), "location": highlight.location.map { .number(Double($0)) } ?? .none,
            "location_url": string(highlight.url), "url": string(highlight.readwiseURL),
            "color": string(highlight.color), "tags": .list(highlight.tags.map { .string($0) }),
            "highlighted_at": highlight.highlightedAt.map { .date($0) } ?? .none,
            "location_label": .string(locationLabel(highlight)),
        ]
        if let blockID { values["block_id"] = .string(blockID) }
        return values
    }

    /// Where a highlight is, short enough for a link: a page, a Kindle
    /// location or a time in a podcast. Readwise's other kinds of location
    /// only order highlights, so they get an arrow.
    static func locationLabel(_ highlight: Readwise.Highlight) -> String {
        guard let location = highlight.location else { return "↗" }
        switch highlight.locationType {
        case "page": return "p. \(location)"
        case "location": return "Loc. \(location)"
        case "time_offset":
            let hours = location / 3600, minutes = location / 60 % 60, seconds = location % 60
            return hours > 0
                ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
                : String(format: "%d:%02d", minutes, seconds)
        default: return "↗"
        }
    }

    /// The category as a folder key: lowercase letters, digits and dashes.
    static func categoryKey(_ category: String?) -> String {
        let key = String((category ?? "books").lowercased().unicodeScalars.map {
            $0.isASCII && CharacterSet.alphanumerics.contains($0) ? Character($0) : "-"
        })
        return key.isEmpty ? "books" : key
    }

    static func folderName(_ key: String) -> String {
        ["books": "Books", "articles": "Articles", "tweets": "Tweets", "podcasts": "Podcasts",
         "supplementals": "Supplementals"][key] ?? key.replacingOccurrences(of: "-", with: " ").capitalized
    }

    /// Trailing spaces go, runs of blank lines become one, and the block
    /// has no blank lines around it.
    static func tidy(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n").map {
            String($0.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
        }
        var result: [String] = []
        for line in lines where !(line.isEmpty && (result.last?.isEmpty ?? true)) {
            result.append(line)
        }
        lines = result
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// Obsidian wants a quote's block ID on its own line after the quote.
    static func addBlockID(_ blockID: String, to text: String) -> String {
        guard let paragraph = text.range(of: "\n\n") else { return text + "\n\n" + blockID }
        return text[..<paragraph.lowerBound] + "\n\n" + blockID + text[paragraph.lowerBound...]
    }
}

/// Brings Readwise into the notebook: finds the books that changed, fetches
/// them in full, renders them and hands them to the integration engine in
/// batches. Progress is kept on this device only.
@MainActor
public final class ReadwiseSync {
    public struct Progress: Codable, Equatable, Sendable {
        /// Books changed since this time are fetched next.
        public var since: Date?
        /// Books to fetch again: their notes had not downloaded yet, or
        /// Readwise sent highlights that could not be read.
        public var pending: [Int] = []
        /// The template text last checked without errors.
        public var lastGoodTemplate: String?
        /// Books asked to come back, kept until their notes exist.
        public var bringingBack: [Int] = []
        /// What every note was last rendered with. When the template, a
        /// display setting or the renderer changes, on any device, every
        /// book is fetched and rendered again.
        public var rendered: String?
        /// When every book was last fetched and rendered.
        public var fullSync: Date?
    }

    /// Every week every book is fetched and rendered again. That repairs a
    /// highlight an older device's late change put back, even when
    /// Readwise never changes that book again.
    static let fullSyncInterval: TimeInterval = 7 * 24 * 60 * 60

    /// The template to render with, see `template(now:)`.
    public struct Template: Sendable {
        public let source: String
        /// Why the template note could not be used, if it could not.
        public let error: String?
        /// Another device rendered with a newer version of the template
        /// note than this device has received.
        public let waiting: Bool
        let version: String?
    }

    public struct Summary: Equatable, Sendable {
        public var created = 0
        public var updated = 0
        public var pending = 0
    }

    public let updates: NotebookIntegrationUpdates
    let source: any ReadwiseSource
    let progressURL: URL
    public var batchSize = 25
    /// Runs before each batch, so the app can let iCloud sync go first, or
    /// stop the sync by throwing.
    public var beforeBatch: @MainActor () async throws -> Void = {}
    /// Books done and how many there are, when that is known.
    public var onProgress: @MainActor (Int, Int?) -> Void = { _, _ in }

    public init(updates: NotebookIntegrationUpdates, source: any ReadwiseSource, progressURL: URL) {
        self.updates = updates
        self.source = source
        self.progressURL = progressURL
    }

    public var progress: Progress {
        (try? Data(contentsOf: progressURL)).flatMap {
            try? JSONDecoder().decode(Progress.self, from: $0)
        } ?? Progress()
    }

    /// The template note's text, or the built-in layout. A template edited
    /// in the last minute is still being written, so the last good version
    /// is used until it settles. A template that fails its check keeps the
    /// last good version too.
    public func template(now: Date = Date()) async throws -> Template {
        let settings = try updates.settings()
        var progress = progress
        guard let id = settings["template"].flatMap(UUID.init) else {
            return Template(source: ReadwiseRenderer.defaultTemplate, error: nil, waiting: false, version: nil)
        }
        let fallback = progress.lastGoodTemplate ?? ReadwiseRenderer.defaultTemplate
        guard let note = try await updates.replica.integrationNote(id) else {
            return Template(source: fallback, error: "The template note is unavailable.",
                            waiting: false, version: nil)
        }
        // The version names its note, so choosing another template note
        // never waits for the history of the previous one.
        let version = id.uuidString + ":" + note.heads.sorted().joined(separator: ",")
        if let stored = settings["templateVersion"], stored != version,
           stored.hasPrefix(id.uuidString + ":")
        {
            let needed = Set(stored.dropFirst(id.uuidString.count + 1).split(separator: ",").map(String.init))
            if !needed.isSubset(of: note.historyHeads) {
                return Template(source: fallback, error: nil, waiting: true, version: nil)
            }
        }
        if let modified = try note.metadata.modifiedAt, now.timeIntervalSince(modified) < 60 {
            return Template(source: fallback, error: nil, waiting: false, version: nil)
        }
        let text = try note.text
        do {
            try await Task.detached(priority: .utility) { try ReadwiseRenderer.validate(text) }.value
        } catch {
            return Template(source: fallback, error: error.localizedDescription,
                            waiting: false, version: nil)
        }
        if progress.lastGoodTemplate != text {
            progress.lastGoodTemplate = text
            try save(progress)
        }
        return Template(source: text, error: nil, waiting: false, version: version)
    }

    /// Records the template version every note was rendered with, so a
    /// device that has not received it yet waits.
    public func templateUsed(_ template: Template) async throws {
        guard let version = template.version,
              try updates.settings()["templateVersion"] != version else { return }
        try await updates.setSetting("templateVersion", version)
    }

    /// Asks the next runs to bring these books back until their notes
    /// exist.
    public func bringBack(_ ids: Set<Int>) throws {
        var progress = progress
        let all = ids.union(progress.bringingBack)
        guard all.count != progress.bringingBack.count else { return }
        progress.bringingBack = all.sorted()
        try save(progress)
    }

    public func run(
        renderer: ReadwiseRenderer, includeSupplementals: Bool = false,
        bringingBack: Set<Int> = [], now: Date = Date()
    ) async throws -> Summary {
        let started = now
        let rendered = Self.rendering(renderer, includeSupplementals: includeSupplementals)
        var progress = progress
        // A request to bring a book back is saved first, so it survives a
        // failed run or a book that has to wait.
        try bringBack(bringingBack)
        progress = self.progress
        let bringingBack = Set(progress.bringingBack)
        let full = progress.since == nil || progress.rendered != rendered || !bringingBack.isEmpty
            || progress.fullSync.map { now.timeIntervalSince($0) > Self.fullSyncInterval } ?? true
        var summary = Summary()
        var pending: Set<Int> = []
        var done = 0
        var total: Int?
        func include(_ book: Readwise.Book) -> Bool {
            includeSupplementals || ReadwiseRenderer.categoryKey(book.category) != "supplementals"
        }
        func apply(_ books: [Readwise.Book], bringingBack: Set<Int> = []) async throws {
            // A full run compares every note block by block, which also
            // repairs a block another device's late change set back.
            let report = try await self.apply(books, renderer, bringingBack, force: full)
            done += books.count
            onProgress(done, total)
            summary.created += report.created.count
            summary.updated += report.updated.count
            pending.formUnion(report.pending.compactMap(Int.init))
        }

        // Books changed or deleted since the last sync, also before a full
        // sync, which does not list deleted books. With `updatedAfter` a
        // book only lists its changed highlights, so changed books are
        // fetched again by ID with all of them.
        var changed = Set(progress.pending)
        if let since = progress.since?.addingTimeInterval(-60) {
            var cursor: String?
            var removed: [Readwise.Book] = []
            repeat {
                let page = try await source.export(
                    updatedAfter: since, ids: nil, includeDeleted: true, cursor: cursor)
                for book in page.results {
                    if book.isDeleted { removed.append(book) } else { changed.insert(book.id) }
                }
                cursor = page.nextPageCursor
            } while cursor != nil
            if !removed.isEmpty { try await apply(removed) }
            done = 0
        }

        if full {
            var cursor: String?
            repeat {
                let page = try await source.export(
                    updatedAfter: nil, ids: nil, includeDeleted: false, cursor: cursor)
                if total == nil { total = page.count }
                // A book asked to come back is included even when its
                // category is hidden, or its note would stay in Trash.
                let included = page.results.filter { include($0) || bringingBack.contains($0.id) }
                try await apply(included, bringingBack: bringingBack)
                // Skipped books count as done, so progress reaches its total.
                if included.count < page.results.count {
                    done += page.results.count - included.count
                    onProgress(done, total)
                }
                cursor = page.nextPageCursor
            } while cursor != nil
        } else {
            let ids = changed.sorted()
            total = ids.count
            for start in stride(from: 0, to: ids.count, by: 50) {
                var cursor: String?
                repeat {
                    let page = try await source.export(
                        updatedAfter: nil, ids: Array(ids[start..<min(start + 50, ids.count)]),
                        includeDeleted: false, cursor: cursor)
                    try await apply(page.results.filter(include))
                    cursor = page.nextPageCursor
                } while cursor != nil
            }
        }
        try Task.checkCancellation()
        // The template check may have saved meanwhile, so start from the
        // file as it is now.
        progress = self.progress
        progress.since = started
        progress.pending = pending.sorted()
        progress.bringingBack = bringingBack.intersection(pending).sorted()
        if full {
            progress.rendered = rendered
            progress.fullSync = started
        }
        try save(progress)
        summary.pending = pending.count
        return summary
    }

    /// Whether the notes were rendered with something else, so the next
    /// sync fetches and renders every book.
    public func needsFullRender(_ renderer: ReadwiseRenderer, includeSupplementals: Bool) -> Bool {
        progress.rendered != Self.rendering(renderer, includeSupplementals: includeSupplementals)
    }

    private static func rendering(_ renderer: ReadwiseRenderer, includeSupplementals: Bool) -> String {
        NoteDocument.integrationHash([
            String(ReadwiseRenderer.version), String(renderer.options.blockIDs),
            renderer.options.timeZone.identifier, String(includeSupplementals), renderer.source,
        ].joined(separator: "\u{0}"))
    }

    /// Renders off the main actor, a batch at a time after iCloud's turn,
    /// and hands complete books to the engine. Incomplete books wait.
    private func apply(
        _ books: [Readwise.Book], _ renderer: ReadwiseRenderer, _ bringingBack: Set<Int>,
        force: Bool
    ) async throws -> NotebookIntegrationUpdates.Report {
        var total = NotebookIntegrationUpdates.Report()
        total.pending = books.filter { !$0.isComplete && !$0.isDeleted }.map { String($0.id) }
        let complete = books.filter { $0.isComplete || $0.isDeleted }
        for start in stride(from: 0, to: complete.count, by: batchSize) {
            try await beforeBatch()
            let batch = Array(complete[start..<min(start + batchSize, complete.count)])
            let rendering = Task.detached(priority: .utility) {
                try batch.map { try renderer.item(for: $0) }
            }
            let items = try await withTaskCancellationHandler {
                try await rendering.value
            } onCancel: {
                rendering.cancel()
            }
            try Task.checkCancellation()
            let report = try await updates.apply(
                items, bringingBack: Set(bringingBack.map(String.init)), message: "Readwise",
                force: force)
            total.created += report.created
            total.updated += report.updated
            total.pending += report.pending
        }
        return total
    }

    private func save(_ progress: Progress) throws {
        try FileManager.default.createDirectory(
            at: progressURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(progress).write(to: progressURL, options: .atomic)
    }
}
