import Automerge
import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class NotebookRecoveredOrderingTests: XCTestCase {
    func testRecoveredParentMismatchReorderRejectsWithoutMutation() throws {
        let catalog = try NotebookCatalogDocument()
        let root = try catalog.add(kind: .folder, name: "Root")
        let missingParent = try catalog.add(
            kind: .folder, name: "Missing Parent"
        )
        let recovered = try catalog.add(
            kind: .folder, name: "Recovered", parentID: missingParent
        )
        let damaged = try removingItem(missingParent, from: catalog)
        let before = damaged.snapshot()

        let placement = try XCTUnwrap(
            damaged.placements().first { $0.item.id == recovered }
        )
        XCTAssertNil(placement.parentID)
        XCTAssertEqual(placement.item.parentID, missingParent)
        XCTAssertTrue(placement.issues.contains(.missingParent))

        XCTAssertThrowsError(
            try damaged.reorder([recovered], parentID: nil, before: root)
        ) {
            XCTAssertEqual($0 as? NotebookCatalogError, .invalidOrder)
        }
        XCTAssertEqual(damaged.snapshot(), before)
    }

    func testRootSortIgnoresRecoveredDisplayItems() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try NotebookCatalogDocument()
        let zulu = try catalog.add(kind: .folder, name: "Zulu")
        let alpha = try catalog.add(kind: .folder, name: "Alpha")
        let missingParent = try catalog.add(
            kind: .folder, name: "Missing Parent"
        )
        let recovered = try catalog.add(
            kind: .folder, name: "Recovered", parentID: missingParent
        )
        let damaged = try removingItem(missingParent, from: catalog)
        let recoveredOrder = try item(recovered, in: damaged).orderKey
        XCTAssertNotNil(recoveredOrder)
        try await NotebookCatalogStorage(directory: root).save(
            damaged.snapshot()
        )
        let replica = NotebookReplica(directory: root)
        try await replica.load()

        try await replica.sortChildren(parentID: nil, by: .nameAscending)

        XCTAssertEqual(
            replica.orderedChildren(parentID: nil).map(\.item.id),
            [alpha, zulu, recovered]
        )
        let expected = try NotebookOrderKeyFactory.distribute(
            itemIDs: [alpha, zulu], lower: nil, upper: nil
        )
        let sorted = try NotebookCatalogDocument(
            snapshot: XCTUnwrap(replica.catalogSnapshot)
        )
        XCTAssertEqual(try item(alpha, in: sorted).orderKey, expected[alpha])
        XCTAssertEqual(try item(zulu, in: sorted).orderKey, expected[zulu])
        XCTAssertEqual(try item(recovered, in: sorted).orderKey, recoveredOrder)

        let reloaded = NotebookReplica(directory: root)
        try await reloaded.load()
        XCTAssertEqual(
            reloaded.orderedChildren(parentID: nil).map(\.item.id),
            [alpha, zulu, recovered]
        )
    }

    func testAddAndMoveAppendIgnoreRecoveredItemStoredRank() throws {
        let catalog = try NotebookCatalogDocument()
        let existing = try catalog.add(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            kind: .folder,
            name: "Existing"
        )
        let source = try catalog.add(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            kind: .folder,
            name: "Source"
        )
        let missingParent = try catalog.add(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            kind: .folder,
            name: "Missing Parent"
        )
        let recovered = try catalog.add(
            id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
            kind: .folder,
            name: "Recovered",
            parentID: missingParent
        )
        let moving = try catalog.add(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            kind: .folder,
            name: "Moving",
            parentID: source
        )
        let damaged = try removingItem(missingParent, from: catalog)
        let recoveredOrder = try XCTUnwrap(
            item(recovered, in: damaged).orderKey
        )
        let rootLower = try XCTUnwrap(item(source, in: damaged).orderKey)
        XCTAssertNotEqual(recoveredOrder, rootLower)

        let added = UUID(
            uuidString: "00000000-0000-0000-0000-000000000005"
        )!
        let expectedAdded = try NotebookOrderKeyFactory.between(
            rootLower, nil, itemID: added
        )
        try damaged.add(id: added, kind: .folder, name: "Added")
        XCTAssertEqual(try item(added, in: damaged).orderKey, expectedAdded)

        let expectedMoved = try NotebookOrderKeyFactory.between(
            expectedAdded, nil, itemID: moving
        )
        try damaged.move(moving, to: nil)
        XCTAssertEqual(try item(moving, in: damaged).orderKey, expectedMoved)
        XCTAssertEqual(
            try damaged.orderedChildren(parentID: nil, inTrash: false)
                .map(\.item.id),
            [existing, source, added, moving, recovered]
        )
        XCTAssertEqual(try item(recovered, in: damaged).orderKey, recoveredOrder)
    }

    private func removingItem(
        _ id: UUID,
        from catalog: NotebookCatalogDocument
    ) throws -> NotebookCatalogDocument {
        let raw = try Document(catalog.snapshot().data)
        guard case .Object(let items, .Map) = try raw.get(
            obj: .ROOT, key: "items"
        ) else {
            throw NotebookCatalogError.invalidDocument
        }
        try raw.delete(obj: items, key: id.uuidString)
        return try NotebookCatalogDocument(serializedData: raw.save())
    }

    private func item(
        _ id: UUID,
        in catalog: NotebookCatalogDocument
    ) throws -> NotebookItem {
        try XCTUnwrap(catalog.items().first { $0.id == id })
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "NotebookRecoveredOrderingTests-\(UUID().uuidString)"
        )
    }
}
