import Automerge
import Foundation
import XCTest

@testable import NoteCore

/// After a change, a catalog reads only the items that changed. The result
/// must always match a full read of the same catalog.
final class NotebookCatalogItemUpdateTests: XCTestCase {
    func testUpdatedItemsMatchAFullReadAfterRandomEditsAndMerges() throws {
        for seed in 1...12 {
            var random = SeededRandom(seed: UInt64(seed))
            let base = try NotebookCatalogDocument()
            var copies = [base, try base.fork(), try base.fork()]
            for step in 0..<60 {
                let index = Int(random.next() % UInt64(copies.count))
                let catalog = copies[index]
                try edit(catalog, using: &random, step: step)
                if random.next() % 4 == 0 {
                    let other = copies[(index + 1) % copies.count]
                    try catalog.merge(other)
                }
                try assertMatchesFullRead(catalog, "seed \(seed) step \(step)")
                if random.next() % 10 == 0 { copies[index] = try catalog.fork() }
            }
        }
    }

    func testConcurrentCopiesOfOneItemStayInSync() throws {
        let base = try NotebookCatalogDocument()
        let left = try base.fork()
        let right = try base.fork()
        let id = UUID()
        _ = try left.add(id: id, kind: .note, name: "Same.md")
        _ = try right.add(id: id, kind: .note, name: "Same.md")
        _ = try left.items()
        try left.merge(right)
        try assertMatchesFullRead(left, "merged copies")
        // Changes to either copy must show up, even to the one that loses.
        try right.setTrashed(id, true)
        _ = try right.items()
        try left.merge(right)
        try assertMatchesFullRead(left, "trashed copy")
    }

    func testRenamingEitherCopyIsRejectedLikeAFullRead() throws {
        // Which copy wins depends on random actor IDs; repeat to see both.
        for attempt in 0..<40 {
            let renamed = attempt % 2
            let base = try NotebookCatalogDocument()
            let sides = [try base.fork(), try base.fork()]
            let id = UUID()
            for side in sides { _ = try side.add(id: id, kind: .note, name: "Same.md") }
            let receiving = sides[1 - renamed]
            try receiving.merge(sides[renamed])
            _ = try receiving.items()
            // Only this side's own copy exists here, so it is the one renamed.
            try sides[renamed].rename(id, to: "Renamed.md")

            XCTAssertThrowsError(try NotebookCatalogDocument(
                serializedData: merged(receiving, sides[renamed])))
            XCTAssertThrowsError(try receiving.merge(sides[renamed]), "attempt \(attempt)")
        }
    }

    func testLosingValueOfAConflictedFieldIsSeen() throws {
        // Which value wins depends on random actor IDs; repeat to see both.
        for attempt in 0..<40 {
            let base = try NotebookCatalogDocument()
            let id = try base.add(kind: .note, name: "Note.md")
            let branches = [try base.fork(), try base.fork(), try base.fork()]
            try branches[0].setTrashed(id, false)
            try branches[1].setTrashed(id, false)
            try branches[2].setTrashed(id, true)
            try branches[0].merge(branches[1])
            _ = try branches[0].items()
            try branches[0].merge(branches[2])
            try assertMatchesFullRead(branches[0], "attempt \(attempt)")
        }
    }

    func testLosingValueThatStartsAConflictIsSeen() throws {
        for attempt in 0..<40 {
            let base = try NotebookCatalogDocument()
            let id = try base.add(kind: .note, name: "Note.md")
            let left = try base.fork()
            let right = try base.fork()
            try left.setTrashed(id, false)
            try right.setTrashed(id, true)
            _ = try left.items()
            try left.merge(right)
            try assertMatchesFullRead(left, "attempt \(attempt)")
        }
    }

    /// The two catalogs merged without any check, read in full.
    private func merged(
        _ catalog: NotebookCatalogDocument, _ other: NotebookCatalogDocument
    ) throws -> Data {
        let raw = try Document(catalog.snapshot().data)
        try raw.merge(other: try Document(other.snapshot().data))
        return raw.save()
    }

    private func edit(
        _ catalog: NotebookCatalogDocument,
        using random: inout SeededRandom,
        step: Int
    ) throws {
        let items = try catalog.items().filter { !$0.isPermanentlyDeleted }
        let folders = try catalog.placements()
            .filter { $0.item.kind == .folder && !$0.isInTrash }.map(\.item)
        let pick = { (random: inout SeededRandom) -> NotebookItem? in
            items.isEmpty ? nil : items[Int(random.next() % UInt64(items.count))]
        }
        switch random.next() % 8 {
        case 0, 1:
            let parent = folders.isEmpty || random.next() % 2 == 0
                ? nil : folders[Int(random.next() % UInt64(folders.count))].id
            let kind: NotebookItemKind = random.next() % 3 == 0 ? .folder : .note
            _ = try catalog.add(
                kind: kind, name: "Item \(step)\(kind == .note ? ".md" : "")",
                parentID: parent)
        case 2:
            guard let item = pick(&random) else { return }
            try catalog.rename(
                item.id, to: "Renamed \(step)\(item.kind == .note ? ".md" : "")")
        case 3:
            guard let item = pick(&random) else { return }
            try? catalog.move(item.id, to: nil)
        case 4:
            guard let item = pick(&random), !item.isTrashed else { return }
            _ = try? catalog.trashItems([item.id])
        case 5:
            guard let item = pick(&random) else { return }
            try catalog.setTrashed(item.id, !item.isTrashed)
        case 6:
            guard let item = pick(&random), item.isTrashed else { return }
            try catalog.markPermanentlyDeleted([item.id])
        default:
            guard let item = pick(&random), item.kind == .note else { return }
            try catalog.recordRecentActivity(for: item.id)
        }
    }

    private func assertMatchesFullRead(
        _ catalog: NotebookCatalogDocument, _ message: String
    ) throws {
        let fresh = try NotebookCatalogDocument(snapshot: catalog.snapshot())
        XCTAssertEqual(try catalog.items(), try fresh.items(), message)
        XCTAssertEqual(try catalog.placements(), try fresh.placements(), message)
    }
}

/// Deterministic, so a failing seed can be replayed.
private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
