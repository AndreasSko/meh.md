import Automerge
import CryptoKit
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

    func testValidatedHistoryIsDecodedOnceForUnchangedHeads() throws {
        let catalog = try NotebookCatalogDocument()
        let id = try catalog.add(kind: .note, name: "Current.md")
        let old = NotebookLinkNote(id: id, name: "Previous.md", path: "")
        try catalog.recordLinkLocations([old])
        let loaded = try NotebookCatalogDocument(snapshot: catalog.snapshot())
        XCTAssertEqual(loaded.historicalLinkLocationsDecodeCount, 1)
        XCTAssertEqual(try loaded.historicalLinkLocations()[id], [old.location])
        _ = try loaded.historicalLinkLocations()
        XCTAssertEqual(loaded.historicalLinkLocationsDecodeCount, 1)
    }

    func testChangedHeadsInvalidateVerifiedHistory() throws {
        let catalog = try NotebookCatalogDocument()
        let id = try catalog.add(kind: .note, name: "Current.md")
        let first = NotebookLinkNote(id: id, name: "First.md", path: "")
        let second = NotebookLinkNote(id: id, name: "Second.md", path: "")
        try catalog.recordLinkLocations([first])
        _ = try catalog.historicalLinkLocations()
        let before = catalog.historicalLinkLocationsDecodeCount
        try catalog.recordLinkLocations([second])
        let locations = try XCTUnwrap(catalog.historicalLinkLocations()[id])
        XCTAssertEqual(Set(locations.map(\.name)), ["First.md", "Second.md"])
        XCTAssertEqual(catalog.historicalLinkLocationsDecodeCount, before + 1)
        _ = try catalog.historicalLinkLocations()
        XCTAssertEqual(catalog.historicalLinkLocationsDecodeCount, before + 1)
    }

    func testMergedHeadsInvalidateVerifiedHistory() throws {
        let base = try NotebookCatalogDocument()
        let id = try base.add(kind: .note, name: "Current.md")
        let first = NotebookLinkNote(id: id, name: "First.md", path: "")
        let second = NotebookLinkNote(id: id, name: "Second.md", path: "")
        try base.recordLinkLocations([first])
        let local = try base.fork()
        let remote = try base.fork()
        _ = try local.historicalLinkLocations()
        let before = local.historicalLinkLocationsDecodeCount
        try remote.recordLinkLocations([second])
        try local.merge(remote)
        let locations = try XCTUnwrap(local.historicalLinkLocations()[id])
        XCTAssertEqual(Set(locations.map(\.name)), ["First.md", "Second.md"])
        XCTAssertEqual(local.historicalLinkLocationsDecodeCount, before + 1)
    }

    func testVerifiedHistoryCacheCannotHideMalformedReloadOrConflict() throws {
        let catalog = try NotebookCatalogDocument()
        let id = try catalog.add(kind: .note, name: "Current.md")
        try catalog.recordLinkLocations([.init(id: id, name: "Previous.md", path: "")])
        _ = try catalog.historicalLinkLocations()
        let snapshot = catalog.snapshot()
        let original = try Document(snapshot.data)
        let key = try XCTUnwrap(original.keys(obj: .ROOT).first { $0.hasPrefix("linkLocation.") })
        let malformed = original.fork()
        try malformed.put(obj: .ROOT, key: key, value: .String("not-json"))
        XCTAssertThrowsError(try NotebookCatalogDocument(serializedData: malformed.save())) {
            XCTAssertEqual($0 as? NotebookCatalogError, .invalidDocument)
        }
        let wrongDigest = original.fork()
        let originalValue = try XCTUnwrap(original.get(obj: .ROOT, key: key))
        guard case .Scalar(.String(let encoded)) = originalValue else {
            return XCTFail("Expected encoded history")
        }
        try wrongDigest.put(obj: .ROOT, key: key,
            value: .String(encoded.replacingOccurrences(of: "Previous.md", with: "Forged.md")))
        XCTAssertThrowsError(try NotebookCatalogDocument(serializedData: wrongDigest.save())) {
            XCTAssertEqual($0 as? NotebookCatalogError, .invalidDocument)
        }
        try malformed.merge(other: wrongDigest)
        XCTAssertEqual(try malformed.getAll(obj: .ROOT, key: key).count, 2)
        XCTAssertThrowsError(try NotebookCatalogDocument(serializedData: malformed.save())) {
            XCTAssertEqual($0 as? NotebookCatalogError, .invalidDocument)
        }
        XCTAssertEqual(try catalog.historicalLinkLocations()[id]?.first?.name, "Previous.md")
    }

    func testValidDigestWithInvalidHistoryNameUsesCatalogErrorContract() throws {
        struct ForgedRecord: Encodable {
            let noteID: UUID
            let location: NotebookLinkLocation
        }
        let catalog = try NotebookCatalogDocument()
        let id = try catalog.add(kind: .note, name: "Current.md")
        _ = try catalog.historicalLinkLocations()
        let originalHeads = catalog.heads
        let decodeCount = catalog.historicalLinkLocationsDecodeCount
        let location = NotebookLinkLocation(name: "bad/name.md", path: "")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ForgedRecord(noteID: id, location: location))
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let forged = try Document(catalog.snapshot().data)
        try forged.put(obj: .ROOT, key: "linkLocation.\(id.uuidString).\(digest)",
                       value: .String(String(decoding: data, as: UTF8.self)))
        XCTAssertThrowsError(try NotebookCatalogDocument(serializedData: forged.save())) {
            XCTAssertEqual($0 as? NotebookCatalogError, .invalidDocument)
        }
        let remote = try catalog.fork()
        try remote.recordLinkLocations([.init(id: id, name: location.name, path: location.path)])
        XCTAssertThrowsError(try catalog.merge(remote)) {
            XCTAssertEqual($0 as? NotebookCatalogError, .invalidDocument)
        }
        XCTAssertEqual(catalog.heads, originalHeads)
        XCTAssertTrue(try catalog.historicalLinkLocations().isEmpty)
        XCTAssertEqual(catalog.historicalLinkLocationsDecodeCount, decodeCount)
    }

}
