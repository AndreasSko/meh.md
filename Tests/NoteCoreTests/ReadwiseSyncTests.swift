import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class ReadwiseSyncTests: XCTestCase {
    private var roots: [URL] = []
    private let device = NotebookIntegrationDevice(id: UUID(), kind: "iPhone")
    private let berlin = ReadwiseRenderer.Options(timeZone: TimeZone(identifier: "Europe/Berlin")!)

    override func tearDown() async throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
    }

    func testTheBuiltInLayout() throws {
        let book = Readwise.Book(
            id: 7, title: "Atomic Habits", author: "James Clear", sourceURL: "https://example.com/b",
            tags: ["habits"], highlights: [
                .init(id: 2, text: "Second", location: 20, tags: ["focus"]),
                .init(id: 1, text: "First\nline", note: "Mine", location: 10),
            ])
        let item = try ReadwiseRenderer(options: berlin).item(for: book)
        XCTAssertEqual(item.key, "7")
        XCTAssertEqual(item.name, "Atomic Habits.md")
        XCTAssertEqual(item.folder, .init(key: "books", name: "Books"))
        XCTAssertEqual(item.blocks.map(\.text), [
            "---\nauthor: James Clear\nurl: https://example.com/b\ntags: [habits]\n---",
            "> First\n> line\n\n^rw-1\n\n*Mine* · [Loc. 10](https://readwise.io/open/1)",
            "> Second\n\n^rw-2\n\n#focus · [Loc. 20](https://readwise.io/open/2)",
        ])
        XCTAssertEqual(item.blocks.map(\.key), ["header", "rw-1", "rw-2"])
    }

    func testBlockIDsCanBeTurnedOffAndAreAddedWhenATemplateLeavesThemOut() throws {
        let book = Readwise.Book(id: 1, title: "B", highlights: [.init(id: 5, text: "Quote")])
        let off = try ReadwiseRenderer(options: .init(blockIDs: false)).item(for: book)
        XCTAssertFalse(off.blocks[1].text.contains("^rw-"))
        let custom = try ReadwiseRenderer(template: """
            # {{ title }}
            {% for highlight in highlights %}
            - {{ highlight_text }}
            {% endfor %}
            """).item(for: book)
        XCTAssertEqual(custom.blocks[1].text, "- Quote\n\n^rw-5")
    }

    func testDiscardedAndDeletedHighlightsAreLeftOut() throws {
        let book = Readwise.Book(id: 1, title: "B", highlights: [
            .init(id: 1, text: "Kept"), .init(id: 2, text: "Gone", isDeleted: true),
        ])
        XCTAssertEqual(try ReadwiseRenderer().item(for: book).blocks.count, 2)
    }

    /// Unknown fields are ignored. A highlight that cannot be read makes its
    /// book incomplete, and a book that cannot be read fails the page.
    func testDecodingMarksWhatItCannotRead() throws {
        let json = """
            {"count": 2, "nextPageCursor": null, "results": [
              {"user_book_id": 1, "title": "Ok", "category": "articles", "book_tags": [{"id": 1, "name": "t"}],
               "highlights": [{"id": 3, "text": "Hi", "highlighted_at": "2026-01-02T03:04:05.123Z",
                               "tags": [{"name": "x"}], "unknown": 1}, {"text": "no id"}]},
              {"user_book_id": 2, "title": "Complete", "highlights": [], "unknown": 1}
            ]}
            """
        let page = try JSONDecoder().decode(Readwise.ExportPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.results.map(\.id), [1, 2])
        XCTAssertEqual(page.results[0].highlights.map(\.id), [3])
        XCTAssertFalse(page.results[0].isComplete)
        XCTAssertTrue(page.results[1].isComplete)
        XCTAssertEqual(page.results[0].tags, ["t"])
        XCTAssertNotNil(page.results[0].highlights[0].highlightedAt)
        let broken = #"{"count": 1, "nextPageCursor": null, "results": [{"title": "no id"}]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(Readwise.ExportPage.self, from: Data(broken.utf8)))
    }

    func testTheFirstSyncImportsEverythingAndLaterSyncsOnlyChangedBooks() async throws {
        let source = FakeReadwise()
        source.books = [book(1, ["One", "Two"]), book(2, ["Other"])]
        let (replica, sync) = try await connected(source)
        let first = try await sync.run(renderer: try ReadwiseRenderer())
        XCTAssertEqual(first.created, 2)
        XCTAssertNotNil(sync.progress.since)

        source.books[0] = book(1, ["One changed", "Two"])
        source.changed = [1]
        let second = try await sync.run(renderer: try ReadwiseRenderer())
        XCTAssertEqual(second, .init(created: 0, updated: 1, pending: 0))
        XCTAssertEqual(source.fetchedIDs, [[1]])
        let id = try XCTUnwrap(sync.updates.record(forItem: "1")?.note)
        let note = try await replica.integrationNote(id)
        XCTAssertTrue(try XCTUnwrap(note).text.contains("> One changed"))
    }

    func testABookDeletedInReadwiseKeepsItsNote() async throws {
        let source = FakeReadwise()
        source.books = [book(1, ["One"])]
        let (_, sync) = try await connected(source)
        _ = try await sync.run(renderer: try ReadwiseRenderer())
        source.deleted = [1]
        _ = try await sync.run(renderer: try ReadwiseRenderer())
        XCTAssertEqual(try sync.updates.record(forItem: "1")?.state, NotebookIntegrationRecord.removed)
    }

    func testSupplementalsAreHiddenUnlessShown() async throws {
        let source = FakeReadwise()
        source.books = [book(1, ["One"]), book(2, ["Daily"], category: "supplementals")]
        let (_, sync) = try await connected(source)
        let hidden = try await sync.run(renderer: try ReadwiseRenderer())
        XCTAssertEqual(hidden.created, 1)
        let shown = try await sync.run(renderer: try ReadwiseRenderer(), includeSupplementals: true)
        XCTAssertEqual(shown.created, 1)
    }

    func testDeleteAndReimportMakesAFreshNote() async throws {
        let source = FakeReadwise()
        source.books = [book(1, ["One"])]
        let (replica, sync) = try await connected(source)
        _ = try await sync.run(renderer: try ReadwiseRenderer())
        let old = try XCTUnwrap(sync.updates.record(forItem: "1")?.note)
        try await replica.setTrashed(old, true)
        let again = try await sync.run(renderer: try ReadwiseRenderer(), bringingBack: [1])
        XCTAssertEqual(again.created, 1)
        XCTAssertNotEqual(try sync.updates.record(forItem: "1")?.note, old)
    }

    func testTheTemplateNoteIsLeftOutOfLinks() async throws {
        let (replica, sync) = try await connected(FakeReadwise())
        let template = try await replica.createNote(name: "Readwise Template.md", text: "[[{{ author }}]]")
        try await sync.updates.setSetting("template", template.uuidString)
        let corpus = try await replica.linkCorpus()
        XCTAssertEqual(corpus.texts[template], "")
        XCTAssertTrue(corpus.notes.contains { $0.id == template })
    }

    func testABookWithAnUnreadableHighlightWaitsInsteadOfLosingIt() async throws {
        let source = FakeReadwise()
        source.books = [book(1, ["One", "Two"])]
        let (replica, sync) = try await connected(source)
        _ = try await sync.run(renderer: try ReadwiseRenderer())
        let json = #"{"user_book_id": 1, "title": "Book 1", "highlights": [{"id": 100, "text": "One"}, {"id": 101}]}"#
        source.books = [try JSONDecoder().decode(Readwise.Book.self, from: Data(json.utf8))]
        source.changed = [1]
        let summary = try await sync.run(renderer: try ReadwiseRenderer())
        XCTAssertEqual(summary.pending, 1)
        XCTAssertEqual(sync.progress.pending, [1])
        let id = try XCTUnwrap(sync.updates.record(forItem: "1")?.note)
        let note = try await replica.integrationNote(id)
        XCTAssertTrue(try XCTUnwrap(note).text.contains("> Two"))
    }

    func testChangedDisplaySettingsRenderEveryBookAgain() async throws {
        let source = FakeReadwise()
        source.books = [book(1, ["One"]), book(2, ["Two"])]
        let (_, sync) = try await connected(source)
        _ = try await sync.run(renderer: try ReadwiseRenderer())
        // Nothing changed in Readwise, but block IDs were turned off, maybe
        // on another device.
        let off = try ReadwiseRenderer(options: .init(blockIDs: false))
        XCTAssertTrue(sync.needsFullRender(off, includeSupplementals: false))
        let summary = try await sync.run(renderer: off)
        XCTAssertEqual(summary.updated, 2)
        XCTAssertFalse(sync.needsFullRender(off, includeSupplementals: false))
    }

    func testAFullSyncStillAppliesDeletions() async throws {
        let source = FakeReadwise()
        source.books = [book(1, ["One"]), book(2, ["Two"])]
        let (_, sync) = try await connected(source)
        _ = try await sync.run(renderer: try ReadwiseRenderer())
        source.deleted = [2]
        _ = try await sync.run(renderer: try ReadwiseRenderer(options: .init(blockIDs: false)))
        XCTAssertEqual(try sync.updates.record(forItem: "2")?.state, NotebookIntegrationRecord.removed)
    }

    func testBrokenTemplatesAreRejectedBeforeUse() throws {
        XCTAssertThrowsError(try ReadwiseRenderer.validate("{% for highlight in highlights %}{{ highlight_tex }}{% endfor %}"))
        XCTAssertThrowsError(try ReadwiseRenderer.validate("{{ title | replace('x') }}"))
        XCTAssertNoThrow(try ReadwiseRenderer.validate(ReadwiseRenderer.defaultTemplate))
        XCTAssertNoThrow(try ReadwiseRenderer.validate(
            "{% set name = author %}{% for highlight in highlights %}{{ name }} {{ highlight.text }}{% endfor %}"))
    }

    func testATemplateThatDoesTooMuchWorkStops() throws {
        let loops = """
            {% for a in highlights %}{% for b in highlights %}{% for c in highlights %}\
            {% for d in highlights %}x{% endfor %}{% endfor %}{% endfor %}{% endfor %}
            """
        XCTAssertThrowsError(try ReadwiseRenderer.validate(loops))
        let book = Readwise.Book(id: 1, title: "B", highlights: (0..<500).map { .init(id: $0, text: "t") })
        let heavy = """
            {% for highlight in highlights %}{% for a in highlights %}{% for b in highlights %}\
            x{% endfor %}{% endfor %}{% endfor %}
            """
        XCTAssertThrowsError(try ReadwiseRenderer(template: heavy).item(for: book))
    }

    func testMissingHighlightsAndBadCursorsAreNotTrusted() throws {
        for json in [#"{"user_book_id": 1, "title": "B"}"#,
                     #"{"user_book_id": 1, "title": "B", "highlights": null}"#] {
            XCTAssertFalse(try JSONDecoder().decode(Readwise.Book.self, from: Data(json.utf8)).isComplete)
        }
        let empty = #"{"user_book_id": 1, "title": "B", "highlights": []}"#
        XCTAssertTrue(try JSONDecoder().decode(Readwise.Book.self, from: Data(empty.utf8)).isComplete)
        let cursor = #"{"count": 0, "nextPageCursor": 5, "results": []}"#
        XCTAssertThrowsError(try JSONDecoder().decode(Readwise.ExportPage.self, from: Data(cursor.utf8)))
    }

    func testABookToBringBackIsKeptUntilItsNoteExists() async throws {
        let source = FakeReadwise()
        source.books = [book(1, ["One"])]
        let (replica, sync) = try await connected(source)
        _ = try await sync.run(renderer: try ReadwiseRenderer())
        let id = try XCTUnwrap(sync.updates.record(forItem: "1")?.note)
        try await replica.setTrashed(id, true)
        // Readwise sends the book incomplete this time, so it waits.
        let json = #"{"user_book_id": 1, "title": "Book 1"}"#
        source.books = [try JSONDecoder().decode(Readwise.Book.self, from: Data(json.utf8))]
        _ = try await sync.run(renderer: try ReadwiseRenderer(), bringingBack: [1])
        XCTAssertEqual(sync.progress.bringingBack, [1])
        source.books = [book(1, ["One"])]
        let summary = try await sync.run(renderer: try ReadwiseRenderer())
        XCTAssertEqual(summary.created, 1)
        XCTAssertEqual(sync.progress.bringingBack, [])
    }

    func testTemplateChecksFollowAttributesAndBranches() throws {
        XCTAssertThrowsError(try ReadwiseRenderer.validate(
            "{% for highlight in highlights %}{{ highlight.tex }}{% endfor %}"))
        XCTAssertNoThrow(try ReadwiseRenderer.validate(
            "{% if author %}{% set name = author %}{% else %}{% set name = title %}{% endif %}{{ name }}"))
        XCTAssertThrowsError(try ReadwiseRenderer.validate(
            "{% for highlight in highlights %}{% set inner = 1 %}{% endfor %}{{ inner }}"))
        XCTAssertThrowsError(try ReadwiseRenderer.validate("{{ title.text }}"))
        XCTAssertThrowsError(try ReadwiseRenderer.validate(
            "{% for tag in document_tags %}{{ tag.text }}{% endfor %}"))
        XCTAssertNoThrow(try ReadwiseRenderer.validate(
            "{% for h in highlights %}{% set same = h %}{{ same.text }} {{ h.block_id }}{% endfor %}"))
    }

    func testABookToBringBackComesBackWhenItsCategoryIsHidden() async throws {
        let source = FakeReadwise()
        source.books = [Readwise.Book(id: 1, title: "Picked", category: "supplementals",
                                      highlights: [.init(id: 10, text: "One")])]
        let (replica, sync) = try await connected(source)
        _ = try await sync.run(renderer: try ReadwiseRenderer(), includeSupplementals: true)
        let id = try XCTUnwrap(sync.updates.record(forItem: "1")?.note)
        try await replica.setTrashed(id, true)
        let summary = try await sync.run(renderer: try ReadwiseRenderer(), bringingBack: [1])
        XCTAssertEqual(summary.created, 1)
    }

    func testGrowingAStringStops() throws {
        let doubling = "{% set x = 'aaaaaaaa' %}" + String(repeating: "{% set x = x ~ x %}", count: 40)
        XCTAssertThrowsError(try ReadwiseRenderer.validate(doubling))
        let replacing = "{% set x = title ~ title ~ title %}"
            + String(repeating: "{% set x = x | replace('S', x) %}", count: 10)
        XCTAssertThrowsError(try ReadwiseRenderer.validate(replacing))
        let quoting = "{% set x = '\\\"' %}" + String(repeating: "{% set x = x | yaml %}", count: 40)
        XCTAssertThrowsError(try ReadwiseRenderer.validate(quoting))
        let twice = "{% set x = 'a' %}" + String(repeating: "{% set x = x ~ x %}", count: 20) + "{{ x }}{{ x }}"
        XCTAssertThrowsError(try ReadwiseRenderer.validate(twice))
    }

    func testEmptyLoopsAndDeepTemplatesStop() throws {
        let empty = "{% for a in highlights %}{% for b in highlights %}{% endfor %}{% endfor %}"
        let book = Readwise.Book(id: 1, title: "B", highlights: (0..<1_000).map { .init(id: $0, text: "t") })
        XCTAssertThrowsError(try ReadwiseRenderer(template: empty).item(for: book))
        XCTAssertThrowsError(try JinjaTemplate(String(repeating: "{% if title %}", count: 40)
            + String(repeating: "{% endif %}", count: 40)))
        XCTAssertThrowsError(try JinjaTemplate("{{ " + String(repeating: "(", count: 5_000) + "title"
            + String(repeating: ")", count: 5_000) + " }}"))
        XCTAssertThrowsError(try JinjaTemplate("{{ title" + String(repeating: " ~ title", count: 5_000) + " }}"))
    }

    func testAnotherTemplateNoteDoesNotWaitForThePreviousOne() async throws {
        let (replica, sync) = try await connected(FakeReadwise())
        let first = try await replica.createNote(name: "First.md", text: "{{ title }}")
        try await sync.updates.setSetting("template", first.uuidString)
        let old = Date().addingTimeInterval(120)
        try await sync.templateUsed(try await sync.template(now: old))
        let second = try await replica.createNote(name: "Second.md", text: "{{ author }}")
        try await sync.updates.setSetting("template", second.uuidString)
        let template = try await sync.template(now: old)
        XCTAssertFalse(template.waiting)
        XCTAssertEqual(template.source, "{{ author }}")
    }

    func testHighlightLinesNameTheirPlace() throws {
        func highlight(_ json: String) throws -> Readwise.Highlight {
            try JSONDecoder().decode(Readwise.Highlight.self, from: Data(json.utf8))
        }
        XCTAssertEqual(ReadwiseRenderer.locationLabel(
            try highlight(#"{"id": 1, "text": "t", "location": 42, "location_type": "page"}"#)), "p. 42")
        XCTAssertEqual(ReadwiseRenderer.locationLabel(
            try highlight(#"{"id": 1, "text": "t", "location": 3725, "location_type": "time_offset"}"#)), "1:02:05")
        XCTAssertEqual(ReadwiseRenderer.locationLabel(
            try highlight(#"{"id": 1, "text": "t", "location": 125, "location_type": "time_offset"}"#)), "2:05")
        XCTAssertEqual(ReadwiseRenderer.locationLabel(
            try highlight(#"{"id": 1, "text": "t", "location": 3, "location_type": "order"}"#)), "↗")
        XCTAssertEqual(ReadwiseRenderer.locationLabel(try highlight(#"{"id": 1, "text": "t"}"#)), "↗")

        let book = Readwise.Book(id: 1, title: "B", highlights: [
            .init(id: 1, text: "Quote", note: "First line\n\nSecond", tags: ["deep work", "#focus"]),
        ])
        let blocks = try ReadwiseRenderer(options: .init(blockIDs: false)).item(for: book).blocks
        XCTAssertEqual(blocks.last?.text,
                       "> Quote\n\n*First line*\n\n*Second* · #deep-work · #focus · [↗](https://readwise.io/open/1)")
    }

    func testTagsWithCommasStayOneTag() throws {
        let book = Readwise.Book(id: 1, title: "B", tags: ["research, methods", "plain"], highlights: [])
        let header = try ReadwiseRenderer().item(for: book).blocks.first?.text ?? ""
        XCTAssertTrue(header.contains(#"tags: ["research, methods", plain]"#), header)
    }

    func testABlockIDOnlyInACommentIsStillAdded() throws {
        let template = "{% for highlight in highlights %}{# block_id #}{{ highlight_text }}{% endfor %}"
        let book = Readwise.Book(id: 1, title: "B", highlights: [.init(id: 7, text: "Quote")])
        let blocks = try ReadwiseRenderer(template: template).item(for: book).blocks
        XCTAssertTrue(blocks.last?.text.contains("^rw-7") == true, blocks.last?.text ?? "")
    }

    func testAHighlightLoopInsideAnIfKeepsItsNames() throws {
        let template = "{% if highlights %}{% for highlight in highlights %}{{ highlight_text }} {% endfor %}{% endif %}"
        XCTAssertNoThrow(try ReadwiseRenderer.validate(template))
        let book = Readwise.Book(id: 1, title: "B", highlights: [.init(id: 7, text: "Quote")])
        let text = try ReadwiseRenderer(template: template).item(for: book).blocks.map(\.text).joined()
        XCTAssertTrue(text.contains("Quote"), text)
    }

    func testANoteDeletedForGoodCountsAsDeleted() async throws {
        let source = FakeReadwise()
        source.books = [book(1, ["One"])]
        let (replica, sync) = try await connected(source)
        _ = try await sync.run(renderer: try ReadwiseRenderer())
        let id = try XCTUnwrap(sync.updates.record(forItem: "1")?.note)
        try await replica.setTrashed(id, true)
        try await replica.permanentlyDelete(try replica.deletionSelection(rootIDs: [id]))
        XCTAssertEqual(try sync.updates.deletedItems(), ["1"])
    }

    func testNotesWithTheirOwnEmphasisStayAsWritten() throws {
        let book = Readwise.Book(id: 1, title: "B", highlights: [
            .init(id: 1, text: "Quote", note: "This is *important*"),
        ])
        let blocks = try ReadwiseRenderer(options: .init(blockIDs: false)).item(for: book).blocks
        XCTAssertTrue(blocks.last?.text.contains("This is *important* ·") == true, blocks.last?.text ?? "")
    }

    func testNumbersAndDatesStayTextInYAML() throws {
        let book = Readwise.Book(id: 1, title: "B", author: "2026-11-14", tags: ["00123", "plain"], highlights: [])
        let header = try ReadwiseRenderer().item(for: book).blocks.first?.text ?? ""
        XCTAssertTrue(header.contains(#"author: "2026-11-14""#), header)
        XCTAssertTrue(header.contains(#"tags: ["00123", plain]"#), header)
    }

    func testAHighlightATemplateLeavesOutGetsNoID() throws {
        let template = "{% for highlight in highlights %}{% if highlight_note %}{{ highlight_text }}{% endif %}{% endfor %}"
        let book = Readwise.Book(id: 1, title: "B", highlights: [
            .init(id: 1, text: "Kept", note: "n"), .init(id: 2, text: "Left out"),
        ])
        let texts = try ReadwiseRenderer(template: template).item(for: book).blocks.map(\.text)
        XCTAssertFalse(texts.contains { $0.contains("^rw-2") }, texts.joined(separator: " | "))
    }

    func testProgressReachesItsTotalWithHiddenSupplementals() async throws {
        let source = FakeReadwise()
        source.books = [book(1, ["One"]), Readwise.Book(id: 2, title: "Picked", category: "supplementals",
                                                      highlights: [.init(id: 20, text: "Two")])]
        let (_, sync) = try await connected(source)
        var last: (Int, Int?) = (0, nil)
        sync.onProgress = { last = ($0, $1) }
        _ = try await sync.run(renderer: try ReadwiseRenderer())
        XCTAssertEqual(last.0, 2)
    }

    func testEveryBookIsRenderedAgainOnceAWeek() async throws {
        let source = FakeReadwise()
        source.books = [book(1, ["One"]), book(2, ["Two"])]
        let (_, sync) = try await connected(source)
        let start = Date()
        _ = try await sync.run(renderer: try ReadwiseRenderer(), now: start)
        source.fetchedIDs = []
        _ = try await sync.run(renderer: try ReadwiseRenderer(), now: start.addingTimeInterval(60))
        XCTAssertEqual(sync.progress.fullSync, start)
        _ = try await sync.run(renderer: try ReadwiseRenderer(), now: start.addingTimeInterval(8 * 24 * 60 * 60))
        XCTAssertEqual(sync.progress.fullSync, start.addingTimeInterval(8 * 24 * 60 * 60))
    }

    /// Another device's late change set a highlight back, and Readwise
    /// never changes the book again. The weekly refresh repairs it.
    func testTheWeeklyRefreshRepairsAHighlightSetBack() async throws {
        let source = FakeReadwise()
        source.books = [book(1, ["One"])]
        let (replica, sync) = try await connected(source)
        let start = Date()
        _ = try await sync.run(renderer: try ReadwiseRenderer(), now: start)
        let id = try XCTUnwrap(sync.updates.record(forItem: "1")?.note)
        let loaded = try await replica.integrationNote(id)
        let note = try XCTUnwrap(loaded)
        let old = Readwise.Book(id: 1, title: "Book 1", highlights: [.init(id: 100, text: "Older")])
        try note.applyIntegration(
            try ReadwiseRenderer().item(for: old).blocks,
            link: .init(connection: sync.updates.connection, item: "1"), at: start)
        try await replica.mergeNote(note.snapshot())
        _ = try await sync.run(renderer: try ReadwiseRenderer(), now: start.addingTimeInterval(60))
        let before = try await replica.integrationNote(id)
        XCTAssertTrue(try XCTUnwrap(before).text.contains("Older"))
        _ = try await sync.run(renderer: try ReadwiseRenderer(), now: start.addingTimeInterval(8 * 24 * 60 * 60))
        let after = try await replica.integrationNote(id)
        let text = try XCTUnwrap(after).text
        XCTAssertTrue(text.contains("> One") && !text.contains("Older"), text)
    }

    // MARK: - Helpers

    private func connected(_ source: FakeReadwise) async throws -> (NotebookReplica, ReadwiseSync) {
        let root = FileManager.default.temporaryDirectory.appending(path: "readwise-\(UUID())")
        roots.append(root)
        let replica = NotebookReplica(directory: root.appending(path: "notebook"))
        try await replica.createLocalNotebook()
        let connection = try await NotebookIntegrationUpdates.connect(
            replica: replica, service: Readwise.service, folderName: "Readwise",
            device: device, rendererVersion: ReadwiseRenderer.version)
        let updates = NotebookIntegrationUpdates(
            replica: replica, connection: connection, device: device,
            rendererVersion: ReadwiseRenderer.version)
        return (replica, ReadwiseSync(
            updates: updates, source: source, progressURL: root.appending(path: "progress.json")))
    }

    private func book(_ id: Int, _ texts: [String], category: String = "books") -> Readwise.Book {
        Readwise.Book(id: id, title: "Book \(id)", category: category,
                      highlights: texts.enumerated().map { .init(id: id * 100 + $0.offset, text: $0.element) })
    }
}

/// Readwise with books held in memory.
final class FakeReadwise: ReadwiseSource, @unchecked Sendable {
    var books: [Readwise.Book] = []
    var changed: Set<Int> = []
    var deleted: Set<Int> = []
    var fetchedIDs: [[Int]] = []

    func checkToken() async throws {}

    func export(
        updatedAfter: Date?, ids: [Int]?, includeDeleted: Bool, cursor: String?
    ) async throws -> Readwise.ExportPage {
        if let ids {
            fetchedIDs.append(ids)
            return .init(results: books.filter { ids.contains($0.id) }, nextPageCursor: nil)
        }
        if updatedAfter != nil {
            let results = books.filter { changed.contains($0.id) && !deleted.contains($0.id) }
                + books.filter { deleted.contains($0.id) }.map {
                    Readwise.Book(id: $0.id, title: $0.title ?? "", isDeleted: true, highlights: [])
                }
            changed = []
            return .init(results: results, nextPageCursor: nil)
        }
        // Like Readwise, a full export leaves deleted books out.
        return .init(results: books.filter { !deleted.contains($0.id) }, nextPageCursor: nil)
    }
}
