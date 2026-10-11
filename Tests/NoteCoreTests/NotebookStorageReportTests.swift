import Foundation
import XCTest
@testable import NoteCore

@MainActor
final class NotebookStorageReportTests: XCTestCase {
    func testQuarantinesCountAsRecoveryOnlyForManagedDocuments() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = UUID(), second = UUID(), orphan = UUID()
        let retained = UUID(), anotherRetained = UUID()
        try write(root, "notebook/notes/\(first)/note.automerge", bytes: 10)
        try write(root, "notebook/notes/\(first)/note.previous.automerge", bytes: 7)
        try write(root, "notebook/notes/\(second)/note.automerge", bytes: 20)
        try write(root,
                  "notebook/notes/\(first)/note.quarantine-\(retained).automerge", bytes: 31)
        try write(root,
                  "notebook/notes/\(first)/note.quarantine-\(anotherRetained).automerge",
                  bytes: 17)
        try write(root, "notebook/catalog.quarantine-\(retained).automerge", bytes: 23)
        try write(root, "notebook/notes/\(first)/note.quarantine-invalid.automerge",
                  bytes: 11)
        try write(root,
                  "notebook/notes/\(orphan)/note.quarantine-\(retained).automerge", bytes: 13)
        try write(root, "notebook/nested/catalog.quarantine-\(retained).automerge",
                  bytes: 19)
        try write(root, "notebook/catalog.quarantine-\(retained)-extra.automerge",
                  bytes: 29)
        let descriptors: [NotebookStorageDocument] = [
            .init(id: first, name: "First", path: "First.md", isInTrash: false),
            .init(id: second, name: "Second", path: "Second.md", isInTrash: false)
        ]
        let report = try await scan(root, documents: descriptors)
        let unnamedReport = try await scan(root, documents: [])
        XCTAssertEqual(report.totalBytes, 180)
        XCTAssertEqual(report.totalBytes, unnamedReport.totalBytes)
        XCTAssertEqual(report.categories.map(\.byteCount), [30, 78, 0, 0, 72])
        XCTAssertEqual(report.documents.map(\.id), [first, second])
        XCTAssertEqual(report.documents.map(\.totalBytes), [65, 20])
        XCTAssertEqual(report.documents.first?.currentAndHistoryBytes, 10)
        XCTAssertEqual(report.documents.first?.recoveryBytes, 55)
        // Shared catalog recovery bytes never inflate an individual note.
        XCTAssertEqual(report.documents.reduce(0) { $0 + $1.recoveryBytes }, 55)
    }

    func testCategoriesIncludeTrashRecoveryOrphansAndHiddenFiles() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let active = UUID(), trashed = UUID(), orphan = UUID()
        try write(root, "notebook/notes/\(active)/note.automerge", bytes: 11)
        try write(root, "notebook/notes/\(active)/note.previous.automerge", bytes: 7)
        try write(root, "notebook/notes/\(trashed)/note.automerge", bytes: 13)
        try write(root, "notebook/notes/\(orphan)/note.automerge", bytes: 17)
        try write(root, "notebook/catalog.automerge", bytes: 19)
        try write(root, "notebook/catalog.previous.automerge", bytes: 37)
        try write(root, "notebook/.interrupted", bytes: 23)
        try write(root, "copies/Markdown/Note.md", bytes: 29)
        try write(root, "backups/.stage/Note.md", bytes: 31)
        let report = try await scan(root, documents: [
            .init(id: active, name: "Active", path: "Active.md", isInTrash: false),
            .init(id: trashed, name: "Trash", path: "Trash.md", isInTrash: true)
        ])
        XCTAssertEqual(report.totalBytes, 187)
        let totals = Dictionary(uniqueKeysWithValues:
            report.categories.map { ($0.category, $0.byteCount) })
        XCTAssertEqual(totals[.notesAndHistory], 24)
        XCTAssertEqual(totals[.recoveryCopies], 44)
        XCTAssertEqual(totals[.markdownCopies], 29)
        XCTAssertEqual(totals[.backups], 31)
        XCTAssertEqual(totals[.other], 59)
        XCTAssertEqual(report.activeNoteCount, 1)
        XCTAssertEqual(report.trashNoteCount, 1)
        XCTAssertEqual(report.documents.first?.id, active)
        XCTAssertEqual(report.documents.first?.totalBytes, 18)
    }

    func testSymlinksAreSkippedIncludingRootAndAncestors() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "outside/secret", bytes: 100)
        try write(root, "outside/nested/secret", bytes: 100)
        try write(root, "notebook/.owned", bytes: 3)
        let manager = FileManager.default
        try manager.createSymbolicLink(
            at: root.appending(path: "notebook/.linked"),
            withDestinationURL: root.appending(path: "outside")
        )
        try manager.createSymbolicLink(
            at: root.appending(path: "copies"),
            withDestinationURL: root.appending(path: "outside")
        )
        try manager.createSymbolicLink(
            at: root.appending(path: "alias"),
            withDestinationURL: root.appending(path: "outside")
        )
        let report = try await NotebookStorageReport.scan(
            trustedBoundary: root,
            notebookDirectory: root.appending(path: "notebook"),
            markdownCopiesDirectory: root.appending(path: "copies"),
            backupDirectory: root.appending(path: "alias/nested"), documents: []
        )
        XCTAssertEqual(report.totalBytes, 3)
    }

    func testOverlappingRootsUseSpecificCategoryWithoutDoubleCounting() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "notebook/copies/Markdown/Note.md", bytes: 5)
        try write(root, "notebook/backups/Note.md", bytes: 7)
        try write(root, "notebook/other", bytes: 11)
        let report = try await NotebookStorageReport.scan(
            trustedBoundary: root,
            notebookDirectory: root.appending(path: "notebook"),
            markdownCopiesDirectory: root.appending(path: "notebook/copies"),
            backupDirectory: root.appending(path: "notebook/backups"), documents: []
        )
        XCTAssertEqual(report.totalBytes, 23)
        XCTAssertEqual(report.categories.map(\.byteCount), [0, 0, 5, 7, 11])
    }

    func testEqualSizesSortByPathThenIdentityAndKeepZeroSizeNotes() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let third = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        try write(root, "notebook/notes/\(first)/note.automerge", bytes: 0)
        let report = try await scan(root, documents: [
            .init(id: third, name: "Z", path: "Z.md", isInTrash: false),
            .init(id: second, name: "A", path: "A.md", isInTrash: false),
            .init(id: first, name: "A", path: "A.md", isInTrash: false)
        ])
        XCTAssertEqual(report.documents.map(\.id), [first, second, third])
        XCTAssertEqual(report.totalBytes, 0)
        XCTAssertEqual(report.activeNoteCount, 3)
    }

    func testMissingDirectoriesReturnCompleteEmptyReport() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let report = try await scan(root, documents: [])
        XCTAssertEqual(report.totalBytes, 0)
        XCTAssertEqual(report.categories.count, 5)
        XCTAssertTrue(report.documents.isEmpty)
    }

    func testAlreadyCancelledScanThrowsCancellation() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await scan(root, documents: [])
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled measurement must not publish a report")
        } catch is CancellationError { }
    }

    func testDuplicateDocumentIdentityIsRejected() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let document = NotebookStorageDocument(
            id: UUID(), name: "Note", path: "Note.md", isInTrash: false
        )
        do {
            _ = try await scan(root, documents: [document, document])
            XCTFail("Duplicate identities must not inflate counts")
        } catch NotebookStorageReportError.duplicateDocumentID(let id) {
            XCTAssertEqual(id, document.id)
        }
    }

    func testKnownSystemAliasRootIsMeasured() async throws {
        let root = URL(fileURLWithPath: "/tmp")
            .appending(path: "NotebookStorageAlias-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "notebook/owned", bytes: 9)
        let report = try await scan(root, documents: [])
        XCTAssertEqual(report.totalBytes, 9)
    }

    func testIdenticalRootsHaveDeterministicCategoryAndNoDuplicates() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "owned", bytes: 9)
        let report = try await NotebookStorageReport.scan(
            trustedBoundary: root,
            notebookDirectory: root, markdownCopiesDirectory: root,
            backupDirectory: root, documents: []
        )
        XCTAssertEqual(report.totalBytes, 9)
        XCTAssertEqual(report.categories.map(\.byteCount), [0, 0, 0, 9, 0])
    }

    func testRootOutsideTrustedBoundaryIsRejected() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "owned/file", bytes: 7)
        do {
            _ = try await NotebookStorageReport.scan(
                trustedBoundary: root.appending(path: "owned"),
                notebookDirectory: root,
                markdownCopiesDirectory: root.appending(path: "owned/copies"),
                backupDirectory: root.appending(path: "owned/backups"), documents: []
            )
            XCTFail("Requests must stay within the trusted boundary")
        } catch NotebookStorageReportError.rootOutsideTrustedBoundary(let url) {
            XCTAssertEqual(url.standardizedFileURL.path, root.standardizedFileURL.path)
        }
    }

    private func temporaryRoot() -> URL {
        // Resolve the system temporary directory's /var alias before scanning.
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "NotebookStorageReport-\(UUID())")
    }

    private func write(_ root: URL, _ path: String, bytes: Int) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: 42, count: bytes).write(to: url)
    }

    private func scan(
        _ root: URL, documents: [NotebookStorageDocument]
    ) async throws -> NotebookStorageReport {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try await NotebookStorageReport.scan(
            trustedBoundary: root,
            notebookDirectory: root.appending(path: "notebook"),
            markdownCopiesDirectory: root.appending(path: "copies"),
            backupDirectory: root.appending(path: "backups"), documents: documents
        )
    }
}
