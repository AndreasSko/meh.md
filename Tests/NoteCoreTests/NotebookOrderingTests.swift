import Automerge
import Foundation
import XCTest

@testable import NoteCore

final class NotebookOrderingTests: XCTestCase {
    func testLegacyCatalogUsesAlphabeticalFoldersFirstFallback() throws {
        let catalog = try NotebookCatalogDocument()
        let note = try catalog.add(kind: .note, name: "A.md")
        let secondFolder = try catalog.add(kind: .folder, name: "Zulu")
        let firstFolder = try catalog.add(kind: .folder, name: "Alpha")
        let legacy = try removingOrderMetadata(from: catalog)

        XCTAssertEqual(
            try legacy.orderedChildren(parentID: nil, inTrash: false)
                .map(\.item.id),
            [firstFolder, secondFolder, note]
        )
        XCTAssertTrue(try legacy.items().allSatisfy { $0.orderKey == nil })
    }

    func testFullReorderAllowsFoldersAndNotesToInterleaveAfterReload() throws {
        let catalog = try NotebookCatalogDocument()
        let folder = try catalog.add(kind: .folder, name: "Folder")
        let first = try catalog.add(kind: .note, name: "First.md")
        let second = try catalog.add(kind: .note, name: "Second.md")

        try catalog.reorder(
            [first, folder, second], parentID: nil, before: nil
        )
        let reloaded = try NotebookCatalogDocument(snapshot: catalog.snapshot())

        XCTAssertEqual(
            try reloaded.orderedChildren(parentID: nil, inTrash: false)
                .map(\.item.id),
            [first, folder, second]
        )
    }

    func testConcurrentDifferentItemReordersCombine() throws {
        let base = try fourItemCatalog()
        let ids = try base.orderedChildren(parentID: nil, inTrash: false)
            .map(\.item.id)
        let left = try base.fork()
        let right = try base.fork()

        try left.reorder([ids[3]], parentID: nil, before: ids[1])
        try right.reorder([ids[2]], parentID: nil, before: ids[0])
        try assertConvergence(left, right)

        XCTAssertEqual(
            try left.orderedChildren(parentID: nil, inTrash: false)
                .map(\.item.id),
            [ids[2], ids[0], ids[3], ids[1]]
        )
    }

    func testConcurrentFirstReordersOnLegacyCatalogPreserveBothIntents() throws {
        let current = try fourItemCatalog()
        let base = try removingOrderMetadata(from: current)
        let ids = try base.orderedChildren(parentID: nil, inTrash: false)
            .map(\.item.id)
        let left = try base.fork()
        let right = try base.fork()

        try left.reorder([ids[3]], parentID: nil, before: ids[1])
        try right.reorder([ids[2]], parentID: nil, before: ids[0])
        try assertConvergence(left, right)

        XCTAssertEqual(
            try left.orderedChildren(parentID: nil, inTrash: false)
                .map(\.item.id),
            [ids[2], ids[0], ids[3], ids[1]]
        )
    }

    func testLegacyItemAddedAfterManualOrderStaysAtEnd() throws {
        let catalog = try fourItemCatalog()
        let ids = try catalog.orderedChildren(
            parentID: nil, inTrash: false
        ).map(\.item.id)
        try catalog.reorder([ids[3]], parentID: nil, before: ids[0])
        let mixed = try removingOrderMetadata(
            from: catalog, itemIDs: [ids[1]]
        )

        let appended = try mixed.add(kind: .note, name: "New.md")

        XCTAssertEqual(
            try mixed.orderedChildren(parentID: nil, inTrash: false)
                .map(\.item.id),
            [ids[3], ids[0], ids[2], ids[1], appended]
        )
    }

    func testSameItemConcurrentReorderHasDeterministicWinner() throws {
        let base = try fourItemCatalog()
        let ids = try base.orderedChildren(parentID: nil, inTrash: false)
            .map(\.item.id)
        let leftChange = try base.fork()
        let rightChange = try base.fork()
        try leftChange.reorder([ids[3]], parentID: nil, before: ids[0])
        try rightChange.reorder([ids[3]], parentID: nil, before: ids[2])

        let first = try leftChange.fork()
        try first.merge(rightChange)
        let second = try rightChange.fork()
        try second.merge(leftChange)

        XCTAssertEqual(
            try first.orderedChildren(parentID: nil, inTrash: false),
            try second.orderedChildren(parentID: nil, inTrash: false)
        )
        XCTAssertEqual(first.heads, second.heads)
        XCTAssertTrue(
            try first.placements().first { $0.item.id == ids[3] }!
                .issues.contains(.concurrentReorder)
        )
    }

    func testThreeReplicaReordersConvergeInEveryDeliveryOrder() throws {
        let base = try fourItemCatalog()
        let ids = try base.orderedChildren(parentID: nil, inTrash: false)
            .map(\.item.id)
        let firstChange = try base.fork()
        let secondChange = try base.fork()
        let thirdChange = try base.fork()
        try firstChange.reorder([ids[3]], parentID: nil, before: ids[0])
        try secondChange.reorder([ids[2]], parentID: nil, before: ids[1])
        try thirdChange.reorder([ids[3]], parentID: nil, before: ids[2])

        let first = try merged([firstChange, secondChange, thirdChange])
        let second = try merged([thirdChange, firstChange, secondChange])
        let third = try merged([secondChange, thirdChange, firstChange])

        XCTAssertEqual(try first.placements(), try second.placements())
        XCTAssertEqual(try second.placements(), try third.placements())
        XCTAssertEqual(first.heads, second.heads)
        XCTAssertEqual(second.heads, third.heads)
    }

    func testMoveWinsConcurrentReorderInOldParent() throws {
        let base = try NotebookCatalogDocument()
        let source = try base.add(kind: .folder, name: "Source")
        let destination = try base.add(kind: .folder, name: "Destination")
        let first = try base.add(
            kind: .note, name: "First.md", parentID: source
        )
        let second = try base.add(
            kind: .note, name: "Second.md", parentID: source
        )
        let moving = try base.fork()
        let reordering = try base.fork()

        try moving.move(first, to: destination)
        try reordering.reorder(
            [first], parentID: source, before: second
        )
        try assertConvergence(moving, reordering)

        XCTAssertEqual(
            try moving.orderedChildren(
                parentID: destination, inTrash: false
            ).map(\.item.id),
            [first]
        )
        XCTAssertEqual(
            try moving.orderedChildren(
                parentID: source, inTrash: false
            ).map(\.item.id),
            [second]
        )
    }

    func testConcurrentAppendsHaveDistinctConvergentRanks() throws {
        let base = try NotebookCatalogDocument()
        _ = try base.add(kind: .note, name: "Existing.md")
        let left = try base.fork()
        let right = try base.fork()
        let low = UUID(
            uuidString: "00000000-0000-0000-0000-000000000001"
        )!
        let high = UUID(
            uuidString: "00000000-0000-0000-0000-000000000002"
        )!

        try left.add(id: low, kind: .note, name: "Left.md")
        try right.add(id: high, kind: .note, name: "Right.md")
        try assertConvergence(left, right)

        let appended = try left.orderedChildren(
            parentID: nil, inTrash: false
        ).suffix(2)
        XCTAssertEqual(appended.map(\.item.id), [low, high])
        XCTAssertEqual(Set(appended.compactMap(\.item.orderKey)).count, 2)
    }

    func testRankFactoryHandlesRepeatedInsertionIntoSameGap() throws {
        let upperID = UUID(
            uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"
        )!
        var upper = try NotebookOrderKeyFactory.between(
            nil, nil, itemID: upperID
        )
        let originalUpper = upper

        for value in 1 ... 2_000 {
            let id = UUID(
                uuidString: String(
                    format: "00000000-0000-0000-0000-%012llX", value
                )
            )!
            let inserted = try NotebookOrderKeyFactory.between(
                nil, upper, itemID: id
            )
            XCTAssertLessThan(inserted, upper)
            upper = inserted
        }

        XCTAssertLessThan(upper, originalUpper)
        XCTAssertLessThan(
            upper.rawValue.split(separator: ".").count,
            NotebookOrderKey.maximumComponentCount
        )
    }

    func testMalformedOrderMetadataIsRejected() throws {
        let catalog = try NotebookCatalogDocument()
        let id = try catalog.add(kind: .note, name: "Note.md")
        let raw = try Document(catalog.snapshot().data)
        let item = try itemObject(id, in: raw)
        try raw.put(
            obj: item,
            key: "order:root",
            value: .String("not-a-rank")
        )

        XCTAssertThrowsError(
            try NotebookCatalogDocument(serializedData: raw.save())
        ) {
            XCTAssertEqual(
                $0 as? NotebookCatalogError,
                .invalidDocument
            )
        }
    }

    private func fourItemCatalog() throws -> NotebookCatalogDocument {
        let catalog = try NotebookCatalogDocument()
        for name in ["A.md", "B.md", "C.md", "D.md"] {
            _ = try catalog.add(kind: .note, name: name)
        }
        return catalog
    }

    private func removingOrderMetadata(
        from catalog: NotebookCatalogDocument,
        itemIDs: Set<UUID>? = nil
    ) throws -> NotebookCatalogDocument {
        let raw = try Document(catalog.snapshot().data)
        guard case .Object(let items, .Map) = try raw.get(
            obj: .ROOT, key: "items"
        ) else {
            throw NotebookCatalogError.invalidDocument
        }
        for key in raw.keys(obj: items) {
            guard let id = UUID(uuidString: key),
                  itemIDs.map({ $0.contains(id) }) ?? true else {
                continue
            }
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

    private func merged(
        _ changes: [NotebookCatalogDocument]
    ) throws -> NotebookCatalogDocument {
        let result = try changes[0].fork()
        for change in changes.dropFirst() {
            try result.merge(change)
        }
        return result
    }

    private func itemObject(_ id: UUID, in document: Document) throws -> ObjId {
        guard case .Object(let items, .Map) = try document.get(
            obj: .ROOT, key: "items"
        ), case .Object(let item, .Map) = try document.get(
            obj: items, key: id.uuidString
        ) else {
            throw NotebookCatalogError.invalidDocument
        }
        return item
    }

    private func assertConvergence(
        _ left: NotebookCatalogDocument,
        _ right: NotebookCatalogDocument
    ) throws {
        let leftBefore = try left.fork()
        let rightBefore = try right.fork()
        try left.merge(rightBefore)
        try right.merge(leftBefore)
        XCTAssertEqual(try left.placements(), try right.placements())
        XCTAssertEqual(left.heads, right.heads)
    }
}
