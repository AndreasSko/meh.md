import Foundation
import XCTest

@testable import NoteCore

final class NotebookCatalogCacheTests: XCTestCase {
    func testUnchangedReadsReuseDerivedItems() throws {
        let catalog = try NotebookCatalogDocument()
        let id = try catalog.add(kind: .note, name: "Read me.md")
        let before = catalog.readItemsDecodeCount

        XCTAssertEqual(try catalog.items().map(\.id), [id])
        XCTAssertEqual(catalog.readItemsDecodeCount, before + 1)

        _ = try catalog.items()
        _ = try catalog.placements()
        XCTAssertEqual(catalog.readItemsDecodeCount, before + 1)
    }

    func testLocalMutationInvalidatesDerivedItemsByHeads() throws {
        let catalog = try NotebookCatalogDocument()
        let first = try catalog.add(kind: .note, name: "First.md")
        _ = try catalog.items()
        let before = catalog.readItemsDecodeCount

        let second = try catalog.add(kind: .note, name: "Second.md")

        XCTAssertEqual(Set(try catalog.items().map(\.id)), [first, second])
        XCTAssertEqual(catalog.readItemsDecodeCount, before + 1)
    }

    func testMergeInvalidatesDerivedItemsByHeads() throws {
        let base = try NotebookCatalogDocument()
        let first = try base.add(kind: .note, name: "First.md")
        let local = try base.fork()
        let remote = try base.fork()
        _ = try local.items()
        let before = local.readItemsDecodeCount

        let second = try remote.add(kind: .note, name: "Second.md")
        try local.merge(remote)

        XCTAssertEqual(Set(try local.items().map(\.id)), [first, second])
        XCTAssertEqual(local.readItemsDecodeCount, before + 1)
    }

    func testRejectedMergeKeepsCachedLiveItems() throws {
        let base = try NotebookCatalogDocument()
        let left = try base.fork()
        let right = try base.fork()
        let duplicate = UUID()
        try left.add(id: duplicate, kind: .note, name: "Left.md")
        try right.add(id: duplicate, kind: .note, name: "Right.md")
        let expectedItems = try left.items()
        let before = left.readItemsDecodeCount

        XCTAssertThrowsError(try left.merge(right)) {
            XCTAssertEqual($0 as? NotebookCatalogError, .duplicateIdentity)
        }

        XCTAssertEqual(try left.items(), expectedItems)
        XCTAssertEqual(left.readItemsDecodeCount, before)
    }
}
