import Automerge
import Foundation
import XCTest

@testable import NoteCore

/// Devices that each create an item under the same ID leave several copies
/// of it in the catalog, like the welcome note every new notebook adds.
/// Copies of one kind behave as one item, and edits reach every copy.
final class NotebookCatalogCopiesTests: XCTestCase {
    private let id = NotebookWelcomeNote.id

    func testTrashOnAnyCopyTrashesTheItem() throws {
        for attempt in 0..<20 {
            let (left, right) = try devicesWithOwnCopies()
            // Before the copies meet, so only this device's copy changes.
            try right.setTrashed(id, true)
            try left.merge(right)
            XCTAssertEqual(try item(in: left).isTrashed, true, "attempt \(attempt)")
            try assertMatchesFullRead(left, "attempt \(attempt)")
        }
    }

    func testRestoreAfterSeeingEveryCopyRestoresIt() throws {
        let (left, right) = try devicesWithOwnCopies()
        try right.setTrashed(id, true)
        try left.merge(right)
        try left.setTrashed(id, false)
        XCTAssertEqual(try item(in: left).isTrashed, false)
        try right.merge(left)
        XCTAssertEqual(try item(in: right).isTrashed, false)
        try assertLoadsUnderStrictCopyRule(left)
    }

    func testMovesAndReordersReachEveryCopy() throws {
        let (left, right) = try devicesWithOwnCopies()
        try left.merge(right)
        let folder = try left.add(kind: .folder, name: "Folder")
        let sibling = try left.add(kind: .note, name: "Sibling.md", parentID: folder)
        _ = try left.moveItems([id], to: folder)
        try left.reorder([id], parentID: folder, before: sibling)
        let placement = try placement(in: left)
        XCTAssertEqual(placement.parentID, folder)
        XCTAssertTrue(placement.issues.isEmpty)
        XCTAssertEqual(
            try left.orderedChildren(parentID: folder, inTrash: false).map(\.item.id),
            [id, sibling])
        try assertMatchesFullRead(left, "moved copies")
        try assertLoadsUnderStrictCopyRule(left)
    }

    func testPermanentDeletionMarksEveryCopy() throws {
        let (left, right) = try devicesWithOwnCopies()
        try left.merge(right)
        try left.setTrashed(id, true)
        try left.markPermanentlyDeleted([id])
        XCTAssertEqual(try item(in: left).isPermanentlyDeleted, true)
        try right.merge(left)
        XCTAssertEqual(try item(in: right).isPermanentlyDeleted, true)
    }

    func testConflictsListEveryNameAndFolder() throws {
        let base = try NotebookCatalogDocument()
        let folder = try base.add(kind: .folder, name: "Folder")
        let left = try base.fork()
        let right = try base.fork()
        for device in [left, right] {
            try device.add(id: id, kind: .note, name: NotebookWelcomeNote.name)
        }
        try right.rename(id, to: "Welcome.md")
        try right.move(id, to: folder)
        try left.merge(right)
        let alternatives = try placement(in: left).alternatives
        XCTAssertEqual(alternatives.names, ["Hi \u{2022}_\u{2022}", "Welcome.md"].sorted())
        XCTAssertEqual(Set(alternatives.parentIDs), [nil, folder])

        try left.rename(id, to: "Welcome.md")
        try left.move(id, to: folder)
        XCTAssertEqual(try placement(in: left).alternatives, NotebookItemAlternatives())
    }

    func testDifferentKindsUnderOneIDStayRejected() throws {
        let base = try NotebookCatalogDocument()
        let left = try base.fork()
        let right = try base.fork()
        try left.add(id: id, kind: .note, name: NotebookWelcomeNote.name)
        try right.add(id: id, kind: .folder, name: NotebookWelcomeNote.name)
        XCTAssertThrowsError(try left.merge(right)) {
            XCTAssertEqual($0 as? NotebookCatalogError, .duplicateIdentity)
        }
    }

    func testUndoIsStaleWhenAnotherCopyChanged() throws {
        let (left, right) = try devicesWithOwnCopies()
        let folder = try left.add(kind: .folder, name: "Folder")
        try left.merge(right)
        let undo = try XCTUnwrap(try left.moveItems([id], to: folder))
        // This device never saw the other copy, so only its own one moves.
        let other = try right.add(kind: .folder, name: "Other")
        _ = try right.moveItems([id], to: other)
        try left.merge(right)
        XCTAssertThrowsError(try left.undoBrowserChange(undo)) {
            XCTAssertEqual($0 as? NotebookBrowserChangeError, .staleUndo)
        }
    }

    func testUndoRestoresEveryCopy() throws {
        let (left, right) = try devicesWithOwnCopies()
        try left.merge(right)
        let folder = try left.add(kind: .folder, name: "Folder")
        let undo = try XCTUnwrap(try left.moveItems([id], to: folder))
        _ = try left.undoBrowserChange(undo)
        XCTAssertNil(try placement(in: left).parentID)
        XCTAssertTrue(try placement(in: left).issues.isEmpty)
        try assertLoadsUnderStrictCopyRule(left)
    }

    func testMoveIsNotUndoableWhenOnlySomeCopiesHaveARank() throws {
        let base = try NotebookCatalogDocument()
        let folder = try base.add(kind: .folder, name: "Folder")
        let left = try base.fork()
        let right = try base.fork()
        for device in [left, right] {
            try device.add(id: id, kind: .note, name: NotebookWelcomeNote.name)
        }
        // A round trip leaves a rank in the folder on this copy only.
        try right.move(id, to: folder)
        try right.move(id, to: nil)
        try left.merge(right)
        XCTAssertNil(try left.moveItems([id], to: folder))
        XCTAssertEqual(try placement(in: left).parentID, folder)
    }

    func testUndoIsStaleWhenACopyArrivesLater() throws {
        let base = try NotebookCatalogDocument()
        let folder = try base.add(kind: .folder, name: "Folder")
        let left = try base.fork()
        let late = try base.fork()
        try left.add(id: id, kind: .note, name: NotebookWelcomeNote.name)
        try late.add(id: id, kind: .note, name: NotebookWelcomeNote.name)
        let undo = try XCTUnwrap(try left.moveItems([id], to: folder))
        try left.merge(late)
        XCTAssertThrowsError(try left.undoBrowserChange(undo)) {
            XCTAssertEqual($0 as? NotebookBrowserChangeError, .staleUndo)
        }
    }

    func testCombiningKeepsTrashFromAnyCopy() throws {
        let (left, right) = try devicesWithOwnCopies()
        try right.setTrashed(id, true)
        try left.merge(right)
        let combined = try NotebookCatalogDocument()
            .forkCombining(left, intoFolderNamed: "Other notebook")
        XCTAssertEqual(try item(in: combined).isTrashed, true)
        let joined = try NotebookCatalogDocument().forkJoiningOfflineNotebook(left)
        XCTAssertEqual(try item(in: joined).isTrashed, true)
    }

    // MARK: Helpers

    /// Two devices that each added the welcome note before syncing.
    private func devicesWithOwnCopies() throws
        -> (NotebookCatalogDocument, NotebookCatalogDocument) {
        let base = try NotebookCatalogDocument()
        let left = try base.fork()
        let right = try base.fork()
        for device in [left, right] {
            try device.add(id: id, kind: .note, name: NotebookWelcomeNote.name)
        }
        return (left, right)
    }

    private func item(in catalog: NotebookCatalogDocument) throws -> NotebookItem {
        try XCTUnwrap(try catalog.items().first { $0.id == id })
    }

    private func placement(in catalog: NotebookCatalogDocument) throws -> NotebookPlacement {
        try XCTUnwrap(try catalog.placements().first { $0.item.id == id })
    }

    private func assertMatchesFullRead(
        _ catalog: NotebookCatalogDocument, _ message: String
    ) throws {
        let fresh = try NotebookCatalogDocument(snapshot: catalog.snapshot())
        XCTAssertEqual(try catalog.items(), try fresh.items(), message)
        XCTAssertEqual(try catalog.placements(), try fresh.placements(), message)
    }

    /// v0.31.0 rejects copies of one item unless they share kind and name.
    /// Catalogs a newer build saves after ordinary edits must still pass.
    private func assertLoadsUnderStrictCopyRule(
        _ catalog: NotebookCatalogDocument,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let raw = try Document(catalog.snapshot().data)
        guard case .Object(let items, .Map) = try raw.get(obj: .ROOT, key: "items") else {
            return XCTFail("Expected items", file: file, line: line)
        }
        for key in raw.keys(obj: items) {
            let copies = try raw.getAll(obj: items, key: key)
            guard copies.count > 1 else { continue }
            let identities = try copies.map { value -> [String] in
                guard case .Object(let object, .Map) = value,
                      case .Scalar(.String(let kind)) = try raw.get(obj: object, key: "kind"),
                      case .Scalar(.String(let name)) = try raw.get(obj: object, key: "name")
                else { return [] }
                return [kind, name]
            }
            XCTAssertEqual(Set(identities).count, 1, key, file: file, line: line)
        }
    }
}
