import Automerge
import Foundation
import XCTest

@testable import NoteCore

final class NotebookBrowserTransactionTests: XCTestCase {
    func testBatchMoveNormalizesDescendantsAndRoundTripsUndoRedo() throws {
        let catalog = try NotebookCatalogDocument()
        let source = try catalog.add(kind: .folder, name: "Source")
        let destination = try catalog.add(kind: .folder, name: "Destination")
        let existing = try catalog.add(
            kind: .note, name: "Existing.md", parentID: destination)
        let folder = try catalog.add(
            kind: .folder, name: "Folder", parentID: source)
        let child = try catalog.add(
            kind: .note, name: "Child.md", parentID: folder)
        let note = try catalog.add(
            kind: .note, name: "Note.md", parentID: source)

        let receipt = try XCTUnwrap(
            catalog.moveItems([child, folder, note], to: destination)
        )

        XCTAssertEqual(receipt.itemIDs, [folder, note])
        XCTAssertEqual(
            try catalog.orderedChildren(
                parentID: destination, inTrash: false
            ).map(\.item.id),
            [existing, folder, note]
        )
        XCTAssertEqual(
            try catalog.placements().first { $0.item.id == child }?.parentID,
            folder
        )

        let redo = try catalog.undoBrowserChange(receipt)
        XCTAssertEqual(
            try catalog.orderedChildren(parentID: source, inTrash: false)
                .map(\.item.id),
            [folder, note]
        )
        XCTAssertEqual(
            try catalog.orderedChildren(
                parentID: destination, inTrash: false
            ).map(\.item.id),
            [existing]
        )

        _ = try catalog.undoBrowserChange(redo)
        XCTAssertEqual(
            try catalog.orderedChildren(
                parentID: destination, inTrash: false
            ).map(\.item.id),
            [existing, folder, note]
        )
    }

    func testInvalidBatchMoveLeavesCatalogUnchanged() throws {
        let catalog = try NotebookCatalogDocument()
        let folder = try catalog.add(kind: .folder, name: "Folder")
        let child = try catalog.add(
            kind: .folder, name: "Child", parentID: folder)
        let before = catalog.snapshot()

        XCTAssertThrowsError(try catalog.moveItems([folder], to: child)) {
            XCTAssertEqual(
                $0 as? NotebookBrowserChangeError,
                .invalidDestination
            )
        }
        XCTAssertEqual(catalog.snapshot(), before)
    }

    func testBatchMoveToRootKeepsEveryItemInFinalGraph() throws {
        let catalog = try NotebookCatalogDocument()
        let folder = try catalog.add(kind: .folder, name: "Folder")
        let first = try catalog.add(
            kind: .note, name: "First.md", parentID: folder)
        let second = try catalog.add(
            kind: .note, name: "Second.md", parentID: folder)

        _ = try catalog.moveItems([first, second], to: nil)

        let placements = try catalog.placements()
        XCTAssertNil(placements.first { $0.item.id == first }?.parentID)
        XCTAssertNil(placements.first { $0.item.id == second }?.parentID)
        XCTAssertEqual(Set(placements.map(\.item.id)), [folder, first, second])
    }

    func testMoveAlreadyAtEndIsByteExactNoOp() throws {
        let catalog = try NotebookCatalogDocument()
        let folder = try catalog.add(kind: .folder, name: "Folder")
        _ = try catalog.add(kind: .note, name: "First.md", parentID: folder)
        let second = try catalog.add(
            kind: .note, name: "Second.md", parentID: folder)
        let before = catalog.snapshot()

        XCTAssertNil(try catalog.moveItems([second], to: folder))
        XCTAssertEqual(catalog.snapshot(), before)
    }

    func testHundredItemBatchPreservesSuppliedOrderAndUndo() throws {
        let catalog = try NotebookCatalogDocument()
        let source = try catalog.add(kind: .folder, name: "Source")
        let destination = try catalog.add(kind: .folder, name: "Destination")
        let existing = try catalog.add(
            kind: .note, name: "Existing.md", parentID: destination)
        var ids: [UUID] = []
        for index in 0 ..< 100 {
            ids.append(
                try catalog.add(
                    kind: .note,
                    name: String(format: "%03d.md", index),
                    parentID: source
                )
            )
        }
        let supplied = Array(ids.reversed())

        let receipt = try XCTUnwrap(
            catalog.moveItems(supplied, to: destination)
        )
        XCTAssertEqual(
            try catalog.orderedChildren(
                parentID: destination, inTrash: false
            ).map(\.item.id),
            [existing] + supplied
        )

        _ = try catalog.undoBrowserChange(receipt)
        XCTAssertEqual(
            try catalog.orderedChildren(parentID: source, inTrash: false)
                .map(\.item.id),
            ids
        )
    }

    func testMoveUndoPreservesUnrelatedRename() throws {
        let base = try NotebookCatalogDocument()
        let destination = try base.add(kind: .folder, name: "Destination")
        let note = try base.add(kind: .note, name: "Before.md")
        let catalog = try base.fork()
        let remote = try base.fork()
        let receipt = try XCTUnwrap(
            catalog.moveItems([note], to: destination)
        )

        try remote.rename(note, to: "After.md")
        try catalog.merge(remote)
        _ = try catalog.undoBrowserChange(receipt)

        let restored = try XCTUnwrap(
            catalog.placements().first { $0.item.id == note }
        )
        XCTAssertNil(restored.parentID)
        XCTAssertEqual(restored.item.name, "After.md")
    }

    func testMoveUndoRefusesChangedOrderWithoutPartialRestore() throws {
        let catalog = try NotebookCatalogDocument()
        let destination = try catalog.add(kind: .folder, name: "Destination")
        let existing = try catalog.add(
            kind: .note, name: "Existing.md", parentID: destination)
        let note = try catalog.add(kind: .note, name: "Note.md")
        let receipt = try XCTUnwrap(
            catalog.moveItems([note], to: destination)
        )
        let remote = try catalog.fork()
        try remote.reorder(
            [note], parentID: destination, before: existing
        )
        try catalog.merge(remote)
        let beforeUndo = catalog.snapshot()

        XCTAssertThrowsError(try catalog.undoBrowserChange(receipt)) {
            XCTAssertEqual($0 as? NotebookBrowserChangeError, .staleUndo)
        }
        XCTAssertEqual(catalog.snapshot(), beforeUndo)
    }

    func testMoveUndoRefusesCycleCreatedThroughOldSource() throws {
        let catalog = try NotebookCatalogDocument()
        let source = try catalog.add(kind: .folder, name: "Source")
        let destination = try catalog.add(kind: .folder, name: "Destination")
        let moved = try catalog.add(
            kind: .folder, name: "Moved", parentID: source)
        let receipt = try XCTUnwrap(
            catalog.moveItems([moved], to: destination)
        )
        let remote = try catalog.fork()
        try remote.move(source, to: moved)
        try catalog.merge(remote)
        let beforeUndo = catalog.snapshot()

        XCTAssertThrowsError(try catalog.undoBrowserChange(receipt)) {
            XCTAssertEqual($0 as? NotebookBrowserChangeError, .staleUndo)
        }
        XCTAssertEqual(catalog.snapshot(), beforeUndo)
    }

    func testMoveUndoRefusesPermanentlyDeletedOldSource() throws {
        let catalog = try NotebookCatalogDocument()
        let source = try catalog.add(kind: .folder, name: "Source")
        let destination = try catalog.add(kind: .folder, name: "Destination")
        let moved = try catalog.add(
            kind: .note, name: "Moved.md", parentID: source)
        let receipt = try XCTUnwrap(
            catalog.moveItems([moved], to: destination)
        )
        let remote = try catalog.fork()
        try remote.markPermanentlyDeleted([source])
        try catalog.merge(remote)
        let beforeUndo = catalog.snapshot()

        XCTAssertThrowsError(try catalog.undoBrowserChange(receipt)) {
            XCTAssertEqual($0 as? NotebookBrowserChangeError, .staleUndo)
        }
        XCTAssertEqual(catalog.snapshot(), beforeUndo)
    }

    func testUnrelatedMissingParentDoesNotBlockMoveUndo() throws {
        let catalog = try NotebookCatalogDocument()
        let source = try catalog.add(kind: .folder, name: "Source")
        let destination = try catalog.add(kind: .folder, name: "Destination")
        let moved = try catalog.add(
            kind: .note, name: "Moved.md", parentID: source)
        let unrelated = try catalog.add(kind: .note, name: "Unrelated.md")
        let receipt = try XCTUnwrap(
            catalog.moveItems([moved], to: destination)
        )
        let recovered = try replacingParent(
            of: unrelated, with: UUID(), in: catalog)

        _ = try recovered.undoBrowserChange(receipt)

        XCTAssertEqual(
            try recovered.placements().first { $0.item.id == moved }?.parentID,
            source
        )
        XCTAssertTrue(
            try XCTUnwrap(
                recovered.placements().first { $0.item.id == unrelated }
            ).issues.contains(.missingParent)
        )
    }

    func testRepairingRecoveredMoveReturnsNoStaleReceipt() throws {
        let catalog = try NotebookCatalogDocument()
        let destination = try catalog.add(kind: .folder, name: "Destination")
        let note = try catalog.add(kind: .note, name: "Recovered.md")
        let recovered = try replacingParent(
            of: note, with: UUID(), in: catalog)

        XCTAssertNil(try recovered.moveItems([note], to: destination))
        let placement = try XCTUnwrap(
            recovered.placements().first { $0.item.id == note }
        )
        XCTAssertEqual(placement.parentID, destination)
        XCTAssertFalse(placement.issues.contains(.missingParent))
    }

    func testTrashNormalizesSubtreeAndUndoKeepsDescendantTrashIntent() throws {
        let base = try NotebookCatalogDocument()
        let folder = try base.add(kind: .folder, name: "Folder")
        let child = try base.add(
            kind: .note, name: "Child.md", parentID: folder)
        let catalog = try base.fork()
        let remote = try base.fork()

        let receipt = try catalog.trashItems([child, folder])
        XCTAssertEqual(receipt.itemIDs, [folder])
        try remote.setTrashed(child, true)
        try catalog.merge(remote)
        let redo = try catalog.undoBrowserChange(receipt)

        let placements = try catalog.placements()
        XCTAssertFalse(
            try XCTUnwrap(placements.first { $0.item.id == folder }).isInTrash
        )
        XCTAssertTrue(
            try XCTUnwrap(placements.first { $0.item.id == child }).isInTrash
        )

        _ = try catalog.undoBrowserChange(redo)
        XCTAssertTrue(
            try XCTUnwrap(
                catalog.placements().first { $0.item.id == folder }
            ).isInTrash
        )
    }

    func testTrashUndoRefusesNewVisibilityIntent() throws {
        let catalog = try NotebookCatalogDocument()
        let note = try catalog.add(kind: .note, name: "Note.md")
        let receipt = try catalog.trashItems([note])
        let remote = try catalog.fork()
        try remote.setTrashed(note, false)
        try catalog.merge(remote)
        let beforeUndo = catalog.snapshot()

        XCTAssertThrowsError(try catalog.undoBrowserChange(receipt)) {
            XCTAssertEqual($0 as? NotebookBrowserChangeError, .staleUndo)
        }
        XCTAssertEqual(catalog.snapshot(), beforeUndo)
    }

    func testTrashUndoAllowsRecoveredParent() throws {
        let catalog = try NotebookCatalogDocument()
        let note = try catalog.add(kind: .note, name: "Recovered.md")
        let receipt = try catalog.trashItems([note])
        let recovered = try replacingParent(
            of: note, with: UUID(), in: catalog)

        _ = try recovered.undoBrowserChange(receipt)

        let placement = try XCTUnwrap(
            recovered.placements().first { $0.item.id == note }
        )
        XCTAssertFalse(placement.isInTrash)
        XCTAssertTrue(placement.issues.contains(.missingParent))
    }

    func testLegacyMoveUndoRestoresOldPositionAfterSourceAppend() throws {
        let current = try NotebookCatalogDocument()
        let destination = try current.add(kind: .folder, name: "Destination")
        _ = try current.add(kind: .note, name: "A.md")
        let moved = try current.add(kind: .note, name: "B.md")
        _ = try current.add(kind: .note, name: "C.md")
        let catalog = try removingOrderMetadata(from: current)

        let receipt = try XCTUnwrap(
            catalog.moveItems([moved], to: destination)
        )
        _ = try catalog.add(kind: .note, name: "D.md")
        _ = try catalog.undoBrowserChange(receipt)

        XCTAssertEqual(
            try catalog.orderedChildren(parentID: nil, inTrash: false)
                .filter { $0.item.kind == .note }
                .map(\.displayName),
            ["A.md", "B.md", "C.md", "D.md"]
        )
    }

    func testMalformedPlacementRevisionIsRejectedOnLoad() throws {
        let catalog = try NotebookCatalogDocument()
        let note = try catalog.add(kind: .note, name: "Note.md")
        let raw = try Document(catalog.snapshot().data)
        guard case .Object(let items, .Map) = try raw.get(
            obj: .ROOT, key: "items"
        ), case .Object(let item, .Map) = try raw.get(
            obj: items, key: note.uuidString
        ) else {
            return XCTFail("Expected note metadata map")
        }
        try raw.put(
            obj: item, key: "placementRevision", value: .String("invalid")
        )

        XCTAssertThrowsError(
            try NotebookCatalogDocument(serializedData: raw.save())
        ) {
            XCTAssertEqual($0 as? NotebookCatalogError, .invalidDocument)
        }
    }

    private func removingOrderMetadata(
        from catalog: NotebookCatalogDocument
    ) throws -> NotebookCatalogDocument {
        let raw = try Document(catalog.snapshot().data)
        guard case .Object(let items, .Map) = try raw.get(
            obj: .ROOT, key: "items"
        ) else {
            throw NotebookCatalogError.invalidDocument
        }
        for key in raw.keys(obj: items) {
            guard case .Object(let item, .Map) = try raw.get(
                obj: items, key: key
            ) else {
                throw NotebookCatalogError.invalidDocument
            }
            for metadataKey in raw.keys(obj: item)
            where metadataKey.hasPrefix("order:")
                || metadataKey.hasPrefix("orderSeed:") {
                try raw.delete(obj: item, key: metadataKey)
            }
        }
        return try NotebookCatalogDocument(serializedData: raw.save())
    }

    private func replacingParent(
        of id: UUID,
        with parentID: UUID?,
        in catalog: NotebookCatalogDocument
    ) throws -> NotebookCatalogDocument {
        let raw = try Document(catalog.snapshot().data)
        guard case .Object(let items, .Map) = try raw.get(
            obj: .ROOT, key: "items"
        ), case .Object(let item, .Map) = try raw.get(
            obj: items, key: id.uuidString
        ) else {
            throw NotebookCatalogError.invalidDocument
        }
        try raw.put(
            obj: item,
            key: "parent",
            value: parentID.map { .String($0.uuidString) } ?? .Null
        )
        return try NotebookCatalogDocument(serializedData: raw.save())
    }
}
