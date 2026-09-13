import Automerge
import Foundation
import XCTest

@testable import NoteCore

final class NotebookCatalogStorageTests: XCTestCase {
    private enum InjectedFailure: Error {
        case stop
    }

    private let notebookID = UUID(
        uuidString: "789AD90E-8C82-4021-98AC-524DD668A257"
    )!

    func testReplacementKeepsPreviousAndContinuousHistory() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NotebookCatalogStorage(directory: directory)
        let catalog = try NotebookCatalogDocument(notebookID: notebookID)
        let originalHeads = catalog.heads
        try await store.save(catalog.snapshot())

        let edited = try document(at: store.currentURL)
        _ = try edited.add(kind: .note, name: "New.md")
        try await store.save(edited.snapshot())

        let current = try document(at: store.currentURL)
        let previous = try document(at: store.previousURL)
        XCTAssertEqual(try current.items().map(\.name), ["New.md"])
        XCTAssertEqual(try previous.items(), [])
        XCTAssertEqual(previous.heads, originalHeads)
        XCTAssertTrue(originalHeads.isSubset(of: current.historyHeads))
    }

    func testInterruptedWritesAlwaysLeaveRecoverableCurrent() async throws {
        for stage in NotebookCatalogWriteStage.allCases {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = NotebookCatalogStorage(directory: directory)
            let catalog = try NotebookCatalogDocument(
                notebookID: notebookID
            )
            try await store.save(catalog.snapshot())
            let edited = try document(at: store.currentURL)
            _ = try edited.add(kind: .note, name: "New.md")

            do {
                try await store.write(edited.snapshot()) { reached in
                    if reached == stage { throw InjectedFailure.stop }
                }
                XCTFail("Expected the injected failure")
            } catch InjectedFailure.stop {
                // Expected interruption boundary.
            }

            let expectedCount =
                stage == .temporarySynced
                    || stage == .previousReplaced ? 0 : 1
            XCTAssertEqual(
                try document(at: store.currentURL).items().count,
                expectedCount
            )
        }
    }

    func testLoadDistinguishesFirstLaunchMissingAndCorruptCurrent()
        async throws
    {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NotebookCatalogStorage(directory: directory)
        let firstLoad = await store.load()
        XCTAssertEqual(firstLoad, .firstLaunch)

        let catalog = try NotebookCatalogDocument(notebookID: notebookID)
        try await store.save(catalog.snapshot())
        let edited = try document(at: store.currentURL)
        _ = try edited.add(kind: .folder, name: "Folder")
        try await store.save(edited.snapshot())
        try FileManager.default.removeItem(at: store.currentURL)

        guard case .recoveryRequired(let missing) = await store.load() else {
            return XCTFail("A missing current file must require recovery")
        }
        XCTAssertEqual(missing.currentFailure, .absent)

        try Data("damaged".utf8).write(to: store.currentURL)
        guard case .recoveryRequired(let damaged) = await store.load() else {
            return XCTFail("A damaged current file must offer recovery")
        }
        XCTAssertEqual(damaged.currentFailure, .corrupt)
    }

    func testRecoveryQuarantinesCurrentAndRetainsPrevious() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await storeWithPrevious(in: directory)
        let damaged = Data("damaged current bytes".utf8)
        try damaged.write(to: store.currentURL)

        guard case .recoveryRequired(let recovery) = await store.load() else {
            return XCTFail("Expected recovery")
        }
        let restored = try await store.recover(recovery)

        XCTAssertEqual(restored.notebookID, notebookID)
        XCTAssertEqual(try document(at: store.currentURL).items(), [])
        XCTAssertEqual(try document(at: store.previousURL).items(), [])
        let quarantines = try quarantineURLs(in: directory)
        XCTAssertEqual(quarantines.count, 1)
        XCTAssertEqual(try Data(contentsOf: quarantines[0]), damaged)
    }

    func testRecoveryRetriesIdempotentlyAfterEveryStage() async throws {
        for stage in NotebookCatalogRecoveryStage.allCases {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try await storeWithPrevious(in: directory)
            try Data("damaged".utf8).write(to: store.currentURL)
            guard case .recoveryRequired(let recovery) = await store.load()
            else {
                return XCTFail("Expected recovery")
            }

            do {
                _ = try await store.recover(recovery) { reached in
                    if reached == stage { throw InjectedFailure.stop }
                }
                XCTFail("Expected injected recovery failure")
            } catch InjectedFailure.stop {
                // Retry must finish or recognize the completed replacement.
            }

            let restored = try await store.recover(recovery)
            XCTAssertEqual(restored, recovery.previous)
            XCTAssertEqual(try document(at: store.currentURL).items(), [])
            XCTAssertEqual(try quarantineURLs(in: directory).count, 1)

            let retried = try await store.recover(recovery)
            XCTAssertEqual(retried, recovery.previous)
            XCTAssertEqual(try quarantineURLs(in: directory).count, 1)
        }
    }

    func testRecoveryRefusesChangedCurrentAndPreviousSources() async throws {
        do {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try await storeWithPrevious(in: directory)
            try Data("damaged".utf8).write(to: store.currentURL)
            guard case .recoveryRequired(let recovery) = await store.load()
            else {
                return XCTFail("Expected recovery")
            }
            try futureSchemaData().write(to: store.currentURL)

            await assertRecoverySourceChanged(store, recovery)
        }

        do {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try await storeWithPrevious(in: directory)
            try Data("damaged".utf8).write(to: store.currentURL)
            guard case .recoveryRequired(let recovery) = await store.load()
            else {
                return XCTFail("Expected recovery")
            }
            let foreign = try NotebookCatalogDocument()
            try foreign.snapshot().data.write(to: store.previousURL)

            await assertRecoverySourceChanged(store, recovery)
        }
    }

    func testUnsupportedCurrentBlocksPreviousRecovery() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await storeWithPrevious(in: directory)
        try futureSchemaData().write(to: store.currentURL)

        let result = await store.load()
        XCTAssertEqual(
            result,
            .blocked(
                NotebookCatalogLoadFailure(
                    current: .unsupportedSchemaVersion,
                    previous: .valid
                )
            )
        )
        XCTAssertEqual(try document(at: store.previousURL).items(), [])
    }

    func testSaveRejectsForgedStaleAndForeignSnapshots() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NotebookCatalogStorage(directory: directory)
        let catalog = try NotebookCatalogDocument(notebookID: notebookID)
        let stale = catalog.snapshot()
        try await store.save(stale)

        let edited = try document(at: store.currentURL)
        _ = try edited.add(kind: .note, name: "Current.md")
        try await store.save(edited.snapshot())

        await assertSaveError(store, stale, .disconnectedHistory)

        let foreign = try NotebookCatalogDocument().snapshot()
        await assertSaveError(store, foreign, .notebookIdentityMismatch)

        let forged = NotebookCatalogSnapshot(
            data: edited.snapshot().data,
            heads: ["forged-head"],
            notebookID: notebookID
        )
        await assertSaveError(store, forged, .invalidIncomingDocument)
    }

    private func storeWithPrevious(
        in directory: URL
    ) async throws -> NotebookCatalogStorage {
        let store = NotebookCatalogStorage(directory: directory)
        let catalog = try NotebookCatalogDocument(notebookID: notebookID)
        try await store.save(catalog.snapshot())
        let edited = try document(at: store.currentURL)
        _ = try edited.add(kind: .note, name: "Current.md")
        try await store.save(edited.snapshot())
        return store
    }

    private func assertRecoverySourceChanged(
        _ store: NotebookCatalogStorage,
        _ recovery: NotebookCatalogRecovery,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await store.recover(recovery)
            XCTFail("Expected changed recovery source", file: file, line: line)
        } catch let error as NotebookCatalogStorageError {
            XCTAssertEqual(
                error,
                .recoverySourceChanged,
                file: file,
                line: line
            )
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func assertSaveError(
        _ store: NotebookCatalogStorage,
        _ snapshot: NotebookCatalogSnapshot,
        _ expected: NotebookCatalogStorageError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await store.save(snapshot)
            XCTFail("Expected save rejection", file: file, line: line)
        } catch let error as NotebookCatalogStorageError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func futureSchemaData() throws -> Data {
        let document = Document(textEncoding: .unicodeScalar)
        try document.put(
            obj: .ROOT,
            key: "schemaVersion",
            value: .Uint(2)
        )
        return document.save()
    }

    private func document(at url: URL) throws -> NotebookCatalogDocument {
        try NotebookCatalogDocument(
            serializedData: Data(contentsOf: url)
        )
    }

    private func quarantineURLs(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("catalog.quarantine-")
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "NotebookCatalogStorageTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}
