import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class NotebookOrderingIntegrationTests: XCTestCase {
    func testSortingAndMovesPreserveBodiesAcrossReloadAndSync() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let left = NotebookReplica(directory: root.appending(path: "left"))
        try await left.createLocalNotebook()
        let folder = try await left.createFolder(name: "Observatory")
        let beta = try await left.createNote(name: "Beta.md", text: "# β\r\n\r\n👋🏽\n")
        let alpha = try await left.createNote(name: "Alpha.md", text: "\u{FEFF}A\r\n")
        let before = try await left.persistedNoteSnapshots()
        let session = try await left.openNote(beta)

        try await left.sortChildren(parentID: nil, by: .nameAscending)
        XCTAssertEqual(left.orderedChildren(parentID: nil).map(\.item.id), [folder, alpha, beta])
        try await left.reorder([beta], parentID: nil, before: folder)
        XCTAssertEqual(left.orderedChildren(parentID: nil).map(\.item.id), [beta, folder, alpha])
        try await left.move(alpha, to: folder)
        let after = try await left.persistedNoteSnapshots()
        XCTAssertEqual(before, after)
        let reopenedSession = try await left.openNote(beta)
        XCTAssertTrue(session === reopenedSession)

        let reloaded = NotebookReplica(directory: left.directory)
        try await reloaded.load()
        XCTAssertEqual(reloaded.orderedChildren(parentID: nil).map(\.item.id), [beta, folder])
        XCTAssertEqual(reloaded.orderedChildren(parentID: folder).map(\.item.id), [alpha])

        let right = NotebookReplica(directory: root.appending(path: "right"))
        try await right.acceptSeed(SyncRecord(catalog: XCTUnwrap(left.catalogSnapshot)))
        for record in try await left.records() { try await right.apply(record) }
        XCTAssertEqual(right.placements, left.placements)
        XCTAssertEqual(right.orderedChildren(parentID: nil), left.orderedChildren(parentID: nil))
        let received = try await right.persistedNoteSnapshots()
        XCTAssertEqual(received, before)
    }

    func testDateSortIsOneTimeAndMissingDatesAlwaysComeLast() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let old = UUID(), recent = UUID(), unknown = UUID()
        let entries = [
            NotebookImportEntry(
                id: unknown, kind: .note, name: "Alpha.md", parentID: nil, text: "unknown"),
            NotebookImportEntry(
                id: old, kind: .note, name: "Beta.md", parentID: nil, text: "old",
                createdAt: Date(timeIntervalSince1970: 100),
                modifiedAt: Date(timeIntervalSince1970: 200)),
            NotebookImportEntry(
                id: recent, kind: .note, name: "Gamma.md", parentID: nil, text: "recent",
                createdAt: Date(timeIntervalSince1970: 300),
                modifiedAt: Date(timeIntervalSince1970: 400)),
        ]
        try await replica.importMarkdown(
            NotebookImportPlan(id: UUID(), entries: entries, skippedPaths: []))
        try await replica.sortChildren(parentID: nil, by: .modifiedNewest)
        XCTAssertEqual(replica.orderedChildren(parentID: nil).map(\.item.id), [recent, old, unknown])
        let session = try await replica.openNote(old)
        try session.replaceAll(with: "A newly edited fictional star chart")
        try await session.flush()
        XCTAssertEqual(replica.orderedChildren(parentID: nil).map(\.item.id), [recent, old, unknown])
        try await replica.sortChildren(parentID: nil, by: .modifiedNewest)
        XCTAssertEqual(replica.orderedChildren(parentID: nil).map(\.item.id), [old, recent, unknown])
        try await replica.sortChildren(parentID: nil, by: .createdOldest)
        XCTAssertEqual(replica.orderedChildren(parentID: nil).map(\.item.id), [old, recent, unknown])
        try await replica.sortChildren(parentID: nil, by: .createdNewest)
        XCTAssertEqual(replica.orderedChildren(parentID: nil).map(\.item.id), [recent, old, unknown])
    }

    func testDateSortUsesLiveSessionInsteadOfStaleStoredSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let active = UUID(), closed = UUID()
        try await replica.importMarkdown(NotebookImportPlan(
            id: UUID(),
            entries: [
                NotebookImportEntry(
                    id: active, kind: .note, name: "Active.md", parentID: nil,
                    text: "original", modifiedAt: Date(timeIntervalSince1970: 100)),
                NotebookImportEntry(
                    id: closed, kind: .note, name: "Closed.md", parentID: nil,
                    text: "closed", modifiedAt: Date(timeIntervalSince1970: 200)),
            ],
            skippedPaths: []
        ))
        let session = try await replica.openNote(active)
        let stale = try XCTUnwrap(session.currentSnapshot)
        try session.replaceAll(with: "newer live content")
        try await session.flush()
        let live = try XCTUnwrap(session.currentSnapshot)

        // Model an older storage read without relying on actor scheduling.
        // The open session remains authoritative after its successful flush.
        try stale.data.write(to: replica.noteStorage(active).currentURL, options: .atomic)
        try await replica.sortChildren(parentID: nil, by: .modifiedNewest)
        XCTAssertEqual(replica.orderedChildren(parentID: nil).map(\.item.id), [active, closed])
        try await replica.sortChildren(parentID: nil, by: .modifiedOldest)
        XCTAssertEqual(replica.orderedChildren(parentID: nil).map(\.item.id), [closed, active])
        XCTAssertEqual(session.currentSnapshot, live)
        XCTAssertEqual(session.text, "newer live content")
    }

    func testInvalidReorderDoesNotPublishPartialCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let note = try await replica.createNote(name: "Comet.md")
        let before = replica.catalogSnapshot
        do {
            try await replica.reorder([note, UUID()], parentID: nil, before: nil)
            XCTFail("Invalid identities must reject the complete operation")
        } catch {}
        XCTAssertEqual(replica.catalogSnapshot, before)
        let reloaded = NotebookReplica(directory: root)
        try await reloaded.load()
        XCTAssertEqual(reloaded.catalogSnapshot, before)
    }
}
