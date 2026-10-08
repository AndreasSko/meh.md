import Automerge
import Foundation
import XCTest

@testable import NoteCore

final class NotebookBrowserPlacementTests: XCTestCase {
    func testCrossFolderInsertionIsOneUndoablePlacement() throws {
        let catalog = try NotebookCatalogDocument()
        let source = try catalog.add(kind: .folder, name: "Source")
        let target = try catalog.add(kind: .folder, name: "Target")
        let a = try catalog.add(kind: .note, name: "A.md", parentID: source)
        let b = try catalog.add(kind: .note, name: "B.md", parentID: source)
        let c = try catalog.add(kind: .note, name: "C.md", parentID: source)
        let first = try catalog.add(
            kind: .note, name: "First.md", parentID: target)
        let anchor = try catalog.add(
            kind: .note, name: "Anchor.md", parentID: target)

        let undo = try XCTUnwrap(catalog.placeItems(
            [b], to: target, before: anchor))
        XCTAssertEqual(try children(catalog, target), [first, b, anchor])
        XCTAssertEqual(try children(catalog, source), [a, c])
        let redo = try catalog.undoBrowserChange(undo)
        XCTAssertEqual(try children(catalog, source), [a, b, c])
        XCTAssertEqual(try children(catalog, target), [first, anchor])
        _ = try catalog.undoBrowserChange(redo)
        XCTAssertEqual(try children(catalog, target), [first, b, anchor])
    }

    func testSameFolderOrderingBothDirectionsAndUndoRedo() throws {
        let catalog = try NotebookCatalogDocument()
        let ids = try ["A", "B", "C", "D"].map {
            try catalog.add(kind: .note, name: $0 + ".md")
        }
        let earlier = try XCTUnwrap(catalog.placeItems(
            [ids[3]], to: nil, before: ids[1]))
        XCTAssertEqual(try children(catalog),
                       [ids[0], ids[3], ids[1], ids[2]])
        let redo = try catalog.undoBrowserChange(earlier)
        XCTAssertEqual(try children(catalog), ids)
        _ = try catalog.undoBrowserChange(redo)
        let later = try XCTUnwrap(catalog.placeItems(
            [ids[0]], to: nil, before: ids[2]))
        XCTAssertEqual(try children(catalog),
                       [ids[3], ids[1], ids[0], ids[2]])
        _ = try catalog.undoBrowserChange(later)
        XCTAssertEqual(try children(catalog),
                       [ids[0], ids[3], ids[1], ids[2]])
    }

    func testIdenticalPlacementIsByteExactNoOp() throws {
        let catalog = try NotebookCatalogDocument()
        let a = try catalog.add(kind: .note, name: "A.md")
        let b = try catalog.add(kind: .note, name: "B.md")
        let c = try catalog.add(kind: .note, name: "C.md")
        let snapshot = catalog.snapshot()
        XCTAssertNil(try catalog.placeItems([a, b], to: nil, before: c))
        XCTAssertEqual(catalog.snapshot(), snapshot)
        XCTAssertNil(try catalog.placeItems([c], to: nil, before: nil))
        XCTAssertEqual(catalog.snapshot(), snapshot)
    }

    func testLegacySameFolderUndoRestoresOriginalFallbackOrder() throws {
        let catalog = try NotebookCatalogDocument()
        let ids = try ["A", "B", "C"].map {
            try catalog.add(kind: .note, name: $0 + ".md")
        }
        let raw = try Document(catalog.snapshot().data)
        guard case .Object(let items, .Map) = try raw.get(
            obj: .ROOT, key: "items") else {
            return XCTFail("Expected catalog metadata")
        }
        for id in ids {
            guard case .Object(let item, .Map) = try raw.get(
                obj: items, key: id.uuidString) else {
                return XCTFail("Expected note metadata")
            }
            for key in raw.keys(obj: item)
            where key.hasPrefix("order:") || key.hasPrefix("orderSeed:") {
                try raw.delete(obj: item, key: key)
            }
        }
        let legacy = try NotebookCatalogDocument(serializedData: raw.save())
        let undo = try XCTUnwrap(legacy.placeItems(
            [ids[2]], to: nil, before: ids[0]))
        XCTAssertEqual(try children(legacy), [ids[2], ids[0], ids[1]])
        let redo = try legacy.undoBrowserChange(undo)
        XCTAssertEqual(try children(legacy), ids)
        _ = try legacy.undoBrowserChange(redo)
        XCTAssertEqual(try children(legacy), [ids[2], ids[0], ids[1]])
    }

    func testInvalidDropCannotChangeAnyMember() throws {
        let catalog = try NotebookCatalogDocument()
        let folder = try catalog.add(kind: .folder, name: "Folder")
        let child = try catalog.add(
            kind: .folder, name: "Child", parentID: folder)
        let note = try catalog.add(kind: .note, name: "Note.md")
        let other = try catalog.add(kind: .note, name: "Other.md")
        let trashed = try catalog.add(kind: .folder, name: "Trash")
        let inherited = try catalog.add(
            kind: .folder, name: "Inherited", parentID: trashed)
        try catalog.setTrashed(trashed, true)
        let deleted = try catalog.add(kind: .folder, name: "Deleted")
        try catalog.markPermanentlyDeleted([deleted])
        let snapshot = catalog.snapshot()
        let drops: [([UUID], UUID?, UUID?)] = [
            ([], nil, nil),
            ([note, UUID()], nil, nil),
            ([note, trashed], nil, nil),
            ([note, inherited], nil, nil),
            ([note, deleted], nil, nil),
            ([note], UUID(), nil),
            ([note], other, nil),
            ([note], trashed, nil),
            ([note], inherited, nil),
            ([note], deleted, nil),
            ([folder, note], child, nil),
            ([note], nil, UUID()),
            ([note], nil, trashed),
            ([note], nil, deleted),
            ([note], nil, note),
            ([note], nil, child),
        ]
        for (ids, target, anchor) in drops {
            XCTAssertThrowsError(try catalog.placeItems(
                ids, to: target, before: anchor))
            XCTAssertEqual(catalog.snapshot(), snapshot)
        }
    }

    func testBatchInsertionNormalizesDescendantsAndSuppliedOrder() throws {
        let catalog = try NotebookCatalogDocument()
        let folder = try catalog.add(kind: .folder, name: "Folder")
        let child = try catalog.add(
            kind: .note, name: "Child.md", parentID: folder)
        let peer = try catalog.add(kind: .note, name: "Peer.md")
        let target = try catalog.add(kind: .folder, name: "Target")
        let anchor = try catalog.add(
            kind: .note, name: "Anchor.md", parentID: target)
        let undo = try XCTUnwrap(catalog.placeItems(
            [child, peer, folder, peer], to: target, before: anchor))
        XCTAssertEqual(undo.itemIDs, [peer, folder])
        XCTAssertEqual(try children(catalog, target), [peer, folder, anchor])
        XCTAssertEqual(try children(catalog, folder), [child])
        _ = try catalog.undoBrowserChange(undo)
        XCTAssertEqual(try children(catalog), [folder, peer, target])
    }

    func testUndoRefusesLaterRemoteOrderAndParentChanges() throws {
        for changesParent in [false, true] {
            let catalog = try NotebookCatalogDocument()
            let folder = try catalog.add(kind: .folder, name: "Folder")
            let a = try catalog.add(kind: .note, name: "A.md")
            let b = try catalog.add(kind: .note, name: "B.md")
            let c = try catalog.add(kind: .note, name: "C.md")
            let undo = try XCTUnwrap(catalog.placeItems(
                [c], to: nil, before: a))
            let remote = try catalog.fork()
            if changesParent {
                try remote.move(c, to: folder)
            } else {
                try remote.reorder([c], parentID: nil, before: b)
            }
            try catalog.merge(remote)
            let snapshot = catalog.snapshot()
            XCTAssertThrowsError(try catalog.undoBrowserChange(undo)) {
                XCTAssertEqual($0 as? NotebookBrowserChangeError, .staleUndo)
            }
            XCTAssertEqual(catalog.snapshot(), snapshot)
        }
    }

    func testDropRejectsForeignNotebookAndChangedSourceParents() throws {
        let catalog = try NotebookCatalogDocument()
        let folder = try catalog.add(kind: .folder, name: "Folder")
        let a = try catalog.add(kind: .note, name: "A.md")
        let b = try catalog.add(kind: .note, name: "B.md")
        let expectations = [
            NotebookBrowserPlacementExpectation(itemID: a, parentID: nil),
            NotebookBrowserPlacementExpectation(itemID: b, parentID: nil),
        ]
        let before = catalog.snapshot()
        XCTAssertThrowsError(try catalog.placeItems(
            [a, b], to: folder, before: nil, expecting: expectations,
            notebookID: UUID())) {
            XCTAssertEqual($0 as? NotebookBrowserChangeError,
                           .notebookIdentityMismatch)
        }
        XCTAssertEqual(catalog.snapshot(), before)
        try catalog.move(b, to: folder)
        let afterMove = catalog.snapshot()
        XCTAssertThrowsError(try catalog.placeItems(
            [a, b], to: nil, before: nil, expecting: expectations,
            notebookID: catalog.notebookID)) {
            XCTAssertEqual($0 as? NotebookBrowserChangeError,
                           .invalidSelection)
        }
        XCTAssertEqual(catalog.snapshot(), afterMove)
        XCTAssertThrowsError(try catalog.placeItems(
            [a, b], to: folder, before: nil,
            expecting: Array(expectations.prefix(1))))
        XCTAssertEqual(catalog.snapshot(), afterMove)
    }

    func testMissingStoredDestinationAncestryRejectsDrop() throws {
        let catalog = try NotebookCatalogDocument()
        let folder = try catalog.add(kind: .folder, name: "Recovered")
        let note = try catalog.add(kind: .note, name: "Note.md")
        let raw = try Document(catalog.snapshot().data)
        guard case .Object(let items, .Map) = try raw.get(
            obj: .ROOT, key: "items"),
              case .Object(let item, .Map) = try raw.get(
                obj: items, key: folder.uuidString) else {
            return XCTFail("Expected folder metadata")
        }
        try raw.put(obj: item, key: "parent",
                    value: .String(UUID().uuidString))
        let damaged = try NotebookCatalogDocument(serializedData: raw.save())
        let snapshot = damaged.snapshot()
        XCTAssertThrowsError(try damaged.placeItems(
            [note], to: folder, before: nil)) {
            XCTAssertEqual($0 as? NotebookBrowserChangeError,
                           .invalidDestination)
        }
        XCTAssertEqual(damaged.snapshot(), snapshot)
    }

    func testDropRejectsUnseenConflictingParentEvenWhenWinnerMatches() throws {
        let catalog = try NotebookCatalogDocument()
        let source = try catalog.add(kind: .folder, name: "Source")
        let remoteTarget = try catalog.add(kind: .folder, name: "Remote")
        let target = try catalog.add(kind: .folder, name: "Target")
        let note = try catalog.add(
            kind: .note, name: "Note.md", parentID: source)
        let firstPeer = try catalog.fork()
        let secondPeer = try catalog.fork()
        try firstPeer.move(note, to: remoteTarget)
        try secondPeer.move(note, to: target)
        try secondPeer.move(note, to: source)
        try catalog.merge(firstPeer)
        try catalog.merge(secondPeer)
        let placement = try XCTUnwrap(catalog.placements().first {
            $0.item.id == note
        })
        XCTAssertEqual(placement.item.parentID, source)
        XCTAssertTrue(placement.issues.contains(.concurrentMove))
        let snapshot = catalog.snapshot()
        XCTAssertThrowsError(try catalog.placeItems(
            [note], to: target, before: nil,
            expecting: [.init(itemID: note, parentID: source)],
            notebookID: catalog.notebookID)) {
            XCTAssertEqual($0 as? NotebookBrowserChangeError,
                           .invalidSelection)
        }
        XCTAssertEqual(catalog.snapshot(), snapshot)
        // Explicit repair moves retain their existing conflict-resolution
        // semantics, but cannot manufacture a restorable undo receipt.
        XCTAssertNil(try catalog.moveItems([note], to: target))
        XCTAssertEqual(try catalog.placements().first {
            $0.item.id == note
        }?.item.parentID, target)
    }

    private func children(
        _ catalog: NotebookCatalogDocument, _ parentID: UUID? = nil
    ) throws -> [UUID] {
        try catalog.orderedChildren(parentID: parentID, inTrash: false)
            .map(\.item.id)
    }
}

@MainActor
final class NotebookBrowserPlacementIntegrationTests: XCTestCase {
    func testPlacementIsDurablePreservesBodiesAndRoundTripsUndo() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let folder = try await replica.createFolder(name: "Moons")
        let a = try await replica.createNote(
            name: "A.md", text: "\u{FEFF}# Europa\r\n👋🏽\r\n")
        let b = try await replica.createNote(
            name: "B.md", text: "# Titan\n", parentID: folder)
        let session = try await replica.openNote(a)
        let bodies = try await replica.persistedNoteSnapshots()
        let storage = NotebookCatalogStorage(directory: root)
        let previousCurrent = try Data(contentsOf: storage.currentURL)
        let result = try await replica.placeItems([a], to: folder, before: b)
        let undo = try XCTUnwrap(result)
        XCTAssertEqual(try Data(contentsOf: storage.previousURL),
                       previousCurrent)
        XCTAssertEqual(replica.orderedChildren(parentID: folder)
            .map(\.item.id), [a, b])
        let afterBodies = try await replica.persistedNoteSnapshots()
        XCTAssertEqual(afterBodies, bodies)
        let reopened = try await replica.openNote(a)
        XCTAssertTrue(reopened === session)
        let reloaded = NotebookReplica(directory: root)
        try await reloaded.load()
        XCTAssertEqual(reloaded.orderedChildren(parentID: folder)
            .map(\.item.id), [a, b])
        let redo = try await reloaded.undoBrowserChange(undo)
        XCTAssertEqual(reloaded.orderedChildren(parentID: nil)
            .map(\.item.id), [folder, a])
        _ = try await reloaded.undoBrowserChange(redo)
        XCTAssertEqual(reloaded.orderedChildren(parentID: folder)
            .map(\.item.id), [a, b])
        let reloadedBodies = try await reloaded.persistedNoteSnapshots()
        XCTAssertEqual(reloadedBodies, bodies)
    }

    func testNoOpInsertionAndInvalidAnchorDoNotRotateStorage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let a = try await replica.createNote(name: "A.md")
        let b = try await replica.createNote(name: "B.md")
        let storage = NotebookCatalogStorage(directory: root)
        let current = try Data(contentsOf: storage.currentURL)
        let previous = try Data(contentsOf: storage.previousURL)
        let result = try await replica.placeItems([a], to: nil, before: b)
        XCTAssertNil(result)
        do {
            _ = try await replica.placeItems([a], to: nil, before: UUID())
            XCTFail("A stale anchor must reject the drop")
        } catch {
            XCTAssertEqual(error as? NotebookBrowserChangeError,
                           .invalidDestination)
        }
        XCTAssertEqual(try Data(contentsOf: storage.currentURL), current)
        XCTAssertEqual(try Data(contentsOf: storage.previousURL), previous)
    }

    func testQueuedDropChecksSourceAfterConcurrentMove() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let folder = try await replica.createFolder(name: "Folder")
        let note = try await replica.createNote(name: "Note.md")
        let identity = try XCTUnwrap(replica.catalogSnapshot?.notebookID)
        let entered = expectation(description: "move write entered")
        var release: CheckedContinuation<Void, Never>?
        replica.catalogWriteSuspension = {
            entered.fulfill()
            await withCheckedContinuation { release = $0 }
        }
        let concurrentMove = Task {
            _ = try await replica.moveItems([note], to: folder)
        }
        await fulfillment(of: [entered], timeout: 1)
        replica.catalogWriteSuspension = nil
        let drop = Task {
            try await replica.placeItems(
                [note], to: nil, before: nil,
                expecting: [.init(itemID: note, parentID: nil)],
                notebookID: identity)
        }
        await Task.yield()
        release?.resume()
        try await concurrentMove.value
        let snapshot = replica.catalogSnapshot
        do {
            _ = try await drop.value
            XCTFail("The queued drag must not reverse a newer parent move")
        } catch {
            XCTAssertEqual(error as? NotebookBrowserChangeError,
                           .invalidSelection)
        }
        XCTAssertEqual(replica.catalogSnapshot, snapshot)
        XCTAssertEqual(replica.placements.first { $0.item.id == note }?
            .item.parentID, folder)
    }
}
