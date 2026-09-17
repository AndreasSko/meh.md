import Foundation
import XCTest
@testable import NoteCore

final class NotebookMarkdownExportTests: XCTestCase {
    func testSelectionPreservesAncestorsAndFolderContents() throws {
        let catalog = try NotebookCatalogDocument()
        let folder = try catalog.add(kind: .folder, name: "Projects")
        let first = try NoteDocument(text: "# Exact 👋\n")
        let second = try NoteDocument(text: "Second")
        try catalog.add(id: first.noteID, kind: .note, name: "Draft", parentID: folder)
        try catalog.add(id: second.noteID, kind: .note, name: "Other", parentID: folder)
        let snapshots = [first.snapshot(), second.snapshot()]
        let selected = try NotebookMarkdownExport.makeWrapper(
            placements: catalog.placements(), notes: snapshots,
            selectedIDs: [first.noteID]
        )
        let files = try XCTUnwrap(selected.fileWrappers?["Projects"]?.fileWrappers)
        XCTAssertEqual(Set(files.keys), ["Draft.md"])
        XCTAssertEqual(files["Draft.md"]?.regularFileContents, Data("# Exact 👋\n".utf8))
        let all = try NotebookMarkdownExport.makeWrapper(
            placements: catalog.placements(), notes: snapshots, selectedIDs: [folder]
        )
        XCTAssertEqual(all.fileWrappers?["Projects"]?.fileWrappers?.count, 2)
        XCTAssertThrowsError(try NotebookMarkdownExport.makeWrapper(
            placements: catalog.placements(), notes: [], selectedIDs: [folder]
        ))
    }
}
