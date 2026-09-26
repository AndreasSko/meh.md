import Foundation
import XCTest

@testable import NoteCore

final class NotebookRecentsTests: XCTestCase {
    func testConcurrentPinAndUnpinResolveToUnpinAndObservedPinCanRestore() throws {
        let base = try NotebookCatalogDocument()
        let note = try base.add(kind: .note, name: "Note.md")
        try base.setPinnedInRecents(true, for: note)
        let left = try base.fork()
        let right = try base.fork()
        try left.setPinnedInRecents(false, for: note)
        try right.setPinnedInRecents(true, for: note)
        try left.merge(right)
        try right.merge(left)
        XCTAssertFalse(try left.recentStates()[note]!.pinned)
        XCTAssertFalse(try right.recentStates()[note]!.pinned)
        try left.setPinnedInRecents(true, for: note)
        try right.merge(left)
        XCTAssertTrue(try right.recentStates()[note]!.pinned)
    }

    func testIndependentFirstWritesMergeWithoutCompetingMapObjects() throws {
        let base = try NotebookCatalogDocument()
        let first = try base.add(kind: .note, name: "First.md")
        let second = try base.add(kind: .note, name: "Second.md")
        let left = try base.fork()
        let right = try base.fork()
        try left.setPinnedInRecents(true, for: first)
        try right.setPinnedInRecents(true, for: second)
        try left.merge(right)
        try right.merge(left)
        XCTAssertTrue(try left.recentStates()[first]!.pinned)
        XCTAssertTrue(try left.recentStates()[second]!.pinned)
        XCTAssertEqual(left.snapshot().heads, right.snapshot().heads)
    }

    func testConcurrentTrashClearWinsOverStaleEdit() throws {
        let base = try NotebookCatalogDocument()
        let note = try base.add(kind: .note, name: "Note.md")
        try base.recordRecentActivity(for: note)
        try base.setPinnedInRecents(true, for: note)
        let left = try base.fork()
        let right = try base.fork()
        try left.clearRecents(for: [note])
        try right.recordRecentActivity(for: note)
        try right.setPinnedInRecents(true, for: note)
        try left.merge(right)
        let cleared = try left.recentStates()[note]!
        XCTAssertFalse(cleared.pinned)
        XCTAssertNil(cleared.activityOrder)
        try left.recordRecentActivity(for: note)
        XCTAssertNotNil(try left.recentStates()[note]!.activityOrder)
    }

    @MainActor
    func testReplicaCapOverflowAndTrashRestore() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "recents-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let replica = NotebookReplica(directory: directory)
        try await replica.createLocalNotebook()
        var ids: [UUID] = []
        for index in 0..<6 {
            ids.append(try await replica.createNote(name: "\(index).md"))
        }
        for id in ids.prefix(5) { try await replica.setPinnedInRecents(true, for: id) }
        XCTAssertEqual(replica.pinnedRecentCount, 5)
        XCTAssertFalse(replica.canPinInRecents)
        do {
            try await replica.setPinnedInRecents(true, for: ids[5])
            XCTFail("Sixth local pin must be blocked")
        } catch NotebookReplicaError.pinLimitReached {}
        try await replica.recordRecentActivity(for: ids[5])
        XCTAssertEqual(replica.recentNotes.count, 5)
        try await replica.setTrashed(ids[0], true)
        XCTAssertEqual(replica.pinnedRecentCount, 4)
        XCTAssertEqual(replica.recentNotes.last?.id, ids[5])
        try await replica.setTrashed(ids[0], false)
        XCTAssertFalse(replica.isPinnedInRecents(ids[0]))
    }

    @MainActor
    func testRemoteTrashFromOldClientClearsPinBeforeRestore() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "recents-remote-trash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let replica = NotebookReplica(directory: directory)
        try await replica.createLocalNotebook()
        let note = try await replica.createNote(name: "Note.md")
        try await replica.recordRecentActivity(for: note)
        try await replica.setPinnedInRecents(true, for: note)

        // Older clients change visibility without clearing Recents metadata.
        let remote = try NotebookCatalogDocument(snapshot: replica.catalogSnapshot!)
        try remote.setTrashed(note, true)
        XCTAssertTrue(try remote.recentStates()[note]!.pinned)
        try await replica.apply(SyncRecord(catalog: remote.snapshot()))
        XCTAssertTrue(replica.recentNotes.isEmpty)
        XCTAssertFalse(try NotebookCatalogDocument(snapshot: replica.catalogSnapshot!)
            .recentStates()[note]!.pinned)

        try remote.setTrashed(note, false)
        try await replica.apply(SyncRecord(catalog: remote.snapshot()))
        XCTAssertFalse(replica.isPinnedInRecents(note))
        XCTAssertFalse(replica.recentNotes.contains { $0.id == note })
    }

    @MainActor
    func testTwoReplicasKeepAllConcurrentPinsInStableOrder() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "recents-merge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let left = NotebookReplica(directory: root.appending(path: "left"))
        let right = NotebookReplica(directory: root.appending(path: "right"))
        try await left.createLocalNotebook()
        var ids: [UUID] = []
        for index in 0..<6 {
            ids.append(try await left.createNote(name: "\(index).md"))
        }
        try await right.load()
        try await right.acceptSeed(SyncRecord(catalog: left.catalogSnapshot!))
        for id in ids.prefix(3) { try await left.setPinnedInRecents(true, for: id) }
        for id in ids.suffix(3) { try await right.setPinnedInRecents(true, for: id) }
        let leftSnapshot = left.catalogSnapshot!
        let rightSnapshot = right.catalogSnapshot!
        try await left.acceptSeed(SyncRecord(catalog: rightSnapshot))
        try await right.acceptSeed(SyncRecord(catalog: leftSnapshot))
        XCTAssertEqual(left.pinnedRecentCount, 6)
        XCTAssertEqual(left.recentNotes, right.recentNotes)
        XCTAssertFalse(left.canPinInRecents)
        XCTAssertEqual(Set(left.recentNotes.map(\.id)), Set(ids))
    }

    @MainActor
    func testSyncedActivityOrdersAndRefillsAfterUnpin() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "recents-activity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let left = NotebookReplica(directory: root.appending(path: "left"))
        let right = NotebookReplica(directory: root.appending(path: "right"))
        try await left.createLocalNotebook()
        var ids: [UUID] = []
        for index in 0..<6 {
            ids.append(try await left.createNote(name: "\(index).md"))
        }
        try await right.load()
        try await right.acceptSeed(SyncRecord(catalog: left.catalogSnapshot!))

        try await left.recordRecentActivity(for: ids[0])
        try await right.recordRecentActivity(for: ids[1])
        let leftSnapshot = left.catalogSnapshot!
        let rightSnapshot = right.catalogSnapshot!
        try await left.acceptSeed(SyncRecord(catalog: rightSnapshot))
        try await right.acceptSeed(SyncRecord(catalog: leftSnapshot))
        XCTAssertEqual(left.recentNotes, right.recentNotes)
        XCTAssertEqual(Set(left.recentNotes.map(\.id)), Set(ids.prefix(2)))

        let older = try XCTUnwrap(left.recentNotes.last?.id)
        try await left.recordRecentActivity(for: older)
        try await right.acceptSeed(SyncRecord(catalog: left.catalogSnapshot!))
        XCTAssertEqual(left.recentNotes.first?.id, older)
        XCTAssertEqual(left.recentNotes, right.recentNotes)

        for id in ids.suffix(4) { try await left.recordRecentActivity(for: id) }
        try await left.setPinnedInRecents(true, for: ids[0])
        try await left.setPinnedInRecents(true, for: ids[1])
        let pinnedOrder = Array(left.recentNotes.prefix(2).map(\.id))
        try await left.recordRecentActivity(for: ids[1])
        XCTAssertEqual(left.recentNotes.first?.id, ids[0])
        XCTAssertTrue(left.isLatestRecentActivity(ids[1]))
        XCTAssertFalse(left.isLatestRecentActivity(ids[0]))
        try await left.recordRecentActivity(for: ids[0])
        XCTAssertEqual(Array(left.recentNotes.prefix(2).map(\.id)), pinnedOrder)
        try await left.setPinnedInRecents(false, for: ids[0])
        XCTAssertEqual(left.recentNotes.count, 5)
        XCTAssertEqual(Set(left.recentNotes.map(\.id)).count, 5)
        XCTAssertEqual(left.recentNotes.first?.id, ids[1])
        XCTAssertTrue(left.recentNotes.contains { $0.id == ids[0] && !$0.isPinned })
        try await right.acceptSeed(SyncRecord(catalog: left.catalogSnapshot!))
        XCTAssertEqual(left.recentNotes, right.recentNotes)
    }

    @MainActor
    func testPinPublishesBeforeSaveAndRollsBackOnFailure() async throws {
        enum InjectedFailure: Error { case save }

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "recents-optimistic-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let replica = NotebookReplica(directory: directory)
        try await replica.createLocalNotebook()
        let first = try await replica.createNote(name: "First.md")
        let second = try await replica.createNote(name: "Second.md")
        try await replica.recordRecentActivity(for: first)
        try await replica.recordRecentActivity(for: second)
        XCTAssertEqual(replica.recentNotes.first?.id, second)

        let previousHeads = try XCTUnwrap(replica.catalogSnapshot).heads
        let writeEntered = expectation(description: "pin reached catalog save")
        var releaseWrite: CheckedContinuation<Void, Never>?
        replica.catalogWriteSuspension = {
            writeEntered.fulfill()
            await withCheckedContinuation { releaseWrite = $0 }
        }
        let pin = Task { try await replica.setPinnedInRecents(true, for: first) }
        await fulfillment(of: [writeEntered], timeout: 2)
        XCTAssertEqual(replica.recentNotes.first?.id, first)
        XCTAssertTrue(replica.isPinnedInRecents(first))
        XCTAssertEqual(replica.pinnedRecentCount, 1)
        XCTAssertEqual(replica.catalogSnapshot?.heads, previousHeads)

        replica.catalogWriteSuspension = nil
        releaseWrite?.resume()
        try await pin.value
        XCTAssertNotEqual(replica.catalogSnapshot?.heads, previousHeads)

        let persistedNotes = replica.recentNotes
        let persistedHeads = replica.catalogSnapshot?.heads
        replica.catalogWriteSuspension = { throw InjectedFailure.save }
        do {
            try await replica.setPinnedInRecents(false, for: first)
            XCTFail("The injected save failure must escape")
        } catch InjectedFailure.save {}
        XCTAssertEqual(replica.recentNotes, persistedNotes)
        XCTAssertEqual(replica.catalogSnapshot?.heads, persistedHeads)
        XCTAssertTrue(replica.isPinnedInRecents(first))
    }

    @MainActor
    func testPinDoesNotTouchOpenEditorSession() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "recents-editor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let replica = NotebookReplica(directory: directory)
        try await replica.createLocalNotebook()
        let id = try await replica.createNote(name: "Note.md", text: "draft")
        let session = try await replica.openNote(id)
        try session.replaceAll(with: "unsaved draft")
        let revision = session.editorRevision
        let text = session.text
        try await replica.setPinnedInRecents(true, for: id)
        XCTAssertEqual(session.text, text)
        XCTAssertEqual(session.editorRevision, revision)
        try await replica.setPinnedInRecents(false, for: id)
        XCTAssertEqual(session.text, text)
        XCTAssertEqual(session.editorRevision, revision)
    }
}
