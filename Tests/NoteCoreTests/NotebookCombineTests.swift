import Foundation
import XCTest

@testable import NoteCore

final class NotebookCombineTests: XCTestCase {
    func testConcurrentCombinesOfTheSameNotebookKeepOneItemPerNote() throws {
        let stored = try NotebookCatalogDocument()
        _ = try stored.add(kind: .note, name: "Theirs")
        let local = try NotebookCatalogDocument()
        let note = try local.add(kind: .note, name: "Mine")

        // Two devices with the same local notebook combine before either
        // receives the other's result.
        let phone = try stored.forkCombining(local, omitting: [], intoFolderNamed: "From iCloud")
        let tablet = try stored.forkCombining(local, omitting: [], intoFolderNamed: "From iCloud")
        try phone.merge(tablet)
        try tablet.merge(phone)

        let placements = try phone.placements()
        XCTAssertEqual(placements.filter { $0.item.id == note }.count, 1)
        XCTAssertEqual(
            try tablet.placements().first { $0.item.id == note }?.item.parentID,
            placements.first { $0.item.id == note }?.item.parentID,
            "every device places the note in the same folder"
        )
        _ = try NotebookCatalogDocument(snapshot: phone.snapshot())
    }
}
