import Foundation
import XCTest

@testable import NoteCore

final class NotebookSearchTests: XCTestCase {
    func testRanksTitleMatchesAndKeepsUTF16BodyRange() throws {
        let exact = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let prefix = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let substring = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let body = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let corpus = NotebookSearchCorpus(
            notebookID: UUID(),
            entries: [
                .init(id: body, title: "Europa", path: "Moons", text: "A😀B Needle C"),
                .init(id: substring, title: "A Needle Log", path: "", text: "Preview"),
                .init(id: prefix, title: "Needlework", path: "", text: "Preview"),
                .init(id: exact, title: "NEEDLE", path: "", text: "Preview"),
            ],
            unavailableCount: 0
        )

        let results = corpus.search("needle")

        XCTAssertEqual(results.map(\.id), [exact, prefix, substring, body])
        XCTAssertEqual(results.map(\.matchesTitle), [true, true, true, false])
        XCTAssertEqual(results.last?.bodyMatchRange, NSRange(location: 5, length: 6))
        XCTAssertEqual(results.last?.excerptMatchRange, NSRange(location: 5, length: 6))
    }

    func testMatchingIsLiteralAndAccentSensitive() {
        let id = UUID()
        let corpus = NotebookSearchCorpus(
            notebookID: UUID(),
            entries: [.init(id: id, title: "Café [draft]", path: "", text: "Body")],
            unavailableCount: 0
        )

        XCTAssertEqual(corpus.search("[DRAFT]").map(\.id), [id])
        XCTAssertTrue(corpus.search("Cafe").isEmpty)
    }

    func testPreviewAndSnippetDoNotSplitComposedCharacters() throws {
        let previewText = String(repeating: "a", count: 159) + "😀" + "tail"
        let previewCorpus = NotebookSearchCorpus(
            notebookID: UUID(),
            entries: [.init(id: UUID(), title: "Match", path: "", text: previewText)],
            unavailableCount: 0
        )
        XCTAssertTrue(try XCTUnwrap(previewCorpus.search("match").first).excerpt
            .hasSuffix("😀…"))

        let snippetText = String(repeating: "a", count: 69) + "😀"
            + String(repeating: "b", count: 69) + "needle"
            + String(repeating: "c", count: 80)
        let snippetCorpus = NotebookSearchCorpus(
            notebookID: UUID(),
            entries: [.init(id: UUID(), title: "Other", path: "", text: snippetText)],
            unavailableCount: 0
        )
        let result = try XCTUnwrap(snippetCorpus.search("needle").first)
        XCTAssertTrue(result.excerpt.contains("😀"))
        let range = try XCTUnwrap(result.excerptMatchRange)
        XCTAssertEqual((result.excerpt as NSString).substring(with: range), "needle")
    }

    func testRepresentativeCorpusFindsBodyPhraseWithTitleFirstOrdering() {
        let exact = UUID()
        let prefix = UUID()
        let substring = UUID()
        let body = UUID()
        let filler = String(repeating: "fictional orbital observation. ", count: 70)
        var entries = (0..<2_000).map { index in
            NotebookSearchCorpus.Entry(
                id: UUID(),
                title: "Observation \(index)",
                path: "Archive/Sector \(index % 20)",
                text: filler
            )
        }
        entries[125] = .init(
            id: body,
            title: "Europa Survey",
            path: "Moons",
            text: filler + " distinctive solar needle passage"
        )
        entries[500] = .init(
            id: substring,
            title: "Archive Solar Needle",
            path: "Projects",
            text: filler
        )
        entries[1_000] = .init(
            id: prefix,
            title: "Solar Needle Notes",
            path: "Projects",
            text: filler
        )
        entries[1_500] = .init(
            id: exact,
            title: "Solar Needle",
            path: "Projects",
            text: filler
        )
        let corpus = NotebookSearchCorpus(
            notebookID: UUID(), entries: entries, unavailableCount: 0)
        let clock = ContinuousClock()
        let start = clock.now

        let results = corpus.search("solar needle")

        let elapsed = start.duration(to: clock.now)
        print("NotebookSearch 2,000-note warm match: \(elapsed)")
        XCTAssertEqual(results.map(\.id), [exact, prefix, substring, body])
        XCTAssertEqual(results.last?.bodyMatchRange?.length, 12)
    }
}

@MainActor
final class NotebookSearchCorpusTests: XCTestCase {
    func testCorpusUsesLiveTextBuildsPathAndExcludesTrash() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let folder = try await replica.createFolder(name: "Projects")
        let live = try await replica.createNote(
            name: "Live.markdown", text: "stored", parentID: folder)
        let trashed = try await replica.createNote(name: "Private.md", text: "secret")
        try await replica.setTrashed(trashed, true)
        let session = try await replica.openNote(live)
        let before = replica.searchRevision
        try session.replaceAll(with: "unsaved live text")

        let corpus = try await replica.searchCorpus()

        XCTAssertNotEqual(replica.searchRevision, before)
        XCTAssertEqual(corpus.entries, [
            .init(id: live, title: "Live", path: "Projects", text: "unsaved live text")
        ])
        XCTAssertEqual(corpus.unavailableCount, 0)
        XCTAssertTrue(corpus.search("secret").isEmpty)
    }

    func testUnavailableBodyKeepsTitleSearchableWithoutBodyMatches() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let note = try await replica.createNote(name: "Damaged.md", text: "content")
        try Data("invalid".utf8).write(to: replica.noteStorage(note).currentURL)

        let corpus = try await replica.searchCorpus()

        XCTAssertEqual(corpus.entries.map(\.id), [note])
        XCTAssertEqual(corpus.unavailableCount, 1)
        let titleResult = try XCTUnwrap(corpus.search("damaged").first)
        XCTAssertTrue(titleResult.matchesTitle)
        XCTAssertNil(titleResult.bodyMatchRange)
        XCTAssertTrue(corpus.search("content").isEmpty)
    }

    func testRemoteChangeToUnopenedNoteInvalidatesRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let note = try await replica.createNote(name: "Remote.md", text: "before")
        let before = replica.searchRevision
        guard case .current(let snapshot) = await replica.noteStorage(note).load() else {
            return XCTFail("Expected a stored note")
        }
        let remote = try NoteDocument(snapshot: snapshot)
        try remote.replaceAll(with: "after")

        try await replica.apply(SyncRecord(
            snapshot: remote.snapshot(),
            notebookID: try XCTUnwrap(replica.catalogSnapshot?.notebookID)
        ))

        XCTAssertNotEqual(replica.searchRevision, before)
        let corpus = try await replica.searchCorpus()
        XCTAssertEqual(corpus.entries.first?.text, "after")
    }
}
