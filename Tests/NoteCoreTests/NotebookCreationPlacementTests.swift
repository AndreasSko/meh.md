import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class NotebookCreationPlacementTests: XCTestCase {
    func testContextualCreationPersistsMixedSiblingOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let first = try await replica.createNote(name: "First.md")
        let last = try await replica.createFolder(name: "Last")
        let inserted = try await replica.createFolder(
            name: "Inserted", position: .after(first))
        let child = try await replica.createNote(name: "Existing.md", parentID: inserted)
        let newChild = try await replica.createNote(
            name: "New.md", text: "body", parentID: inserted, position: .first)
        let appended = try await replica.createNote(name: "Appended.md")

        let reopened = NotebookReplica(directory: root)
        try await reopened.load()
        XCTAssertEqual(
            reopened.orderedChildren(parentID: nil).map(\.item.id),
            [first, inserted, last, appended])
        XCTAssertEqual(
            reopened.orderedChildren(parentID: inserted).map(\.item.id),
            [newChild, child])
        let session = try await reopened.openNote(newChild)
        XCTAssertEqual(session.text, "body")
    }

    func testAnchorsMustBeActiveSiblings() throws {
        let catalog = try NotebookCatalogDocument()
        let folder = try catalog.add(kind: .folder, name: "Folder")
        let child = try catalog.add(kind: .note, name: "Child.md", parentID: folder)
        let removed = try catalog.add(kind: .note, name: "Removed.md")
        _ = try catalog.trashItems([removed])
        for anchor in [child, removed, UUID()] {
            for position in [NotebookCreationPosition.after(anchor), .before(anchor)] {
                XCTAssertThrowsError(try catalog.add(
                    kind: .folder, name: "New", position: position)) { error in
                    XCTAssertEqual(error as? NotebookCatalogError, .invalidOrder)
                }
            }
        }
        XCTAssertEqual(try catalog.items().count, 3)
    }

    func testBeforeSiblingCreationPersistsAtBeginningAndBetweenMixedItems() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let parent = try await replica.createFolder(name: "Parent")
        let first = try await replica.createNote(name: "First.md", parentID: parent)
        let last = try await replica.createFolder(name: "Last", parentID: parent)
        let beforeFirst = try await replica.createFolder(
            name: "Before First", parentID: parent, position: .before(first))
        let beforeLast = try await replica.createNote(
            name: "Before Last.md", parentID: parent, position: .before(last))

        let reopened = NotebookReplica(directory: root)
        try await reopened.load()
        XCTAssertEqual(
            reopened.orderedChildren(parentID: parent).map(\.item.id),
            [beforeFirst, first, beforeLast, last])
        XCTAssertEqual(reopened.orderedChildren(parentID: nil).map(\.item.id), [parent])
    }

    func testConcurrentInsertionBeforeSameSiblingConverges() throws {
        let base = try NotebookCatalogDocument()
        let first = try base.add(kind: .folder, name: "First")
        let anchor = try base.add(kind: .note, name: "Anchor.md")
        let left = try base.fork()
        let right = try base.fork()
        let leftID = try left.add(kind: .note, name: "Left.md", position: .before(anchor))
        let rightID = try right.add(kind: .folder, name: "Right", position: .before(anchor))
        try left.merge(right)
        try right.merge(left)
        let leftIDs = try left.orderedChildren(parentID: nil, inTrash: false).map(\.item.id)
        XCTAssertEqual(
            leftIDs,
            try right.orderedChildren(parentID: nil, inTrash: false).map(\.item.id))
        XCTAssertEqual(leftIDs.first, first)
        XCTAssertEqual(leftIDs.last, anchor)
        XCTAssertEqual(Set(leftIDs.dropFirst().dropLast()), [leftID, rightID])
    }

    func testConcurrentInsertionAfterSameSiblingConverges() throws {
        let base = try NotebookCatalogDocument()
        let anchor = try base.add(kind: .note, name: "Anchor.md")
        let tail = try base.add(kind: .folder, name: "Tail")
        let left = try base.fork()
        let right = try base.fork()
        let leftID = try left.add(kind: .note, name: "Left.md", position: .after(anchor))
        let rightID = try right.add(kind: .folder, name: "Right", position: .after(anchor))
        try left.merge(right)
        try right.merge(left)
        let leftIDs = try left.orderedChildren(parentID: nil, inTrash: false).map(\.item.id)
        XCTAssertEqual(
            leftIDs,
            try right.orderedChildren(parentID: nil, inTrash: false).map(\.item.id))
        XCTAssertEqual(leftIDs.first, anchor)
        XCTAssertEqual(leftIDs.last, tail)
        XCTAssertEqual(Set(leftIDs.dropFirst().dropLast()), [leftID, rightID])
    }

    func testQueuedCreationUsesLatestCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let entered = expectation(description: "first creation is saving")
        var release: CheckedContinuation<Void, Never>?
        replica.catalogWriteSuspension = {
            entered.fulfill()
            await withCheckedContinuation { release = $0 }
        }
        let first = Task { try await replica.createFolder(name: "First") }
        await fulfillment(of: [entered], timeout: 1)
        let second = Task { try await replica.createNote(name: "Second.md", position: .first) }
        // Let the second operation reach the occupied catalog write gate.
        for _ in 0..<10 { await Task.yield() }
        replica.catalogWriteSuspension = nil
        release?.resume()
        let firstID = try await first.value
        let secondID = try await second.value
        XCTAssertEqual(
            replica.orderedChildren(parentID: nil).map(\.item.id), [secondID, firstID])
    }
}
