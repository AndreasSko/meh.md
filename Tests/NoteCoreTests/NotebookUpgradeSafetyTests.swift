import Automerge
import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class NotebookUpgradeSafetyTests: XCTestCase {
    func testSchemaTwoAttachmentMergeKeepsOfflineSchemaOneEdits() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "notebook-format-two-merge-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let replica = NotebookReplica(directory: directory)
        try await replica.createLocalNotebook()
        let noteID = try await replica.createNote(
            name: "Original.md", text: "original body"
        )
        let schemaOne = try XCTUnwrap(replica.catalogSnapshot)
        let remote = try NotebookCatalogDocument(snapshot: schemaOne)
        let attachmentID = UUID()
        let content = try NotebookAttachmentContent(
            sha256: String(repeating: "a", count: 64), byteCount: 42
        )
        try remote.add(id: attachmentID, kind: .attachment,
                       name: "diagram.pdf", attachment: content)
        let beforeRecords = try await replica.records()
        let staleNote = try XCTUnwrap(beforeRecords.first {
            $0.kind == .note && $0.snapshot.noteID == noteID
        })

        // These edits were made against schema one while the peer upgraded.
        try await replica.rename(noteID, to: "Offline.md")
        let session = try await replica.openNote(noteID)
        try session.replaceAll(with: "latest offline body")
        try await session.flush()
        let offlineHeads = try XCTUnwrap(replica.catalogSnapshot).heads

        try await replica.apply(SyncRecord(catalog: remote.snapshot()))
        try await replica.apply(staleNote)
        let merged = try XCTUnwrap(replica.catalogSnapshot)
        let mergedCatalog = try NotebookCatalogDocument(snapshot: merged)
        XCTAssertTrue(offlineHeads.isSubset(of: mergedCatalog.historyHeads))
        let items = try mergedCatalog.items()
        XCTAssertEqual(items.first { $0.id == noteID }?.name, "Offline.md")
        XCTAssertEqual(items.first { $0.id == attachmentID }?.attachment,
                       content)
        XCTAssertEqual(session.text, "latest offline body")

        let reopened = NotebookReplica(directory: directory)
        try await reopened.load()
        let reopenedSession = try await reopened.openNote(noteID)
        XCTAssertEqual(reopenedSession.text, "latest offline body")
        XCTAssertEqual(try reopened.attachmentDescriptor(for: attachmentID),
                       NotebookAttachmentDescriptor(id: attachmentID,
                                                    content: content))
    }

    func testFutureCatalogPauseKeepsLocalEditsAndCompatibleReplay() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "notebook-upgrade-safety-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let seed = try NotebookCatalogDocument().snapshot()
        let future = try Self.futureCatalog(from: seed, version: NotebookSyncFormat.supportedVersion + 1)
        let transport = UpgradeTransport(seed: SyncRecord(catalog: seed))
        let replica = NotebookReplica(directory: directory)
        let coordinator = NotebookSyncCoordinator(
            replica: replica, transport: transport
        )

        // A fresh legacy notebook joins the same canonical seed first.
        await coordinator.synchronize()
        XCTAssertNil(coordinator.lastError)
        XCTAssertEqual(replica.catalogSnapshot?.notebookID, seed.notebookID)
        let joined = try XCTUnwrap(replica.catalogSnapshot)
        let stateURL = directory.appending(path: "notebook-sync-state.json")
        let joinedState = try Self.state(at: stateURL)
        XCTAssertEqual(joinedState.cursor, "1")

        await transport.offerFuture(SyncRecord(catalog: future))
        let publishedBeforeFailure = await transport.publishedRecords()
        await coordinator.synchronize()
        XCTAssertEqual(
            coordinator.lastError as? SyncError,
            .updateRequired(requiredVersion: NotebookSyncFormat.supportedVersion + 1)
        )
        XCTAssertEqual(replica.catalogSnapshot, joined)
        XCTAssertEqual(try Self.state(at: stateURL).cursor, joinedState.cursor)
        XCTAssertEqual(
            try Self.state(at: stateURL).acknowledgedHeads,
            joinedState.acknowledgedHeads
        )
        let publishedAfterFailure = await transport.publishedRecords()
        XCTAssertEqual(publishedAfterFailure, publishedBeforeFailure)

        // The sync error must leave ordinary local editing enabled and durable.
        let noteID = try await replica.createNote(name: "Draft.md", text: "first")
        try await replica.rename(noteID, to: "Retained.md")
        let session = try await replica.openNote(noteID)
        try session.replaceAll(with: "edited while sync paused")
        try await session.flush()
        let editedCatalog = try XCTUnwrap(replica.catalogSnapshot)
        XCTAssertNotEqual(editedCatalog.heads, joined.heads)

        await coordinator.synchronize()
        XCTAssertEqual(
            coordinator.lastError as? SyncError,
            .updateRequired(requiredVersion: NotebookSyncFormat.supportedVersion + 1)
        )
        XCTAssertEqual(replica.catalogSnapshot?.heads, editedCatalog.heads)
        XCTAssertEqual(try Self.state(at: stateURL).cursor, joinedState.cursor)
        let publishedWhilePaused = await transport.publishedRecords()
        XCTAssertEqual(publishedWhilePaused, publishedBeforeFailure)
        XCTAssertEqual(session.text, "edited while sync paused")

        let reopenedWhilePaused = NotebookReplica(directory: directory)
        try await reopenedWhilePaused.load()
        XCTAssertEqual(
            reopenedWhilePaused.placements.first { $0.item.id == noteID }?.item.name,
            "Retained.md"
        )
        let pausedSession = try await reopenedWhilePaused.openNote(noteID)
        XCTAssertEqual(pausedSession.text, "edited while sync paused")

        // A compatible test peer lets us verify pending-upload replay. A real
        // cloud format upgrade would require installing a capable app instead.
        await transport.withdrawFuture()
        await coordinator.synchronize()
        XCTAssertNil(coordinator.lastError)
        let published = await transport.publishedRecords()
        let note = try XCTUnwrap(published.last {
            $0.kind == .note && $0.snapshot.noteID == noteID
        })
        XCTAssertEqual(
            try NoteDocument(snapshot: note.snapshot).text,
            "edited while sync paused"
        )
        let catalog = try XCTUnwrap(published.last { $0.kind == .catalog })
        let items = try NotebookCatalogDocument(
            snapshot: XCTUnwrap(catalog.catalogSnapshot)
        ).items()
        XCTAssertEqual(items.first { $0.id == noteID }?.name, "Retained.md")

        let reopened = NotebookReplica(directory: directory)
        try await reopened.load()
        XCTAssertEqual(
            reopened.placements.first { $0.item.id == noteID }?.item.name,
            "Retained.md"
        )
        let reopenedSession = try await reopened.openNote(noteID)
        XCTAssertEqual(reopenedSession.text, "edited while sync paused")
    }

    private static func futureCatalog(
        from seed: NotebookCatalogSnapshot, version: UInt64
    ) throws -> NotebookCatalogSnapshot {
        let document = try Document(seed.data)
        try document.put(obj: .ROOT, key: "schemaVersion", value: .Uint(version))
        // The future item's shape is opaque to this release. Version checking
        // must stop before the catalog decoder reads it.
        try document.put(obj: .ROOT, key: "items", value: .String("future layout"))
        return NotebookCatalogSnapshot(
            data: document.save(),
            heads: Set(document.heads().map(\.debugDescription)),
            notebookID: seed.notebookID
        )
    }

    private static func state(at url: URL) throws -> NotebookSyncState {
        try JSONDecoder().decode(NotebookSyncState.self, from: Data(contentsOf: url))
    }
}

private actor UpgradeTransport: SyncTransport {
    nonisolated let scope = "upgrade-safety"
    private let seed: SyncRecord
    private var future: SyncRecord?
    private var published: [SyncRecord] = []

    init(seed: SyncRecord) { self.seed = seed }

    func offerFuture(_ record: SyncRecord) { future = record }
    func withdrawFuture() { future = nil }
    func publishedRecords() -> [SyncRecord] { published }

    func bootstrap(proposing record: SyncRecord) async throws -> SyncRecord {
        seed
    }

    func publish(_ record: SyncRecord) async throws {
        try record.validate()
        published.append(record)
    }

    func fetch(after cursor: String?) async throws -> SyncPage {
        let records = [seed] + (future.map { [$0] } ?? [])
        let offset = Int(cursor ?? "0") ?? -1
        guard offset >= 0, offset <= records.count else {
            throw SyncError.invalidCursor
        }
        return SyncPage(
            records: Array(records.dropFirst(offset)),
            cursor: String(records.count), hasMore: false
        )
    }

    func purgeDeletedNotes(_ noteIDs: Set<UUID>, notebookID: UUID) async throws {}
}
