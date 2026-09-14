import Foundation
import XCTest

@testable import NoteCore

final class NotebookImportPlanTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
    }

    func testPreservesTreeEmptyFoldersAndExactUTF8Bytes() async throws {
        let root = temporaryDirectory.appendingPathComponent(
            "Notebook",
            isDirectory: true
        )
        let empty = root.appendingPathComponent("Empty", isDirectory: true)
        let nested = root.appendingPathComponent("Projects", isDirectory: true)
        try createDirectory(empty)
        try createDirectory(nested)

        let exactBytes = Data(
            [0xEF, 0xBB, 0xBF]
                + Array("# Café 👋\r\n\r\nExact bytes\r\n".utf8)
        )
        try exactBytes.write(to: nested.appendingPathComponent("Plan.MARKDOWN"))
        try Data("root\n".utf8).write(
            to: root.appendingPathComponent("Root.Md")
        )

        let plan = try await NotebookImportScanner().scan(urls: [root])

        XCTAssertEqual(
            plan.entries.map(\.name),
            ["Notebook", "Empty", "Projects", "Plan.MARKDOWN", "Root.Md"]
        )
        let rootEntry = try entry(named: "Notebook", in: plan)
        let emptyEntry = try entry(named: "Empty", in: plan)
        let projectsEntry = try entry(named: "Projects", in: plan)
        let planEntry = try entry(named: "Plan.MARKDOWN", in: plan)
        XCTAssertEqual(rootEntry.kind, .folder)
        XCTAssertNil(rootEntry.parentID)
        XCTAssertNil(rootEntry.text)
        XCTAssertEqual(emptyEntry.parentID, rootEntry.id)
        XCTAssertEqual(projectsEntry.parentID, rootEntry.id)
        XCTAssertEqual(planEntry.parentID, projectsEntry.id)
        XCTAssertEqual(planEntry.kind, .note)
        XCTAssertEqual(Data(try XCTUnwrap(planEntry.text).utf8), exactBytes)
        XCTAssertTrue(plan.skippedPaths.isEmpty)
    }

    func testSkipsHiddenNonMarkdownSymlinkAndPackageEntries() async throws {
        let root = temporaryDirectory.appendingPathComponent(
            "Import",
            isDirectory: true
        )
        try createDirectory(root)
        try Data("hidden".utf8).write(
            to: root.appendingPathComponent(".hidden.md")
        )
        try Data("plain".utf8).write(
            to: root.appendingPathComponent("plain.txt")
        )
        let target = root.appendingPathComponent("target.md")
        try Data("target".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Alias.md"),
            withDestinationURL: target
        )
        let package = root.appendingPathComponent("Bundle.app", isDirectory: true)
        try createDirectory(package)
        try Data("inside".utf8).write(
            to: package.appendingPathComponent("inside.md")
        )

        let plan = try await NotebookImportScanner().scan(urls: [root])

        XCTAssertEqual(plan.entries.map(\.name), ["Import", "target.md"])
        XCTAssertEqual(
            plan.skippedPaths,
            [
                "Import/.hidden.md",
                "Import/Alias.md",
                "Import/Bundle.app",
                "Import/plain.txt",
            ]
        )
    }

    func testMalformedUTF8FailsWholeScan() async throws {
        let invalid = temporaryDirectory.appendingPathComponent("invalid.md")
        try Data([0x66, 0x6F, 0x80]).write(to: invalid)

        do {
            _ = try await NotebookImportScanner().scan(urls: [invalid])
            XCTFail("Expected malformed UTF-8 to fail")
        } catch {
            XCTAssertEqual(
                error as? NotebookImportScannerError,
                .invalidUTF8(path: "invalid.md")
            )
        }
    }

    func testInvalidImportedNameFailsWholeScan() async throws {
        let root = temporaryDirectory.appendingPathComponent(
            "Import",
            isDirectory: true
        )
        try createDirectory(root)
        let invalid = root.appendingPathComponent("bad\nname.md")
        try Data("text".utf8).write(to: invalid)

        do {
            _ = try await NotebookImportScanner().scan(urls: [root])
            XCTFail("Expected an invalid name to fail")
        } catch {
            XCTAssertEqual(
                error as? NotebookImportScannerError,
                .invalidName(path: "Import/bad\nname.md")
            )
        }
    }

    func testScanDoesNotModifySourceFiles() async throws {
        let note = temporaryDirectory.appendingPathComponent("source.md")
        let bytes = Data("unchanged\r\n".utf8)
        try bytes.write(to: note)
        let attributesBefore = try FileManager.default.attributesOfItem(
            atPath: note.path
        )

        _ = try await NotebookImportScanner().scan(urls: [note])

        XCTAssertEqual(try Data(contentsOf: note), bytes)
        let attributesAfter = try FileManager.default.attributesOfItem(
            atPath: note.path
        )
        XCTAssertEqual(
            attributesAfter[.modificationDate] as? Date,
            attributesBefore[.modificationDate] as? Date
        )
        XCTAssertEqual(
            attributesAfter[.size] as? NSNumber,
            attributesBefore[.size] as? NSNumber
        )
    }

    func testOverlappingSelectionsAreImportedOnlyOnce() async throws {
        let root = temporaryDirectory.appendingPathComponent(
            "Root",
            isDirectory: true
        )
        let nested = root.appendingPathComponent("Nested", isDirectory: true)
        try createDirectory(nested)
        let note = nested.appendingPathComponent("note.md")
        try Data("once".utf8).write(to: note)

        let plan = try await NotebookImportScanner().scan(
            urls: [note, nested, root, root]
        )

        XCTAssertEqual(plan.entries.map(\.name), ["Root", "Nested", "note.md"])
        XCTAssertEqual(plan.entries.filter { $0.name == "note.md" }.count, 1)
    }

    func testSelectedMarkdownFilesArePlacedAtRootDeterministically() async throws {
        let beta = temporaryDirectory.appendingPathComponent("beta.MD")
        let alpha = temporaryDirectory.appendingPathComponent("alpha.markdown")
        try Data("beta".utf8).write(to: beta)
        try Data("alpha".utf8).write(to: alpha)

        let plan = try await NotebookImportScanner().scan(urls: [beta, alpha])

        XCTAssertEqual(plan.entries.map(\.name), ["alpha.markdown", "beta.MD"])
        XCTAssertTrue(plan.entries.allSatisfy { $0.parentID == nil })
    }

    func testCapturesSourceFileAndFolderDates() async throws {
        let folder = temporaryDirectory.appendingPathComponent(
            "Dated",
            isDirectory: true
        )
        try createDirectory(folder)
        let note = folder.appendingPathComponent("note.md")
        try Data("exact".utf8).write(to: note)
        let requestedFolderDate = Date(timeIntervalSince1970: 1_600_000_000)
        let requestedNoteDate = Date(timeIntervalSince1970: 1_700_000_000.123)
        try FileManager.default.setAttributes(
            [.modificationDate: requestedNoteDate],
            ofItemAtPath: note.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: requestedFolderDate],
            ofItemAtPath: folder.path
        )
        let actualNote = try note.resourceValues(
            forKeys: [.creationDateKey, .contentModificationDateKey]
        )
        let actualFolder = try folder.resourceValues(
            forKeys: [.creationDateKey, .contentModificationDateKey]
        )

        let plan = try await NotebookImportScanner().scan(urls: [folder])

        let folderEntry = try entry(named: "Dated", in: plan)
        let noteEntry = try entry(named: "note.md", in: plan)
        XCTAssertEqual(
            folderEntry.createdAt,
            actualFolder.creationDate?.noteTimestamp
        )
        XCTAssertEqual(
            folderEntry.modifiedAt,
            actualFolder.contentModificationDate?.noteTimestamp
        )
        XCTAssertEqual(
            noteEntry.createdAt,
            actualNote.creationDate?.noteTimestamp
        )
        XCTAssertEqual(
            noteEntry.modifiedAt,
            actualNote.contentModificationDate?.noteTimestamp
        )
    }

    func testOlderPlanWithoutDateFieldsDecodesAsUnknown() throws {
        let id = UUID()
        let json = Data(
            """
            {"id":"\(UUID().uuidString)","entries":[{"id":"\(id.uuidString)",
            "kind":"note","name":"old.md","text":"body"}],"skippedPaths":[]}
            """.utf8
        )

        let plan = try JSONDecoder().decode(NotebookImportPlan.self, from: json)

        XCTAssertNil(plan.entries[0].createdAt)
        XCTAssertNil(plan.entries[0].modifiedAt)
    }

    private func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }

    private func entry(
        named name: String,
        in plan: NotebookImportPlan
    ) throws -> NotebookImportEntry {
        try XCTUnwrap(plan.entries.first { $0.name == name })
    }
}
