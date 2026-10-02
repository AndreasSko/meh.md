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

    func testCollisionWinnerMatchesCurrentMarkdownCopyOrder() throws {
        let catalog = try NotebookCatalogDocument()
        let smaller = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let larger = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let first = try NoteDocument(noteID: smaller, text: "Smaller")
        let second = try NoteDocument(noteID: larger, text: "Larger")
        try catalog.add(id: smaller, kind: .note, name: "Draft.md")
        try catalog.add(id: larger, kind: .note, name: "Draft")
        let wrapper = try NotebookMarkdownExport.makeWrapper(
            placements: catalog.placements().reversed(),
            notes: [first.snapshot(), second.snapshot()],
            selectedIDs: [smaller, larger]
        )
        let files = try XCTUnwrap(wrapper.fileWrappers)
        XCTAssertEqual(files["Draft.md"]?.regularFileContents, Data("Smaller".utf8))
        XCTAssertEqual(files.count, 2)
    }

    func testImportedRootExportKeepsNestedLinkSyntax() async throws {
        let root = UUID(), nested = UUID()
        let source = try NoteDocument(text: "[[Ideas/Travel Plan#Packing|my label]]\n"
            + "[packing](./Ideas/Travel%20Plan.md#Packing)\n"
            + "[website](https://example.com)\n")
        let target = try NoteDocument(text: "# Packing\nFictional trip")
        let catalog = try NotebookCatalogDocument().forkAddingImportEntries([
            .init(id: root, kind: .folder, name: "Vault", parentID: nil, text: nil),
            .init(id: nested, kind: .folder, name: "Ideas", parentID: root, text: nil),
            .init(id: source.noteID, kind: .note, name: "Start.md", parentID: root,
                  text: try source.text),
            .init(id: target.noteID, kind: .note, name: "Travel Plan.md", parentID: nested,
                  text: try target.text),
        ])
        try catalog.rename(root, to: "Renamed vault")
        let archive = try catalog.add(kind: .folder, name: "Archive")
        try catalog.move(root, to: archive)
        let wrapper = try NotebookMarkdownExport.makeWrapper(
            placements: catalog.placements(), notes: [source.snapshot(), target.snapshot()],
            selectedIDs: [root])
        XCTAssertEqual(Set(try XCTUnwrap(wrapper.fileWrappers).keys),
                       ["Start.md", "Ideas"])
        XCTAssertEqual(wrapper.fileWrappers?["Start.md"]?.regularFileContents,
                       Data(try source.text.utf8))
        try await assertRoundTrip(wrapper, sourceName: "Start.md",
                                  targetSuffix: "Ideas/Travel Plan.md", linkCount: 2)
    }

    func testCombinedImportedRootsDisambiguateDuplicateNotes() async throws {
        let firstRoot = UUID(), secondRoot = UUID(), nested = UUID()
        let source = try NoteDocument(text: "[[Travel Plan#Heading|label]]\n[relative](./Travel%20Plan.md#Heading)\n[root](</Nested/Travel%20Plan.md#Heading>)")
        let firstTarget = try NoteDocument(text: "# Heading\nFirst imaginary topic")
        let secondTarget = try NoteDocument(text: "# Heading\nSecond imaginary topic")
        let catalog = try NotebookCatalogDocument().forkAddingImportEntries([
            .init(id: firstRoot, kind: .folder, name: "First", parentID: nil, text: nil),
            .init(id: secondRoot, kind: .folder, name: "Second", parentID: nil, text: nil),
            .init(id: nested, kind: .folder, name: "Nested", parentID: firstRoot, text: nil),
            .init(id: source.noteID, kind: .note, name: "Start.md", parentID: nested,
                  text: try source.text),
            .init(id: firstTarget.noteID, kind: .note, name: "Travel Plan.md", parentID: nested,
                  text: try firstTarget.text),
            .init(id: secondTarget.noteID, kind: .note, name: "Travel Plan.md", parentID: secondRoot,
                  text: try secondTarget.text),
        ])
        try catalog.rename(firstRoot, to: "Renamed first")
        let original = try source.text
        let wrapper = try NotebookMarkdownExport.makeWrapper(
            placements: catalog.placements(),
            notes: [source.snapshot(), firstTarget.snapshot(), secondTarget.snapshot()],
            selectedIDs: [firstRoot, secondRoot])
        let contents = try XCTUnwrap(wrapper.fileWrappers?["Renamed first"]?
            .fileWrappers?["Nested"]?.fileWrappers?["Start.md"]?.regularFileContents)
        XCTAssertEqual(String(decoding: contents, as: UTF8.self),
            "[[Renamed first/Nested/Travel Plan#Heading|label]]\n[relative](./Travel%20Plan.md#Heading)\n[root](<./Travel%20Plan.md#Heading>)")
        XCTAssertEqual(try source.text, original)
        let literalBackup = try NotebookMarkdownExport.makeWrapper(
            placements: catalog.placements(),
            notes: [source.snapshot(), firstTarget.snapshot(), secondTarget.snapshot()],
            selectedIDs: [firstRoot, secondRoot], preserveSource: true)
        XCTAssertEqual(literalBackup.fileWrappers?["Renamed first"]?.fileWrappers?["Nested"]?
            .fileWrappers?["Start.md"]?.regularFileContents, Data(original.utf8))
        try await assertRoundTrip(wrapper, sourceName: "Start.md",
            targetSuffix: "Renamed first/Nested/Travel Plan.md", linkCount: 3)
    }

    func testExportCollisionPreservesAmbiguousDestination() async throws {
        let catalog = try NotebookCatalogDocument()
        let smaller = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let larger = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let first = try NoteDocument(noteID: smaller, text: "Markdown extension first")
        let target = try NoteDocument(noteID: larger, text: "# Heading\nOther imaginary note")
        let source = try NoteDocument(text: "[label](./Travel%20Plan#Heading)")
        try catalog.add(id: smaller, kind: .note, name: "Travel Plan.md")
        // These names collapse when the exporter appends .md. The original
        // link is deliberately ambiguous, so export must never guess a target.
        try catalog.add(id: larger, kind: .note, name: "Travel Plan")
        try catalog.add(id: source.noteID, kind: .note, name: "Start")
        let wrapper = try NotebookMarkdownExport.makeWrapper(
            placements: catalog.placements(), notes: [first.snapshot(), target.snapshot(), source.snapshot()],
            selectedIDs: [smaller, larger, source.noteID])
        XCTAssertEqual(wrapper.fileWrappers?["Start.md"]?.regularFileContents,
                       Data(try source.text.utf8))
        XCTAssertEqual(wrapper.fileWrappers?.count, 3)
    }

    func testFilenameCollisionRepairsEncodedDestination() async throws {
        let catalog = try NotebookCatalogDocument()
        let folderID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let targetID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let target = try NoteDocument(noteID: targetID, text: "# Heading")
        let source = try NoteDocument(text: "[label](./Travel%20Plan#Heading)")
        try catalog.add(id: folderID, kind: .folder, name: "Travel Plan.md")
        try catalog.add(id: targetID, kind: .note, name: "Travel Plan")
        try catalog.add(id: source.noteID, kind: .note, name: "Start.md")
        let wrapper = try NotebookMarkdownExport.makeWrapper(
            placements: catalog.placements(), notes: [target.snapshot(), source.snapshot()],
            selectedIDs: [folderID, targetID, source.noteID])
        let contents = try XCTUnwrap(wrapper.fileWrappers?["Start.md"]?.regularFileContents)
        XCTAssertEqual(String(decoding: contents, as: UTF8.self),
            "[label](./Travel%20Plan%20%2800000000%29#Heading)")
        try await assertRoundTrip(wrapper, sourceName: "Start.md",
            targetSuffix: "Travel Plan (00000000).md", linkCount: 1)
    }

    func testExportTranslatesHistoricallyResolvedLink() async throws {
        let catalog = try NotebookCatalogDocument()
        let source = try NoteDocument(text: "[label](./Old.md#Heading)")
        let target = try NoteDocument(text: "# Heading")
        try catalog.add(id: source.noteID, kind: .note, name: "Start.md")
        try catalog.add(id: target.noteID, kind: .note, name: "Renamed.md")
        let descriptors = [
            NotebookLinkNote(id: source.noteID, name: "Start.md", path: ""),
            NotebookLinkNote(id: target.noteID, name: "Renamed.md", path: "",
                formerLocations: [.init(name: "Old.md", path: "")]),
        ]
        let wrapper = try NotebookMarkdownExport.makeWrapper(
            placements: catalog.placements(), notes: [source.snapshot(), target.snapshot()],
            selectedIDs: [source.noteID, target.noteID], originalLinkNotes: descriptors)
        XCTAssertEqual(wrapper.fileWrappers?["Start.md"]?.regularFileContents,
                       Data("[label](./Renamed.md#Heading)".utf8))
        XCTAssertEqual(try source.text, "[label](./Old.md#Heading)")
        try await assertRoundTrip(wrapper, sourceName: "Start.md",
                                  targetSuffix: "Renamed.md", linkCount: 1)
    }

    private func assertRoundTrip(
        _ wrapper: FileWrapper, sourceName: String, targetSuffix: String, linkCount: Int
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-roundtrip-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try wrapper.write(to: directory, options: .atomic, originalContentsURL: nil)
        let plan = try await NotebookImportScanner().scan(urls: [directory])
        let catalog = try NotebookCatalogDocument().forkAddingImportEntries(plan.entries)
        let placements = try catalog.placements()
        let byID = Dictionary(uniqueKeysWithValues: placements.map { ($0.item.id, $0) })
        func path(_ id: UUID?) -> String {
            guard let id, let placement = byID[id] else { return "" }
            let parent = path(placement.parentID)
            return parent.isEmpty ? placement.displayName : parent + "/" + placement.displayName
        }
        let notes = placements.filter { $0.item.kind == .note }.map { placement in
            NotebookLinkNote(id: placement.item.id, name: placement.displayName,
                path: path(placement.parentID), rootID: placement.item.importRootID,
                rootPath: placement.item.importRootID.map { path($0) })
        }
        let source = try XCTUnwrap(plan.entries.first { $0.name == sourceName })
        let target = try XCTUnwrap(notes.first { $0.fullPath.hasSuffix("/" + targetSuffix) })
        let occurrences = NotebookLinkParser.parse(try XCTUnwrap(source.text)).filter {
            if case .external = NotebookLinkResolver.resolve($0, sourceID: source.id, notes: notes) {
                return false
            }
            return true
        }
        XCTAssertEqual(occurrences.count, linkCount)
        for occurrence in occurrences {
            guard case .resolved(let targetID, _) = NotebookLinkResolver.resolve(
                occurrence, sourceID: source.id, notes: notes) else {
                return XCTFail("Exported link did not resolve: \(occurrence.destination)")
            }
            XCTAssertEqual(targetID, target.id)
        }
    }

    func testMixedFolderExportsOnlyMarkdown() throws {
        let catalog = try NotebookCatalogDocument()
        let folder = try catalog.add(kind: .folder, name: "Project")
        let note = try NoteDocument(text: "# Notes\n")
        try catalog.add(id: note.noteID, kind: .note, name: "Notes.md",
                        parentID: folder)
        try catalog.add(kind: .attachment, name: "Diagram.pdf", parentID: folder,
                        attachment: NotebookAttachmentContent(
                            sha256: String(repeating: "a", count: 64),
                            byteCount: 200_000_000))
        let exported = try NotebookMarkdownExport.makeWrapper(
            placements: catalog.placements(), notes: [note.snapshot()],
            selectedIDs: [folder])
        let files = try XCTUnwrap(exported.fileWrappers?["Project"]?.fileWrappers)
        XCTAssertEqual(Set(files.keys), ["Notes.md"])
        XCTAssertEqual(files["Notes.md"]?.regularFileContents,
                       Data("# Notes\n".utf8))
    }
}
