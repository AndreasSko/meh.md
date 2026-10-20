import Automerge
import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class NotebookWelcomeNoteTests: XCTestCase {
    nonisolated(unsafe) private var roots: [URL] = []
    private let welcome = NotebookWelcomeNote.id

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    func testBundledNoteDecodesWithItsFixedHistory() throws {
        let snapshot = try NotebookWelcomeNote.snapshot()
        let note = try NoteDocument(snapshot: snapshot)
        XCTAssertEqual(note.noteID, welcome)
        XCTAssertEqual(try note.text, NotebookWelcomeNote.text)
        // A failure here after editing the text shows the new heads.
        XCTAssertEqual(note.heads, NotebookWelcomeNote.heads)
        // Each device must edit with its own actor, never the bundled one.
        let first = try Document(snapshot.data)
        let second = try Document(snapshot.data)
        XCTAssertNotEqual(first.actor, second.actor)
    }

    func testFreshNotebookOpensWithTheWelcomeNote() async throws {
        let replica = try await freshDevice()
        let notes = visibleWelcomeNotes(replica)
        XCTAssertEqual(notes.map(\.item.name), [NotebookWelcomeNote.name])
        let session = try await replica.openNote(welcome)
        XCTAssertEqual(session.currentSnapshot?.heads, NotebookWelcomeNote.heads)
    }

    func testFreshDevicesShareOneWelcomeNoteAndMergeOfflineEdits() async throws {
        let transport = InMemorySyncTransport(scope: "welcome-shared")
        let first = try await freshDevice()
        try await edit(first, append: "\nFirst device line.")
        let firstSync = NotebookSyncCoordinator(replica: first, transport: transport)
        await firstSync.synchronize()
        assertSuccess(firstSync)

        let second = try await freshDevice()
        try await edit(second, append: "\nSecond device line.")
        let secondSync = NotebookSyncCoordinator(replica: second, transport: transport)
        await secondSync.synchronize()
        assertSuccess(secondSync)
        await firstSync.synchronize()
        assertSuccess(firstSync)

        for replica in [first, second] {
            XCTAssertEqual(visibleWelcomeNotes(replica).count, 1)
            XCTAssertEqual(replica.placements.filter { $0.item.kind == .note }.count, 1)
            let text = try await replica.openNote(welcome).text
            XCTAssertTrue(text.contains("First device line."))
            XCTAssertTrue(text.contains("Second device line."))
        }
    }

    func testUntouchedWelcomeNoteStaysOutOfAnOlderCloudNotebook() async throws {
        let transport = InMemorySyncTransport(scope: "welcome-older")
        let remote = try await olderCloudNotebook(transport)

        let fresh = try await freshDevice()
        let sync = NotebookSyncCoordinator(replica: fresh, transport: transport)
        await sync.synchronize()
        assertSuccess(sync)
        let remoteSync = NotebookSyncCoordinator(replica: remote, transport: transport)
        await remoteSync.synchronize()
        assertSuccess(remoteSync)

        XCTAssertTrue(visibleWelcomeNotes(fresh).isEmpty)
        XCTAssertTrue(visibleWelcomeNotes(remote).isEmpty)
        XCTAssertEqual(fresh.placements.map(\.item.name), ["Plan.md"])
    }

    func testEditedWelcomeNoteJoinsAnOlderCloudNotebook() async throws {
        let transport = InMemorySyncTransport(scope: "welcome-edited")
        let remote = try await olderCloudNotebook(transport)

        let fresh = try await freshDevice()
        try await edit(fresh, append: "\nMy own words.")
        let sync = NotebookSyncCoordinator(replica: fresh, transport: transport)
        await sync.synchronize()
        assertSuccess(sync)
        let remoteSync = NotebookSyncCoordinator(replica: remote, transport: transport)
        await remoteSync.synchronize()
        assertSuccess(remoteSync)

        XCTAssertEqual(visibleWelcomeNotes(remote).count, 1)
        let text = try await remote.openNote(welcome).text
        XCTAssertTrue(text.contains("My own words."))
    }

    func testWelcomeNoteDeletedOnOneDeviceStaysDeletedOnANewDevice() async throws {
        let transport = InMemorySyncTransport(scope: "welcome-deleted")
        let first = try await freshDevice()
        let firstSync = NotebookSyncCoordinator(replica: first, transport: transport)
        await firstSync.synchronize()
        _ = try await first.trashItems([welcome])
        try await first.permanentlyDelete(first.deletionSelection(rootIDs: [welcome]))
        await firstSync.synchronize()
        assertSuccess(firstSync)

        let second = try await freshDevice()
        let secondSync = NotebookSyncCoordinator(replica: second, transport: transport)
        await secondSync.synchronize()
        assertSuccess(secondSync)

        XCTAssertTrue(visibleWelcomeNotes(second).isEmpty)
        XCTAssertFalse(second.placements.contains {
            $0.item.id == self.welcome && $0.isInTrash && !$0.item.isPermanentlyDeleted
        })
    }

    func testWelcomeNoteTrashedOnOneDeviceStaysInTrashOnANewDevice() async throws {
        let transport = InMemorySyncTransport(scope: "welcome-trashed")
        let first = try await freshDevice()
        let firstSync = NotebookSyncCoordinator(replica: first, transport: transport)
        await firstSync.synchronize()
        _ = try await first.trashItems([welcome])
        await firstSync.synchronize()
        assertSuccess(firstSync)

        let second = try await freshDevice()
        let secondSync = NotebookSyncCoordinator(replica: second, transport: transport)
        await secondSync.synchronize()
        assertSuccess(secondSync)

        XCTAssertTrue(visibleWelcomeNotes(second).isEmpty)
        XCTAssertTrue(second.placements.contains { $0.item.id == self.welcome && $0.isInTrash })
    }

    func testWelcomeNoteDeletedOfflineIsDeletedEverywhereAfterJoining() async throws {
        let transport = InMemorySyncTransport(scope: "welcome-deleted-offline")
        let first = try await freshDevice()
        let firstSync = NotebookSyncCoordinator(replica: first, transport: transport)
        await firstSync.synchronize()
        assertSuccess(firstSync)

        let second = try await freshDevice()
        _ = try await second.trashItems([welcome])
        try await second.permanentlyDelete(second.deletionSelection(rootIDs: [welcome]))
        let secondSync = NotebookSyncCoordinator(replica: second, transport: transport)
        await secondSync.synchronize()
        assertSuccess(secondSync)
        await firstSync.synchronize()
        assertSuccess(firstSync)

        XCTAssertTrue(visibleWelcomeNotes(first).isEmpty)
        XCTAssertTrue(visibleWelcomeNotes(second).isEmpty)
    }

    func testMissingWelcomeNoteIsAddedToAnExistingNotebookOnce() async throws {
        let replica = NotebookReplica(directory: directory())
        try await replica.createNotebookForSync()
        _ = try await replica.createNote(name: "Plan.md", text: "Existing note")

        let added = try await replica.addMissingWelcomeNote()
        let addedAgain = try await replica.addMissingWelcomeNote()

        XCTAssertTrue(added)
        XCTAssertFalse(addedAgain)
        XCTAssertEqual(visibleWelcomeNotes(replica).count, 1)
        let session = try await replica.openNote(welcome)
        XCTAssertEqual(session.currentSnapshot?.heads, NotebookWelcomeNote.heads)
    }

    func testTrashedOrDeletedWelcomeNoteIsNotAddedAgain() async throws {
        let trashed = try await freshDevice()
        _ = try await trashed.trashItems([welcome])
        let deleted = try await freshDevice()
        _ = try await deleted.trashItems([welcome])
        try await deleted.permanentlyDelete(deleted.deletionSelection(rootIDs: [welcome]))

        for replica in [trashed, deleted] {
            let added = try await replica.addMissingWelcomeNote()
            XCTAssertFalse(added)
            XCTAssertTrue(visibleWelcomeNotes(replica).isEmpty)
        }
    }

    private func freshDevice() async throws -> NotebookReplica {
        let replica = NotebookReplica(directory: directory())
        try await replica.createNotebookForSync()
        try await replica.addWelcomeNote()
        return replica
    }

    /// A notebook from before welcome notes existed.
    private func olderCloudNotebook(
        _ transport: InMemorySyncTransport
    ) async throws -> NotebookReplica {
        let remote = NotebookReplica(directory: directory())
        let sync = NotebookSyncCoordinator(replica: remote, transport: transport)
        await sync.synchronize()
        _ = try await remote.createNote(name: "Plan.md", text: "Existing cloud note")
        await sync.synchronize()
        assertSuccess(sync)
        return remote
    }

    private func edit(_ replica: NotebookReplica, append line: String) async throws {
        let session = try await replica.openNote(welcome)
        try session.replaceAll(with: session.text + line)
        try await session.flush()
    }

    private func visibleWelcomeNotes(_ replica: NotebookReplica) -> [NotebookPlacement] {
        replica.placements.filter {
            $0.item.id == welcome && !$0.isInTrash && !$0.item.isPermanentlyDeleted
        }
    }

    private func directory() -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        roots.append(root)
        return root
    }

    private func assertSuccess(_ sync: NotebookSyncCoordinator,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(sync.lastError, "\(String(describing: sync.lastError))", file: file, line: line)
        guard case .exchanged = sync.status else {
            return XCTFail("Expected completed sync: \(sync.status)", file: file, line: line)
        }
    }
}
