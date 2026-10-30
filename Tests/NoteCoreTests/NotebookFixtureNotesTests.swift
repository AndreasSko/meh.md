#if DEBUG
import Foundation
import XCTest
@testable import NoteCore

@MainActor
final class NotebookFixtureNotesTests: XCTestCase {
    func testBatchAppendsNotesLikeSingleCreation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let replica = NotebookReplica(directory: directory)
        try await replica.createLocalNotebook()
        let folder = try await replica.createFolder(name: "Field journals")
        let existing = try await replica.createNote(name: "Existing.md", parentID: folder)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let ids = try await replica.createNotes([
            .init(name: "B.md", history: [.init(date: date, text: "First")],
                  parentID: folder),
            .init(name: "A.md", history: [.init(date: date, text: "Root")]),
            .init(name: "C.md", history: [
                .init(date: date, text: "Draft"),
                .init(date: date.addingTimeInterval(1), text: "Draft revised"),
            ], parentID: folder),
        ])

        XCTAssertEqual(
            replica.orderedChildren(parentID: folder).map(\.item.id),
            [existing, ids[0], ids[2]]
        )
        XCTAssertEqual(
            replica.orderedChildren(parentID: nil).map(\.item.id), [folder, ids[1]]
        )
        let revised = try await replica.openNote(ids[2])
        XCTAssertEqual(revised.text, "Draft revised")
    }
}
#endif
