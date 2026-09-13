import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class NotebookImportIntegrationTests: XCTestCase {
    func testRealServiceImportsAndPublishesExactSourceHierarchy() async throws {
        let endpoint = try loopbackEndpoint()
        let root = temporaryDirectory(named: "HTTPImport")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceParent = root.appending(path: "sources")
        let source = sourceParent.appending(path: "Imported Notes")
        try createDirectory(source.appending(path: "Empty"))
        try createDirectory(source.appending(path: "Projects/2026"))

        let unicode = Data("# Café 👋🏽\n\nGrüße aus Zürich\n".utf8)
        let crlf = Data("# Plan\r\n\r\n- first\r\n- second\r\n".utf8)
        let plain = Data("This format is intentionally unsupported.\r\n".utf8)
        try unicode.write(to: source.appending(path: "Café.md"))
        try crlf.write(to: source.appending(path: "Projects/2026/Plan.markdown"))
        try plain.write(to: source.appending(path: "Projects/ignored.txt"))
        let sourcesBefore = try treeSnapshot(at: sourceParent)

        let plan = try await NotebookImportScanner().scan(urls: [source])
        XCTAssertEqual(plan.skippedPaths, ["Imported Notes/Projects/ignored.txt"])

        let transport = LocalSyncTransport(
            baseURL: endpoint,
            workspace: "import-\(UUID().uuidString)",
            pageSize: 2,
            protocolVersion: 2
        )
        let left = NotebookReplica(directory: root.appending(path: "left"))
        try await left.createLocalNotebook()
        try await left.importMarkdown(plan)
        XCTAssertFalse(left.hasPendingImport)
        let leftSync = NotebookSyncCoordinator(replica: left, transport: transport)
        await leftSync.synchronize()
        try assertSuccess(leftSync)

        let right = NotebookReplica(directory: root.appending(path: "right"))
        let rightSync = NotebookSyncCoordinator(replica: right, transport: transport)
        await rightSync.synchronize()
        try assertSuccess(rightSync)

        XCTAssertEqual(left.placements, right.placements)
        try await assertImportedPlan(plan, in: right)

        let exportRoot = root.appending(path: "published")
        try await NotebookMarkdownPublisher(directory: exportRoot).publish(
            catalog: try XCTUnwrap(right.catalogSnapshot),
            placements: right.placements,
            notes: right.persistedNoteSnapshots()
        )
        try assertPublishedImport(plan, placements: right.placements, at: exportRoot)
        XCTAssertEqual(try treeSnapshot(at: sourceParent), sourcesBefore)
    }

    func testTwoHundredNoteImportAndPublishReportsElapsedTime() async throws {
        let root = temporaryDirectory(named: "ScaleImport")
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = root.appending(path: "sources")
        try createDirectory(sources)
        var selectedFolders: [URL] = []

        for folderIndex in 0..<10 {
            let folder = sources.appending(
                path: String(format: "Folder-%02d", folderIndex)
            )
            try createDirectory(folder)
            selectedFolders.append(folder)
            for noteIndex in 0..<20 {
                let name = String(format: "Note-%03d.md", noteIndex)
                let text = "folder \(folderIndex), note \(noteIndex) 👋\r\n"
                try Data(text.utf8).write(to: folder.appending(path: name))
            }
        }
        let duplicate = sources.appending(path: "Existing.md")
        try Data("imported duplicate\r\n".utf8).write(to: duplicate)
        let sourcesBefore = try treeSnapshot(at: sources)

        let replica = NotebookReplica(directory: root.appending(path: "replica"))
        try await replica.createLocalNotebook()
        let existingID = try await replica.createNote(
            name: "Existing.md",
            text: "existing content\n"
        )
        let started = ContinuousClock.now
        let plan = try await NotebookImportScanner().scan(
            urls: selectedFolders + [duplicate]
        )
        try await replica.importMarkdown(plan)
        let exportRoot = root.appending(path: "published")
        try await NotebookMarkdownPublisher(directory: exportRoot).publish(
            catalog: try XCTUnwrap(replica.catalogSnapshot),
            placements: replica.placements,
            notes: replica.persistedNoteSnapshots()
        )
        let elapsed = started.duration(to: .now)

        XCTAssertEqual(plan.entries.filter { $0.kind == .note }.count, 201)
        XCTAssertEqual(plan.entries.filter { $0.kind == .folder }.count, 10)
        XCTAssertEqual(replica.placements.count, plan.entries.count + 1)
        let existing = try await replica.openNote(existingID)
        XCTAssertEqual(existing.text, "existing content\n")
        try assertPublishedImport(plan, placements: replica.placements, at: exportRoot)
        XCTAssertEqual(
            try Data(
                contentsOf: try exportedURL(
                    for: existingID,
                    placements: replica.placements,
                    at: exportRoot
                )
            ),
            Data("existing content\n".utf8)
        )
        XCTAssertEqual(try treeSnapshot(at: sources), sourcesBefore)

        XCTContext.runActivity(
            named: "Imported and published 200 nested notes in \(elapsed)"
        ) { _ in }
        print("Notebook import scale: 200 notes in \(elapsed)")
    }

    private func loopbackEndpoint() throws -> URL {
        guard
            let value = ProcessInfo.processInfo.environment["MEH_NOTEBOOK_HTTP_URL"],
            let endpoint = URL(string: value),
            endpoint.host == "127.0.0.1" || endpoint.host == "::1"
        else {
            throw XCTSkip(
                "Set MEH_NOTEBOOK_HTTP_URL to a disposable loopback service"
            )
        }
        return endpoint
    }

    private func assertSuccess(
        _ coordinator: NotebookSyncCoordinator,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        if case .failed(let message) = coordinator.status {
            XCTFail(message, file: file, line: line)
            throw SyncError.unavailable(message)
        }
    }

    private func assertImportedPlan(
        _ plan: NotebookImportPlan,
        in replica: NotebookReplica,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for entry in plan.entries {
            let placement = try XCTUnwrap(
                replica.placements.first { $0.item.id == entry.id },
                file: file,
                line: line
            )
            XCTAssertEqual(placement.item.kind, entry.kind, file: file, line: line)
            XCTAssertEqual(placement.item.name, entry.name, file: file, line: line)
            XCTAssertEqual(placement.parentID, entry.parentID, file: file, line: line)
            if let text = entry.text {
                let session = try await replica.openNote(entry.id)
                XCTAssertEqual(
                    session.text,
                    text,
                    file: file,
                    line: line
                )
            }
        }
    }

    private func assertPublishedImport(
        _ plan: NotebookImportPlan,
        placements: [NotebookPlacement],
        at exportRoot: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for entry in plan.entries {
            let url = try exportedURL(
                for: entry.id,
                placements: placements,
                at: exportRoot
            )
            if entry.kind == .folder {
                var isDirectory: ObjCBool = false
                XCTAssertTrue(
                    FileManager.default.fileExists(
                        atPath: url.path,
                        isDirectory: &isDirectory
                    ),
                    file: file,
                    line: line
                )
                XCTAssertTrue(isDirectory.boolValue, file: file, line: line)
            } else {
                XCTAssertEqual(
                    try Data(contentsOf: url),
                    Data(try XCTUnwrap(entry.text).utf8),
                    file: file,
                    line: line
                )
            }
        }
    }

    private func exportedURL(
        for id: UUID,
        placements: [NotebookPlacement],
        at exportRoot: URL
    ) throws -> URL {
        let indexed = Dictionary(
            uniqueKeysWithValues: placements.map { ($0.item.id, $0) }
        )
        var names: [String] = []
        var currentID: UUID? = id
        while let itemID = currentID {
            let placement = try XCTUnwrap(indexed[itemID])
            var name = placement.displayName
            if placement.item.kind == .note,
                !name.lowercased().hasSuffix(".md"),
                !name.lowercased().hasSuffix(".markdown")
            {
                name += ".md"
            }
            names.append(name)
            currentID = placement.parentID
        }
        return names.reversed().reduce(
            exportRoot.appending(path: "Markdown")
        ) { $0.appending(path: $1) }
    }

    private func treeSnapshot(at root: URL) throws -> [String: Data] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return [:] }
        var files: [String: Data] = [:]
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                let relative = String(url.path.dropFirst(root.path.count + 1))
                files[relative] = try Data(contentsOf: url)
            }
        }
        return files
    }

    private func temporaryDirectory(named name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "NotebookImportIntegrationTests-\(name)-\(UUID().uuidString)"
        )
    }

    private func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }
}
