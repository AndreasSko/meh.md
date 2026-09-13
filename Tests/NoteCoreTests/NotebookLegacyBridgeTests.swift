import Foundation
@testable import NoteCore
import XCTest

@MainActor
final class NotebookLegacyBridgeTests: XCTestCase {
    override func tearDown() {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories = []
        super.tearDown()
    }

    nonisolated(unsafe) private var temporaryDirectories: [URL] = []
    private let cloudRoot = "iCloud.test/private/account"

    func testFreshBridgeJoinsExistingV1Canonical() async throws {
        let store = InMemorySyncStore()
        let legacy = transport(store: store)
        let canonical = try NoteDocument(text: "remote")
        _ = try await legacy.bootstrap(
            proposing: SyncRecord(snapshot: canonical.snapshot())
        )
        let root = temporaryDirectory()
        let bridge = NotebookLegacyBridge(
            directory: root.appending(path: "Notebook/LegacyBridge"),
            legacyDirectory: root.appending(path: "Notes")
        )

        let result = try await bridge.synchronize(
            legacyTransport: legacy,
            notebookScope: notebookScope
        )

        XCTAssertEqual(result.noteID, canonical.noteID)
        XCTAssertEqual(try NoteDocument(snapshot: result).text, "remote")
    }

    func testReceiptSurvivesFailedJoinAndLostOriginal() async throws {
        let store = InMemorySyncStore()
        let legacy = transport(store: store)
        let root = temporaryDirectory()
        let oldDirectory = root.appending(path: "Notes")
        let source = try NoteDocument(text: "local source")
        try await NoteFileStorage(directory: oldDirectory).save(source.snapshot())
        let bridge = NotebookLegacyBridge(
            directory: root.appending(path: "Notebook/LegacyBridge"),
            legacyDirectory: oldDirectory
        )
        await store.setOffline(true)

        do {
            _ = try await bridge.synchronize(
                legacyTransport: legacy,
                notebookScope: notebookScope
            )
            XCTFail("Expected the offline exchange to fail")
        } catch NotebookLegacyBridgeError.exchangeFailed(_) {}
        try FileManager.default.removeItem(at: oldDirectory)
        await store.setOffline(false)

        let result = try await bridge.synchronize(
            legacyTransport: legacy,
            notebookScope: notebookScope
        )
        XCTAssertEqual(result.noteID, source.noteID)
        XCTAssertEqual(try NoteDocument(snapshot: result).text, "local source")
    }

    func testRepeatedBridgeImportsLateV1Branch() async throws {
        let store = InMemorySyncStore()
        let legacy = transport(store: store)
        let root = temporaryDirectory()
        let oldDirectory = root.appending(path: "Notes")
        let base = try NoteDocument(text: "base")
        try await NoteFileStorage(directory: oldDirectory).save(base.snapshot())
        let bridge = NotebookLegacyBridge(
            directory: root.appending(path: "Notebook/LegacyBridge"),
            legacyDirectory: oldDirectory
        )
        let first = try await bridge.synchronize(
            legacyTransport: legacy,
            notebookScope: notebookScope
        )
        let late = try NoteDocument(snapshot: base.snapshot())
        try late.replaceAll(with: "late old-client edit")
        try await legacy.publish(SyncRecord(snapshot: late.snapshot()))

        let second = try await bridge.synchronize(
            legacyTransport: legacy,
            notebookScope: notebookScope
        )
        let merged = try NoteDocument(snapshot: second)

        XCTAssertTrue(first.heads.isSubset(of: merged.historyHeads))
        XCTAssertTrue(late.heads.isSubset(of: merged.historyHeads))
    }

    func testCorruptSourceStopsBeforeNetworkMutation() async throws {
        let root = temporaryDirectory()
        let oldDirectory = root.appending(path: "Notes")
        try FileManager.default.createDirectory(
            at: oldDirectory, withIntermediateDirectories: true
        )
        try Data("broken".utf8).write(
            to: oldDirectory.appending(path: "note.automerge")
        )
        let transport = CountingLegacyTransport(scope: legacyScope)
        let bridge = NotebookLegacyBridge(
            directory: root.appending(path: "Notebook/LegacyBridge"),
            legacyDirectory: oldDirectory
        )

        do {
            _ = try await bridge.synchronize(
                legacyTransport: transport,
                notebookScope: notebookScope
            )
            XCTFail("Expected corrupt source refusal")
        } catch let error as NotebookLegacyBridgeError {
            XCTAssertEqual(error, .sourceUnavailable)
        }
        let corruptSourceMutations = await transport.mutationCount
        XCTAssertEqual(corruptSourceMutations, 0)
    }

    func testScopeAndOldBindingRefusalsPrecedeNetworkMutation() async throws {
        XCTAssertNoThrow(
            try NotebookLegacyBridge.validateCloudScopes(
                legacy: "http://localhost/workspace",
                notebook: "http://localhost/workspace#v2"
            )
        )
        XCTAssertThrowsError(
            try NotebookLegacyBridge.validateCloudScopes(
                legacy: legacyScope,
                notebook: "iCloud.test/private/other/meh-md-notebook-v2"
            )
        ) { XCTAssertEqual(
            $0 as? NotebookLegacyBridgeError, .incompatibleCloudScopes
        ) }
        XCTAssertThrowsError(
            try NotebookLegacyBridge.validateCloudScopes(
                legacy: legacyScope,
                notebook: legacyScope + "#v2"
            )
        ) { XCTAssertEqual(
            $0 as? NotebookLegacyBridgeError, .incompatibleCloudScopes
        ) }

        let root = temporaryDirectory()
        let oldDirectory = root.appending(path: "Notes")
        try SyncFileIO.replace(
            JSONEncoder().encode(SyncState(scope: "another-scope")),
            at: oldDirectory.appending(path: "sync-state.json")
        )
        let transport = CountingLegacyTransport(scope: legacyScope)
        let bridge = NotebookLegacyBridge(
            directory: root.appending(path: "Notebook/LegacyBridge"),
            legacyDirectory: oldDirectory
        )

        do {
            _ = try await bridge.synchronize(
                legacyTransport: transport,
                notebookScope: notebookScope
            )
            XCTFail("Expected old scope refusal")
        } catch let error as NotebookLegacyBridgeError {
            XCTAssertEqual(error, .legacyScopeChanged)
        }
        let wrongScopeMutations = await transport.mutationCount
        XCTAssertEqual(wrongScopeMutations, 0)
    }

    func testExplicitSourceAndBridgeRecoveryRestorePreviousCopies() async throws {
        let root = temporaryDirectory()
        let oldDirectory = root.appending(path: "Notes")
        let bridgeDirectory = root.appending(path: "Notebook/LegacyBridge")
        let sourceStorage = NoteFileStorage(directory: oldDirectory)
        let bridgeStorage = NoteFileStorage(directory: bridgeDirectory)
        let note = try NoteDocument(text: "Previous")
        try await sourceStorage.save(note.snapshot())
        try await bridgeStorage.save(note.snapshot())
        try note.replaceAll(with: "Newer")
        try await sourceStorage.save(note.snapshot())
        try await bridgeStorage.save(note.snapshot())
        try Data("source damage".utf8).write(to: sourceStorage.currentURL)
        try Data("bridge damage".utf8).write(to: bridgeStorage.currentURL)
        let bridge = NotebookLegacyBridge(
            directory: bridgeDirectory,
            legacyDirectory: oldDirectory
        )

        let source = try await bridge.recoverSourceFromPrevious()
        let copy = try await bridge.recoverBridgeFromPrevious()

        XCTAssertEqual(try NoteDocument(snapshot: source).text, "Previous")
        XCTAssertEqual(try NoteDocument(snapshot: copy).text, "Previous")
    }

    private var legacyScope: String { cloudRoot + "/meh-md-sync-v1" }
    private var notebookScope: String {
        cloudRoot + "/meh-md-notebook-v2"
    }

    private func transport(store: InMemorySyncStore) -> InMemorySyncTransport {
        InMemorySyncTransport(scope: legacyScope, store: store)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "NotebookLegacyBridgeTests-\(UUID().uuidString)"
        )
        temporaryDirectories.append(url)
        return url
    }
}

private actor CountingLegacyTransport: SyncTransport {
    nonisolated let scope: String
    private(set) var mutationCount = 0

    init(scope: String) { self.scope = scope }

    func bootstrap(proposing record: SyncRecord) -> SyncRecord {
        mutationCount += 1
        return record
    }

    func publish(_ record: SyncRecord) { mutationCount += 1 }

    func fetch(after cursor: String?) -> SyncPage {
        SyncPage(records: [], cursor: "done", hasMore: false)
    }
}
