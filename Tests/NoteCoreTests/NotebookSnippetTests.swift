import Automerge
import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class NotebookSnippetTests: XCTestCase {
    private enum Failure: Error { case stop }

    private func replica() async throws -> NotebookReplica {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let replica = NotebookReplica(directory: directory)
        try await replica.createLocalNotebook()
        return replica
    }

    func testRecursiveDiscoveryUsesOutermostStableCategoriesAndDeduplicates() async throws {
        let replica = try await replica()
        let root = try await replica.createFolder(name: "Guides")
        let middle = try await replica.createFolder(name: "Writing", parentID: root)
        let leaf = try await replica.createFolder(name: "Reviews", parentID: middle)
        let note = try await replica.createNote(name: "Feedback.md", parentID: leaf)
        let outside = try await replica.createNote(name: "Loose.md")
        try await replica.setSnippetSource(root, enabled: true)
        try await replica.setSnippetSource(middle, enabled: true)
        try await replica.setSnippetSource(note, enabled: true)
        try await replica.setSnippetSource(outside, enabled: true)

        XCTAssertEqual(Set(replica.snippets.map(\.id)), [note, outside])
        let snippet = try XCTUnwrap(replica.snippets.first { $0.id == note })
        XCTAssertEqual(snippet.path, "Guides/Writing/Reviews/Feedback.md")
        XCTAssertEqual(snippet.categories.map(\.id), [root, middle, leaf])
        XCTAssertEqual(snippet.categories.map(\.name), ["Guides", "Writing", "Reviews"])
        XCTAssertEqual(replica.snippets.first { $0.id == outside }?.categories, [])
        XCTAssertTrue(replica.isSnippetSource(middle))

        try await replica.setSnippetSource(root, enabled: false)
        XCTAssertEqual(Set(replica.snippets.map(\.id)), [note, outside])
        XCTAssertEqual(replica.snippets.first { $0.id == note }?.categories.map(\.id),
                       [middle, leaf])
    }

    func testRegistrationFollowsMoveRenameReloadAndTrash() async throws {
        let replica = try await replica()
        let root = try await replica.createFolder(name: "Library")
        let nested = try await replica.createFolder(name: "Cards", parentID: root)
        let destination = try await replica.createFolder(name: "Archive")
        let note = try await replica.createNote(name: "First.md", text: "stored", parentID: nested)
        try await replica.setSnippetSource(root, enabled: true)
        XCTAssertEqual(replica.snippets.first?.categories.map(\.id), [root, nested])

        try await replica.rename(nested, to: "Prompts")
        try await replica.rename(note, to: "Second.md")
        XCTAssertEqual(replica.snippets.first?.path, "Library/Prompts/Second.md")
        try await replica.move(root, to: destination)
        XCTAssertEqual(replica.snippets.first?.path, "Archive/Library/Prompts/Second.md")

        let loaded = NotebookReplica(directory: replica.directory)
        try await loaded.load()
        XCTAssertEqual(loaded.snippets.first?.id, note)
        XCTAssertEqual(loaded.snippets.first?.categories.map(\.id), [root, nested])
        try await loaded.setTrashed(root, true)
        XCTAssertTrue(loaded.snippets.isEmpty)
        try await loaded.setTrashed(root, false)
        XCTAssertEqual(loaded.snippets.first?.id, note)
    }

    func testTemplatesAndSnippetsHaveIndependentRegistrations() async throws {
        let replica = try await replica()
        let note = try await replica.createNote(name: "Source.md", text: "body")
        try await replica.setSnippetSource(note, enabled: true)
        XCTAssertTrue(replica.templates.isEmpty)
        XCTAssertEqual(replica.snippets.map(\.id), [note])
        try await replica.setTemplateSource(note, enabled: true)
        XCTAssertEqual(replica.templates.map(\.id), [note])
        try await replica.setSnippetSource(note, enabled: false)
        XCTAssertTrue(replica.snippets.isEmpty)
        XCTAssertEqual(replica.templates.map(\.id), [note])
    }

    func testOfflineSnippetRegistrationsMergeAndSurviveReload() throws {
        let base = try NotebookCatalogDocument()
        let folder = try base.add(kind: .folder, name: "Guides")
        let note = try base.add(kind: .note, name: "Note.md", parentID: folder)
        let first = try base.fork()
        let second = try base.fork()
        try first.setSnippetSource(folder, enabled: true)
        try second.setSnippetSource(note, enabled: true)
        try first.merge(second)

        let reloaded = try NotebookCatalogDocument(snapshot: first.snapshot())
        XCTAssertEqual(try reloaded.snippetMetadata().sources, [folder, note])
        let projection = try reloaded.snippetMetadata().projection(reloaded.placements())
        XCTAssertEqual(projection.snippets.map(\.id), [note])
        XCTAssertEqual(projection.snippets.first?.categories.map(\.id), [folder])
    }

    func testSnippetTextReadsUnflushedSessionThenStoredBodyWithoutEditingSource() async throws {
        let replica = try await replica()
        let folder = try await replica.createFolder(name: "Snippets")
        let id = try await replica.createNote(name: "Draft.md", text: "initial", parentID: folder)
        try await replica.setSnippetSource(folder, enabled: true)

        let session = try await replica.openNote(id)
        try session.replaceAll(with: "Latest {{date}} body")
        let snapshot = session.currentSnapshot
        let currentText = try await replica.snippetText(id)
        XCTAssertEqual(currentText, "Latest {{date}} body")
        XCTAssertEqual(session.currentSnapshot, snapshot)

        let closed = NotebookReplica(directory: replica.directory)
        try await closed.load()
        let storedText = try await closed.snippetText(id)
        XCTAssertEqual(storedText, "initial")
    }

    func testDeletionLedgerImmediatelyRemovesSnippetProjectionAndText() async throws {
        let replica = try await replica()
        let folder = try await replica.createFolder(name: "Snippets")
        let id = try await replica.createNote(name: "Draft.md", text: "body", parentID: folder)
        try await replica.setSnippetSource(folder, enabled: true)
        XCTAssertEqual(replica.snippets.map(\.id), [id])
        let catalogBeforeDeletion = replica.catalogSnapshot
        replica.catalogWriteSuspension = { throw Failure.stop }
        do {
            try await replica.rememberDeletions([folder])
            XCTFail("Expected catalog save failure after the deletion ledger")
        } catch is Failure {}
        replica.catalogWriteSuspension = nil

        XCTAssertEqual(replica.catalogSnapshot, catalogBeforeDeletion)
        XCTAssertTrue(replica.snippetSources.isEmpty)
        XCTAssertFalse(replica.isSnippetSource(folder))
        XCTAssertTrue(replica.snippets.isEmpty)
        do {
            _ = try await replica.snippetText(id)
            XCTFail("A deleted snippet source must not remain readable")
        } catch {
            XCTAssertEqual(error as? NotebookSnippetError, .sourceUnavailable)
        }
    }

    func testTextVariablesUseLocalCalendarPreserveUnknownAndDoNotRecurse() throws {
        let date = Date(timeIntervalSince1970: 0)
        let zone = try XCTUnwrap(TimeZone(secondsFromGMT: 5 * 60 * 60 + 30 * 60))
        let title = "Résumé {{date}} 📝"
        let body = "{{date}} {{time}} {{title}} {{unknown}} {{date"
        XCTAssertEqual(NotebookSnippetText.expand(
            text: body, title: title, date: date, timeZone: zone),
            "1970-01-01 05:30 Résumé {{date}} 📝 {{unknown}} {{date")
    }
    func testReceivedOfflineRegistrationsConvergeAndReadSyncedSource() async throws {
        let first = try await replica()
        let folder = try await first.createFolder(name: "Snippets")
        let note = try await first.createNote(
            name: "Agenda.md", text: "## {{title}}\n", parentID: folder)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let second = NotebookReplica(directory: directory)
        try await second.acceptSeed(SyncRecord(catalog: XCTUnwrap(first.catalogSnapshot)))
        for record in try await first.records() where record.kind == .note {
            try await second.apply(record)
        }
        XCTAssertTrue(second.snippets.isEmpty)
        try await first.setSnippetSource(folder, enabled: true)
        try await second.setSnippetSource(note, enabled: true)
        let firstRecord = SyncRecord(catalog: try XCTUnwrap(first.catalogSnapshot))
        let secondRecord = SyncRecord(catalog: try XCTUnwrap(second.catalogSnapshot))
        try await first.apply(secondRecord)
        try await second.apply(firstRecord)
        XCTAssertEqual(first.snippets, second.snippets)
        XCTAssertEqual(Set(second.snippetSources.map(\.id)), [folder, note])
        XCTAssertEqual(second.snippets.count, 1)
        let text = try await second.snippetText(note)
        XCTAssertEqual(text, "## {{title}}\n")

        // Concurrent toggles on one register must also converge in both directions.
        try await first.setSnippetSource(folder, enabled: false)
        try await second.setSnippetSource(folder, enabled: true)
        let disabling = SyncRecord(catalog: try XCTUnwrap(first.catalogSnapshot))
        let enabling = SyncRecord(catalog: try XCTUnwrap(second.catalogSnapshot))
        try await first.apply(enabling)
        try await second.apply(disabling)
        XCTAssertEqual(first.snippetSources, second.snippetSources)
        XCTAssertEqual(first.snippets, second.snippets)
    }

    func testOldCatalogIsEmptyAndMalformedSnippetMetadataIsRejected() throws {
        let catalog = try NotebookCatalogDocument()
        let note = try catalog.add(kind: .note, name: "Source.md")
        XCTAssertTrue(try catalog.snippetMetadata().sources.isEmpty)
        for (key, value) in [
            ("snippet.source.invalid-id", ScalarValue.Boolean(true)),
            ("snippet.source." + note.uuidString, ScalarValue.String("true")),
        ] {
            let raw = try Document(catalog.snapshot().data)
            try raw.put(obj: .ROOT, key: key, value: value)
            XCTAssertThrowsError(try NotebookCatalogDocument(serializedData: raw.save()))
        }
    }

}
