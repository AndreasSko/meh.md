import Foundation
@testable import NoteCore
import XCTest

@testable import NotebookAppModel

@MainActor
final class NotebookFolderSearchTests: XCTestCase {
    private var root: URL!
    private var replica: NotebookReplica!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-search-\(UUID().uuidString)")
        replica = NotebookReplica(directory: root)
        try await replica.load()
        try await replica.createLocalNotebook()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testMatchesNameFirstThenPathInFilesOrder() async throws {
        let projects = try await replica.createFolder(name: "Projects")
        let lisbon = try await replica.createFolder(name: "Lisbon trip", parentID: projects)
        let photos = try await replica.createFolder(name: "Photos", parentID: lisbon)
        let trips = try await replica.createFolder(name: "Trips")
        _ = try await replica.createNote(name: "Lisbon notes.md")

        let matches = NotebookFolderSearch.matches(
            "lis", in: replica.placements, isAllowed: { _ in true })
        XCTAssertEqual(matches.map(\.id), [lisbon, photos])
        XCTAssertEqual(matches.first?.ancestors, ["Projects"])
        XCTAssertEqual(matches.last?.ancestors, ["Projects", "Lisbon trip"])

        // Every word must match, in the name or the path above it.
        XCTAssertEqual(
            NotebookFolderSearch.matches(
                "proj  PHO", in: replica.placements, isAllowed: { _ in true }
            ).map(\.id),
            [photos]
        )
        XCTAssertEqual(
            NotebookFolderSearch.matches(
                "trip", in: replica.placements, isAllowed: { _ in true }
            ).map(\.id),
            [lisbon, trips, photos]
        )
        XCTAssertTrue(NotebookFolderSearch.matches(
            " ", in: replica.placements, isAllowed: { _ in true }).isEmpty)
    }

    func testSkipsDisallowedAndTrashedFoldersButSearchesBelowThem() async throws {
        let source = try await replica.createFolder(name: "Source")
        let inside = try await replica.createFolder(name: "Inside", parentID: source)
        let trashed = try await replica.createFolder(name: "Old inside")
        try await replica.setTrashed(trashed, true)

        let matches = NotebookFolderSearch.matches(
            "inside", in: replica.placements, isAllowed: { $0 != source })
        XCTAssertEqual(matches.map(\.id), [inside])
        // The source itself never shows, though a folder below it does.
        XCTAssertEqual(
            NotebookFolderSearch.matches(
                "source", in: replica.placements, isAllowed: { $0 != source }
            ).map(\.id),
            [inside])
    }

    func testShortcutsKeepOrderAndDropUnavailableFolders() async throws {
        let projects = try await replica.createFolder(name: "Projects")
        let lisbon = try await replica.createFolder(name: "Lisbon trip", parentID: projects)
        let note = try await replica.createNote(name: "Note.md")

        let shortcuts = NotebookFolderSearch.shortcuts(
            for: [lisbon, note, UUID(), projects], in: replica.placements,
            isAllowed: { $0 != projects })
        XCTAssertEqual(shortcuts, [
            NotebookFolderShortcut(id: lisbon, name: "Lisbon trip", ancestors: ["Projects"])
        ])
    }
}
