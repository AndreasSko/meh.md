import Automerge
import Foundation
import XCTest

@testable import NoteCore

final class NotebookCatalogTests: XCTestCase {
    private let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let high = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    func testRoundTripPreservesStableIDsAndHistory() throws {
        let catalog = try NotebookCatalogDocument()
        let folder = try catalog.add(kind: .folder, name: "Café")
        let note = try catalog.add(kind: .note, name: "👋🏽.md", parentID: folder)
        let before = catalog.heads
        try catalog.rename(note, to: "New.md")
        let loaded = try NotebookCatalogDocument(snapshot: catalog.snapshot())
        XCTAssertEqual(loaded.notebookID, catalog.notebookID)
        XCTAssertEqual(try loaded.items(), try catalog.items())
        XCTAssertTrue(before.isSubset(of: loaded.historyHeads))
    }

    func testConcurrentRenameAndMovePreserveBothOperations() throws {
        let base = try NotebookCatalogDocument()
        let folder = try base.add(kind: .folder, name: "Projects")
        let note = try base.add(kind: .note, name: "Original.md")
        let left = try base.fork()
        let right = try base.fork()
        try left.rename(note, to: "Renamed.md")
        try right.move(note, to: folder)
        try assertConvergence(left, right)
        let result = try XCTUnwrap(left.items().first { $0.id == note })
        XCTAssertEqual(result.name, "Renamed.md")
        XCTAssertEqual(result.parentID, folder)
    }

    func testConcurrentNamesRemainVisibleAndConverge() throws {
        let base = try NotebookCatalogDocument()
        let left = try base.fork()
        let right = try base.fork()
        try left.add(id: low, kind: .note, name: "Café.md")
        try right.add(id: high, kind: .note, name: "CAFE\u{301}.md")
        try assertConvergence(left, right)
        let placements = try left.placements()
        XCTAssertEqual(placements.count, 2)
        XCTAssertEqual(placements.first?.displayName, "Café.md")
        XCTAssertEqual(Set(placements.map { NotebookName.collisionKey($0.displayName) }).count, 2)
        XCTAssertTrue(placements.last!.issues.contains(.nameCollision))
        XCTAssertEqual(placements.last!.item.name, "CAFE\u{301}.md")
    }

    func testCollisionSuffixCannotStealAnotherStoredName() throws {
        let catalog = try NotebookCatalogDocument()
        try catalog.add(id: low, kind: .note, name: "a")
        try catalog.add(id: high, kind: .note, name: "a")
        let third = try catalog.add(kind: .note, name: NotebookName.collisionName("a", id: high))
        let placements = try catalog.placements()
        XCTAssertEqual(Set(placements.map { NotebookName.collisionKey($0.displayName) }).count, 3)
        XCTAssertEqual(
            placements.first { $0.item.id == third }?.displayName,
            NotebookName.collisionName("a", id: high))
    }

    func testLocalCyclesAreRejectedWithoutChangingHeads() throws {
        let catalog = try NotebookCatalogDocument()
        let parent = try catalog.add(kind: .folder, name: "Parent")
        let child = try catalog.add(kind: .folder, name: "Child", parentID: parent)
        let heads = catalog.heads
        XCTAssertThrowsError(try catalog.move(parent, to: child)) {
            XCTAssertEqual($0 as? NotebookCatalogError, .folderCycle)
        }
        XCTAssertEqual(catalog.heads, heads)
    }

    func testConcurrentFolderCycleHasDeterministicRootRepair() throws {
        let base = try NotebookCatalogDocument()
        try base.add(id: low, kind: .folder, name: "A")
        try base.add(id: high, kind: .folder, name: "B")
        let left = try base.fork()
        let right = try base.fork()
        try left.move(low, to: high)
        try right.move(high, to: low)
        try assertConvergence(left, right)
        let heads = left.heads
        let result = try left.placements()
        XCTAssertNil(result[0].parentID)
        XCTAssertEqual(result[1].parentID, low)
        XCTAssertTrue(result[0].issues.contains(.cycleRecovered))
        XCTAssertEqual(result[0].item.parentID, high, "Derived repair preserves stored intent")
        XCTAssertEqual(left.heads, heads, "Reading placement must not create new CRDT operations")
    }

    func testConcurrentTrashWinsOverRestoreThenObservedRestoreWorks() throws {
        let base = try NotebookCatalogDocument()
        let note = try base.add(kind: .note, name: "Keep.md")
        try base.setTrashed(note, true)
        let left = try base.fork()
        let right = try base.fork()
        try left.setTrashed(note, false)
        try right.setTrashed(note, true)
        try assertConvergence(left, right)
        XCTAssertTrue(try left.placements()[0].isInTrash)
        try left.setTrashed(note, false)
        XCTAssertFalse(try left.placements()[0].isInTrash)
        try right.merge(left)
        XCTAssertFalse(try right.placements()[0].isInTrash)
    }

    func testFolderTrashIncludesConcurrentChildWithoutChangingChildMetadata() throws {
        let base = try NotebookCatalogDocument()
        let folder = try base.add(kind: .folder, name: "Folder")
        let left = try base.fork()
        let right = try base.fork()
        try left.setTrashed(folder, true)
        let child = try right.add(kind: .note, name: "Offline.md", parentID: folder)
        try assertConvergence(left, right)
        let item = try XCTUnwrap(left.placements().first { $0.item.id == child })
        XCTAssertTrue(item.isInTrash)
        XCTAssertFalse(item.item.isTrashed)
        try left.setTrashed(folder, false)
        XCTAssertTrue(try left.placements().allSatisfy { !$0.isInTrash })
    }

    func testMovingOutOfTrashedFolderRecoversChild() throws {
        let catalog = try NotebookCatalogDocument()
        let folder = try catalog.add(kind: .folder, name: "Folder")
        let child = try catalog.add(kind: .note, name: "Child.md", parentID: folder)
        try catalog.setTrashed(folder, true)
        try catalog.move(child, to: nil)
        XCTAssertFalse(try catalog.placements().first { $0.item.id == child }!.isInTrash)
        XCTAssertThrowsError(try catalog.move(child, to: folder))
    }

    func testConcurrentRenameConflictIsReportedAndResolvedExplicitly() throws {
        let base = try NotebookCatalogDocument()
        let id = try base.add(kind: .note, name: "a.md")
        let left = try base.fork()
        let right = try base.fork()
        try left.rename(id, to: "left.md")
        try right.rename(id, to: "right.md")
        try assertConvergence(left, right)
        XCTAssertTrue(try left.placements()[0].issues.contains(.concurrentRename))
        try left.rename(id, to: "chosen.md")
        XCTAssertFalse(try left.placements()[0].issues.contains(.concurrentRename))
    }

    func testMissingRemoteParentIsVisibleAtRoot() throws {
        let catalog = try NotebookCatalogDocument()
        let id = try catalog.add(kind: .note, name: "Orphan.md")
        let raw = try Document(catalog.snapshot().data)
        guard case .Object(let items, .Map) = try raw.get(obj: .ROOT, key: "items"),
            case .Object(let item, .Map) = try raw.get(obj: items, key: id.uuidString)
        else {
            return XCTFail("Expected item map")
        }
        try raw.put(obj: item, key: "parent", value: .String(UUID().uuidString))
        let loaded = try NotebookCatalogDocument(serializedData: raw.save())
        XCTAssertNil(try loaded.placements()[0].parentID)
        XCTAssertTrue(try loaded.placements()[0].issues.contains(.missingParent))
    }

    func testDuplicateIdentityMergeIsRejectedWithoutPoisoningLiveCatalog() throws {
        let base = try NotebookCatalogDocument()
        let left = try base.fork()
        let right = try base.fork()
        try left.add(id: low, kind: .note, name: "left.md")
        try right.add(id: low, kind: .note, name: "right.md")
        let before = left.snapshot()
        XCTAssertThrowsError(try left.merge(right)) {
            XCTAssertEqual($0 as? NotebookCatalogError, .duplicateIdentity)
        }
        XCTAssertEqual(left.snapshot(), before)
    }

    func testIndependentSameIdentityDoesNotEstablishSharedHistory() throws {
        let id = UUID()
        let left = try NotebookCatalogDocument(notebookID: id)
        let right = try NotebookCatalogDocument(notebookID: id)
        XCTAssertThrowsError(try left.merge(right)) {
            XCTAssertEqual($0 as? NotebookCatalogError, .disconnectedHistory)
        }
    }

    func testCatalogCannotBeLoadedAsNote() throws {
        let catalog = try NotebookCatalogDocument()
        XCTAssertThrowsError(try NoteDocument(serializedData: catalog.snapshot().data))
    }

    func testExplicitTrashRootsUseTheirOwnCollisionScope() throws {
        let catalog = try NotebookCatalogDocument()
        let a = try catalog.add(kind: .folder, name: "A")
        let b = try catalog.add(kind: .folder, name: "B")
        let first = try catalog.add(kind: .note, name: "same.md", parentID: a)
        let second = try catalog.add(kind: .note, name: "same.md", parentID: b)
        try catalog.setTrashed(first, true)
        try catalog.setTrashed(second, true)
        let trashed = try catalog.placements().filter(\.isInTrash)
        XCTAssertEqual(trashed.count, 2)
        XCTAssertTrue(trashed.allSatisfy { $0.parentID == nil })
        XCTAssertEqual(Set(trashed.map(\.displayName)).count, 2)
        XCTAssertEqual(Set(trashed.compactMap { $0.item.parentID }), [a, b])
        try catalog.setTrashed(first, false)
        XCTAssertEqual(try catalog.placements().first { $0.item.id == first }?.parentID, a)
    }

    func testConcurrentMovesReportConflictAndAnObservedMoveResolvesIt() throws {
        let base = try NotebookCatalogDocument()
        let a = try base.add(kind: .folder, name: "A")
        let b = try base.add(kind: .folder, name: "B")
        let note = try base.add(kind: .note, name: "Note.md")
        let left = try base.fork()
        let right = try base.fork()
        try left.move(note, to: a)
        try right.move(note, to: b)
        try assertConvergence(left, right)
        XCTAssertTrue(
            try left.placements().first { $0.item.id == note }!.issues.contains(.concurrentMove))
        try left.move(note, to: nil)
        XCTAssertFalse(
            try left.placements().first { $0.item.id == note }!.issues.contains(.concurrentMove))
    }

    func testTrashRetainsConcurrentRenameAndSeparateNoteBodyEdit() throws {
        let base = try NotebookCatalogDocument()
        let note = try NoteDocument(text: "before")
        try base.add(id: note.noteID, kind: .note, name: "Before.md")
        let left = try base.fork()
        let right = try base.fork()
        try left.setTrashed(note.noteID, true)
        try right.rename(note.noteID, to: "After.md")
        try note.replaceAll(with: "An offline edit that must remain recoverable")
        try assertConvergence(left, right)
        XCTAssertTrue(try left.placements()[0].isInTrash)
        XCTAssertEqual(try left.items()[0].name, "After.md")
        let reopened = try NoteDocument(snapshot: note.snapshot())
        XCTAssertEqual(try reopened.text, "An offline edit that must remain recoverable")
        try left.setTrashed(note.noteID, false)
        XCTAssertFalse(try left.placements()[0].isInTrash)
    }

    func testInvalidStoredNameIsRejectedAtCatalogBoundary() throws {
        for invalidName in ["", "..", "bad/name", String(repeating: "a", count: 256)] {
            let catalog = try NotebookCatalogDocument()
            let id = try catalog.add(kind: .note, name: "valid.md")
            let raw = try Document(catalog.snapshot().data)
            guard case .Object(let items, .Map) = try raw.get(obj: .ROOT, key: "items"),
                case .Object(let item, .Map) = try raw.get(obj: items, key: id.uuidString)
            else {
                return XCTFail("Expected item map")
            }
            try raw.put(obj: item, key: "name", value: .String(invalidName))
            XCTAssertThrowsError(try NotebookCatalogDocument(serializedData: raw.save())) {
                XCTAssertEqual($0 as? NotebookCatalogError, .invalidDocument)
            }
        }
    }

    func testLongCollisionNamesRemainValidPathComponents() throws {
        let catalog = try NotebookCatalogDocument()
        let name = String(repeating: "a", count: 252) + ".md"
        try catalog.add(kind: .note, name: name)
        try catalog.add(kind: .note, name: name)
        for placement in try catalog.placements() {
            XCTAssertNoThrow(try NotebookName.validate(placement.displayName))
            XCTAssertTrue(placement.displayName.hasSuffix(".md"))
            XCTAssertEqual(placement.item.name, name)
        }
    }

    func testThreeReplicaCycleWithIncomingTailConvergesInDifferentOrders() throws {
        let third = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let tail = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let base = try NotebookCatalogDocument()
        try base.add(id: low, kind: .folder, name: "A")
        try base.add(id: high, kind: .folder, name: "B")
        try base.add(id: third, kind: .folder, name: "C")
        try base.add(id: tail, kind: .folder, name: "Tail", parentID: low)
        let a = try base.fork()
        let b = try base.fork()
        let c = try base.fork()
        try a.move(low, to: high)
        try b.move(high, to: third)
        try c.move(third, to: low)
        let first = try a.fork()
        try first.merge(b)
        try first.merge(c)
        let second = try c.fork()
        try second.merge(a)
        try second.merge(b)
        XCTAssertEqual(try first.placements(), try second.placements())
        let repaired = try first.placements().filter { $0.issues.contains(.cycleRecovered) }
        XCTAssertEqual(repaired.map { $0.item.id }, [low])
        XCTAssertEqual(try first.placements().first { $0.item.id == tail }?.parentID, low)
    }

    private func assertConvergence(
        _ left: NotebookCatalogDocument, _ right: NotebookCatalogDocument
    ) throws {
        let leftBefore = try NotebookCatalogDocument(snapshot: left.snapshot())
        let rightBefore = try NotebookCatalogDocument(snapshot: right.snapshot())
        try left.merge(rightBefore)
        try right.merge(leftBefore)
        XCTAssertEqual(try left.placements(), try right.placements())
        XCTAssertEqual(left.heads, right.heads)
        let mergedHeads = left.heads
        try left.merge(rightBefore)
        XCTAssertEqual(left.heads, mergedHeads, "Duplicate delivery is idempotent")
    }
}
