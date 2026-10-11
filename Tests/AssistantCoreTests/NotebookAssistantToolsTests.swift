import Foundation
import XCTest
@testable import AssistantCore
@testable import NoteCore

@MainActor
final class NotebookAssistantToolsTests: XCTestCase {
    private struct CreatedOutput: Decodable { let note_id: String; let title: String }
    private struct ReadOutput: Decodable {
        let note_id: String
        let title: String
        let markdown: String
        let revision: String?
        let truncated: Bool
        let can_update: Bool
    }
    private struct SearchOutput: Decodable {
        struct Item: Decodable { let note_id: String; let title: String; let excerpt: String }
        let results: [Item]
        let truncated: Bool
    }

    func testCreateSearchReadAndUpdatePreservesNativeHistory() async throws {
        let (replica, root) = try await makeReplica()
        defer { try? FileManager.default.removeItem(at: root) }
        let notebookID = try XCTUnwrap(replica.catalogSnapshot?.notebookID)
        let tools = NotebookAssistantTools(replica: replica, notebookID: notebookID,
            isActive: { true }, didWrite: {})

        let created = await tools.context.executor.execute(AssistantToolCall(
            id: "create-1", name: "create_note",
            arguments: #"{"title":"Meeting notes","markdown":"First line\nsecond line"}"#
        ))
        XCTAssertFalse(created.isError, created.output)
        let createdValue = try JSONDecoder().decode(CreatedOutput.self, from: Data(created.output.utf8))
        let noteID = try XCTUnwrap(UUID(uuidString: createdValue.note_id))
        XCTAssertEqual(createdValue.title, "Meeting notes")
        XCTAssertEqual(created.noteReferences.first?.noteID, noteID)

        let search = await tools.context.executor.execute(AssistantToolCall(
            id: "search-1", name: "search_notes", arguments: #"{"query":"second line"}"#
        ))
        let searchValue = try JSONDecoder().decode(SearchOutput.self, from: Data(search.output.utf8))
        XCTAssertEqual(searchValue.results.first?.note_id, noteID.uuidString)
        XCTAssertFalse(searchValue.truncated)

        let read = await tools.context.executor.execute(AssistantToolCall(
            id: "read-1", name: "read_note", arguments: try noteArguments(noteID)
        ))
        let readValue = try JSONDecoder().decode(ReadOutput.self, from: Data(read.output.utf8))
        XCTAssertEqual(readValue.markdown, "First line\nsecond line")
        XCTAssertTrue(readValue.can_update)
        let revision = try XCTUnwrap(readValue.revision)

        let session = try await replica.openNote(noteID)
        let update = await tools.context.executor.execute(AssistantToolCall(
            id: "update-1", name: "update_note",
            arguments: try updateArguments(noteID, revision: revision, markdown: "Revised body")
        ))
        XCTAssertFalse(update.isError, update.output)
        XCTAssertEqual(session.text, "Revised body")

        let reopened = NotebookReplica(directory: root)
        try await reopened.load()
        let reopenedSession = try await reopened.openNote(noteID)
        XCTAssertEqual(reopenedSession.text, "Revised body")
        let persistedVersions = try reopenedSession.historyVersions()
        XCTAssertFalse(persistedVersions.isEmpty)
        let persistedHistory = try persistedVersions.map {
            try reopenedSession.historicalText(for: $0)
        }
        // Verify the durable Automerge snapshot retains the full prior body,
        // rather than relying on an in-memory history index queried mid-edit.
        XCTAssertTrue(persistedHistory.contains("First line\nsecond line"))
    }

    func testCreateCallIDIsIdempotentAndConflictingReuseIsRejected() async throws {
        let (replica, root) = try await makeReplica()
        defer { try? FileManager.default.removeItem(at: root) }
        let notebookID = try XCTUnwrap(replica.catalogSnapshot?.notebookID)
        let tools = NotebookAssistantTools(replica: replica, notebookID: notebookID,
            isActive: { true }, didWrite: {})
        let first = AssistantToolCall(id: "same-id", name: "create_note",
            arguments: #"{"title":"One","markdown":"body"}"#)
        let firstResult = await tools.execute(first)
        let repeated = await tools.execute(first)
        XCTAssertEqual(firstResult, repeated)
        XCTAssertEqual(replica.placements.filter { $0.item.kind == .note }.count, 1)

        let conflicting = await tools.execute(AssistantToolCall(id: "same-id", name: "create_note",
            arguments: #"{"title":"Two","markdown":"other"}"#))
        XCTAssertTrue(conflicting.isError)
        XCTAssertEqual(replica.placements.filter { $0.item.kind == .note }.count, 1)
    }

    func testUnchangedAssistantUpdateFlushesExistingUnsavedText() async throws {
        let (replica, root) = try await makeReplica()
        defer { try? FileManager.default.removeItem(at: root) }
        let noteID = try await replica.createNoteInDefaultFolder(name: "Draft.md", text: "Original")
        let notebookID = try XCTUnwrap(replica.catalogSnapshot?.notebookID)
        let tools = NotebookAssistantTools(replica: replica, notebookID: notebookID,
            isActive: { true }, didWrite: {})

        let session = try await replica.openNote(noteID)
        try session.replaceAll(with: "Already edited locally")
        let read = await tools.execute(AssistantToolCall(
            id: "read-unsaved", name: "read_note", arguments: try noteArguments(noteID)
        ))
        let readValue = try JSONDecoder().decode(ReadOutput.self, from: Data(read.output.utf8))
        XCTAssertEqual(readValue.markdown, "Already edited locally")
        let revision = try XCTUnwrap(readValue.revision)

        let update = await tools.execute(AssistantToolCall(id: "update-same-body", name: "update_note",
            arguments: try updateArguments(noteID, revision: revision,
                                           markdown: "Already edited locally")))
        XCTAssertFalse(update.isError, update.output)
        XCTAssertEqual(session.status, .saved)

        let reopened = NotebookReplica(directory: root)
        try await reopened.load()
        let persisted = try await reopened.openNote(noteID)
        XCTAssertEqual(persisted.text, "Already edited locally")
        XCTAssertEqual(persisted.status, .saved)
    }

    func testStaleRevisionAndTrashCannotUpdateNote() async throws {
        let (replica, root) = try await makeReplica()
        defer { try? FileManager.default.removeItem(at: root) }
        let noteID = try await replica.createNoteInDefaultFolder(name: "Plan.md", text: "Original")
        let notebookID = try XCTUnwrap(replica.catalogSnapshot?.notebookID)
        let tools = NotebookAssistantTools(replica: replica, notebookID: notebookID,
            isActive: { true }, didWrite: {})
        let read = await tools.execute(AssistantToolCall(
            id: "read-stale", name: "read_note", arguments: try noteArguments(noteID)
        ))
        let value = try JSONDecoder().decode(ReadOutput.self, from: Data(read.output.utf8))
        let revision = try XCTUnwrap(value.revision)

        let session = try await replica.openNote(noteID)
        try session.replaceAll(with: "User edit")
        try await session.flush()
        let stale = await tools.execute(AssistantToolCall(id: "stale-update", name: "update_note",
            arguments: try updateArguments(noteID, revision: revision, markdown: "Assistant edit")))
        XCTAssertTrue(stale.isError)
        XCTAssertEqual(session.text, "User edit")

        try await replica.setTrashed(noteID, true)
        let trashed = await tools.execute(AssistantToolCall(
            id: "read-trash", name: "read_note", arguments: try noteArguments(noteID)
        ))
        XCTAssertTrue(trashed.isError)
    }

    func testReadRechecksTrashAfterOpenNoteWaitsForCatalogWrite() async throws {
        let (replica, root) = try await makeReplica()
        defer { try? FileManager.default.removeItem(at: root) }
        let noteID = try await replica.createNoteInDefaultFolder(name: "Pending.md", text: "body")
        let notebookID = try XCTUnwrap(replica.catalogSnapshot?.notebookID)
        let scope = ActiveScope()
        let tools = NotebookAssistantTools(replica: replica, notebookID: notebookID,
            isActive: { scope.check() }, didWrite: {})

        let writeEntered = expectation(description: "trash catalog write entered")
        var releaseWrite: CheckedContinuation<Void, Never>?
        replica.catalogWriteSuspension = {
            writeEntered.fulfill()
            await withCheckedContinuation { releaseWrite = $0 }
        }
        let trash = Task { @MainActor in try await replica.setTrashed(noteID, true) }
        await fulfillment(of: [writeEntered], timeout: 1)
        let arguments = try noteArguments(noteID)
        let read = Task { @MainActor in
            await tools.execute(AssistantToolCall(id: "read-during-trash", name: "read_note",
                arguments: arguments))
        }
        while scope.validationCount < 2 { await Task.yield() }
        replica.catalogWriteSuspension = nil
        releaseWrite?.resume()
        try await trash.value
        let result = await read.value
        XCTAssertTrue(result.isError)
    }

    func testSearchDropsResultsFromCorpusWhenNoteMovesToTrash() async throws {
        let (replica, root) = try await makeReplica()
        defer { try? FileManager.default.removeItem(at: root) }
        let noteID = try await replica.createNoteInDefaultFolder(
            name: "Private.md", text: "needle phrase")
        let notebookID = try XCTUnwrap(replica.catalogSnapshot?.notebookID)
        let tools = NotebookAssistantTools(replica: replica, notebookID: notebookID,
            isActive: { true }, didWrite: {})

        // Keep the old search snapshot to model a Trash change during the
        // corpus' asynchronous note reads.
        let oldCorpus = try await replica.searchCorpus()
        let oldMatches = oldCorpus.search("needle phrase")
        XCTAssertEqual(oldMatches.map(\.id), [noteID])
        try await replica.setTrashed(noteID, true)
        XCTAssertTrue(tools.activeSearchMatches(oldMatches).isEmpty)

        let search = await tools.execute(AssistantToolCall(
            id: "search-after-trash", name: "search_notes",
            arguments: #"{"query":"needle phrase"}"#
        ))
        let output = try JSONDecoder().decode(SearchOutput.self, from: Data(search.output.utf8))
        XCTAssertTrue(output.results.isEmpty)
    }

    func testInactiveNotebookRejectsCallsAndCancelledQueuedCallDoesNotCreate() async throws {
        let (replica, root) = try await makeReplica()
        defer { try? FileManager.default.removeItem(at: root) }
        let notebookID = try XCTUnwrap(replica.catalogSnapshot?.notebookID)
        let active = ActiveScope()
        let tools = NotebookAssistantTools(replica: replica, notebookID: notebookID,
            isActive: { active.isActive }, didWrite: {})

        active.isActive = false
        let inactive = await tools.execute(AssistantToolCall(
            id: "inactive", name: "search_notes", arguments: #"{"query":""}"#
        ))
        XCTAssertTrue(inactive.isError)
        XCTAssertTrue(replica.placements.isEmpty)

        active.isActive = true
        let writeEntered = expectation(description: "create reached catalog write")
        var releaseWrite: CheckedContinuation<Void, Never>?
        replica.catalogWriteSuspension = {
            writeEntered.fulfill()
            await withCheckedContinuation { releaseWrite = $0 }
        }
        let first = Task { @MainActor in
            await tools.execute(AssistantToolCall(id: "first-create", name: "create_note",
                arguments: #"{"title":"First","markdown":"body"}"#))
        }
        await fulfillment(of: [writeEntered], timeout: 1)
        replica.catalogWriteSuspension = nil
        let queued = Task { @MainActor in
            await tools.execute(AssistantToolCall(id: "cancelled", name: "create_note",
                arguments: #"{"title":"Should not exist","markdown":"body"}"#))
        }
        await Task.yield()
        queued.cancel()
        releaseWrite?.resume()
        let firstResult = await first.value
        let queuedResult = await queued.value
        XCTAssertFalse(firstResult.isError)
        XCTAssertTrue(queuedResult.isError)
        XCTAssertEqual(replica.placements.filter { $0.item.kind == .note }.count, 1)
    }

    func testCancelledCreateQueuedBehindNativeCatalogWriteDoesNotCommit() async throws {
        let (replica, root) = try await makeReplica()
        defer { try? FileManager.default.removeItem(at: root) }
        let notebookID = try XCTUnwrap(replica.catalogSnapshot?.notebookID)
        let tools = NotebookAssistantTools(replica: replica, notebookID: notebookID,
            isActive: { true }, didWrite: {})
        let writeEntered = expectation(description: "native catalog write entered")
        var releaseWrite: CheckedContinuation<Void, Never>?
        replica.catalogWriteSuspension = {
            writeEntered.fulfill()
            await withCheckedContinuation { releaseWrite = $0 }
        }

        let nativeCreate = Task { @MainActor in
            try await replica.createNoteInDefaultFolder(name: "User note.md", text: "body")
        }
        await fulfillment(of: [writeEntered], timeout: 1)
        replica.catalogWriteSuspension = nil
        let assistantCreate = Task { @MainActor in
            await tools.execute(AssistantToolCall(id: "queued-create", name: "create_note",
                arguments: #"{"title":"Cancelled note","markdown":"body"}"#))
        }
        await Task.yield()
        assistantCreate.cancel()
        releaseWrite?.resume()

        _ = try await nativeCreate.value
        let result = await assistantCreate.value
        XCTAssertTrue(result.isError)
        XCTAssertEqual(replica.placements.filter { $0.item.kind == .note }.count, 1)
        XCTAssertFalse(replica.placements.contains { $0.displayName == "Cancelled note.md" })
    }

    private func makeReplica() async throws -> (NotebookReplica, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        return (replica, root)
    }

    private func noteArguments(_ id: UUID) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["note_id": id.uuidString]), as: UTF8.self)
    }

    private func updateArguments(_ id: UUID, revision: String, markdown: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "note_id": id.uuidString, "revision": revision, "markdown": markdown,
        ])
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
private final class ActiveScope {
    var isActive = true
    var validationCount = 0

    func check() -> Bool {
        validationCount += 1
        return isActive
    }
}
