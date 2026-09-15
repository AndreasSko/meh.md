import Foundation
import XCTest
@testable import NoteCore

@MainActor
final class NoteSyncCoordinatorTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meh-sync-tests-\(UUID())")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testThreeOfflineReplicasConvergeAfterRestartAndReplay() async throws {
        let remote = TestRecordStore()
        let a = await makeReplica("a", remote)
        let b = await makeReplica("b", remote)
        let c = await makeReplica("c", remote)
        try a.session.replaceAll(with: "one\ntwo\nthree\n")
        await a.sync.synchronize()
        await b.sync.synchronize()
        await c.sync.synchronize()
        try a.session.replaceText(in: NSRange(location: 0, length: 0), with: "A😀\n")
        try b.session.replaceText(in: NSRange(location: 4, length: 0), with: "Bé\n")
        try c.session.replaceText(in: NSRange(location: 8, length: 0), with: "C世界\n")
        try await a.session.flush()
        try await b.session.flush()
        try await c.session.flush()

        // Recreate every local owner from its own durable files.
        let reopenedA = await makeReplica("a", remote)
        let reopenedB = await makeReplica("b", remote)
        let reopenedC = await makeReplica("c", remote)
        await remote.setDuplicateAndReverseDelivery(true)
        for replica in [reopenedA, reopenedB, reopenedC, reopenedA, reopenedB] {
            await replica.sync.synchronize()
            assertExchanged(replica.sync)
        }
        XCTAssertEqual(reopenedA.session.text, reopenedB.session.text)
        XCTAssertEqual(reopenedB.session.text, reopenedC.session.text)
        for text in ["A😀", "Bé", "C世界", "one", "two", "three"] {
            XCTAssertTrue(reopenedA.session.text.contains(text))
        }
        XCTAssertEqual(
            reopenedA.session.persistedSnapshot?.heads,
            reopenedC.session.persistedSnapshot?.heads
        )
    }

    func testLostUploadAcknowledgmentRetriesAfterRestart() async throws {
        let remote = TestRecordStore()
        let a = await makeReplica("a", remote)
        try a.session.replaceAll(with: "acknowledged locally")
        await remote.loseNextPublishResponse()
        await a.sync.synchronize()
        assertFailed(a.sync)
        let before = await remote.recordCount
        let reopened = await makeReplica("a", remote)
        await reopened.sync.synchronize()
        assertExchanged(reopened.sync)
        let after = await remote.recordCount
        XCTAssertEqual(before, after, "Retry must reuse the immutable record")
        let b = await makeReplica("b", remote)
        await b.sync.synchronize()
        XCTAssertEqual(b.session.text, "acknowledged locally")
    }

    func testLostBootstrapResponseKeepsTheAcceptedSeedAcrossRestart() async throws {
        let remote = TestRecordStore()
        await remote.loseNextBootstrapResponse()
        let a = await makeReplica("a", remote)
        let initialID = a.session.persistedSnapshot?.noteID
        try a.session.replaceAll(with: "written after uncertain first connection")
        try await a.session.flush()
        let reopened = await makeReplica("a", remote)
        await reopened.sync.synchronize()
        assertExchanged(reopened.sync)
        XCTAssertEqual(reopened.session.persistedSnapshot?.noteID, initialID)
        let b = await makeReplica("b", remote)
        await b.sync.synchronize()
        XCTAssertEqual(b.session.text, "written after uncertain first connection")
    }

    func testStrictFirstLaunchWaitsForCanonicalBootstrapAndCanRetry() async throws {
        let remote = TestRecordStore()
        await remote.loseNextBootstrapResponse()
        let noteDirectory = directory.appendingPathComponent("strict")
        let storage = SyncBootstrapStorage(
            storage: NoteFileStorage(directory: noteDirectory),
            transport: remote,
            proposalURL: noteDirectory.appendingPathComponent(
                "bootstrap-proposal.json"
            ),
            allowsOfflineFirstLaunch: false
        )
        let session = NoteSession(storage: storage)

        await session.load()
        guard case .blocked = session.status else {
            return XCTFail("Fresh strict sync should wait for the server")
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: noteDirectory.appendingPathComponent("note.automerge").path
        ))

        let acceptedPage = try await remote.fetch(after: nil)
        let accepted = try XCTUnwrap(acceptedPage.records.first)
        let otherAccount = TestRecordStore(scope: "other-account")
        let mismatchedStorage = SyncBootstrapStorage(
            storage: NoteFileStorage(directory: noteDirectory),
            transport: otherAccount,
            proposalURL: noteDirectory.appendingPathComponent(
                "bootstrap-proposal.json"
            ),
            allowsOfflineFirstLaunch: false
        )
        guard case .blocked = await mismatchedStorage.load() else {
            return XCTFail("A proposal from another account must stay blocked")
        }
        let setupError = await mismatchedStorage.bootstrapErrorDescription()
        XCTAssertEqual(setupError, SyncError.scopeChanged.localizedDescription)
        let otherAccountCalls = await otherAccount.bootstrapCalls
        XCTAssertEqual(otherAccountCalls, 0)

        await session.load()
        XCTAssertEqual(session.status, .saved)
        XCTAssertEqual(session.persistedSnapshot, accepted.snapshot)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: noteDirectory.appendingPathComponent("note.automerge").path
        ))
    }

    func testPreviousFileRecoveryReplaysRecordsBeyondOldCheckpoint() async throws {
        let remote = TestRecordStore()
        let a = await makeReplica("a", remote)
        try a.session.replaceAll(with: "base")
        await a.sync.synchronize()
        let b = await makeReplica("b", remote)
        await b.sync.synchronize()
        try a.session.replaceAll(with: "base plus remote changes")
        await a.sync.synchronize()
        await b.sync.synchronize()
        XCTAssertEqual(b.session.text, "base plus remote changes")

        let current = directory.appendingPathComponent("b/note.automerge")
        try Data("damaged current file".utf8).write(to: current)
        let recovered = await makeReplica("b", remote)
        await recovered.session.recoverFromPrevious()
        XCTAssertEqual(recovered.session.text, "base")
        await recovered.sync.synchronize()
        assertExchanged(recovered.sync)
        XCTAssertEqual(recovered.session.text, "base plus remote changes")
    }

    func testMissingSyncBookkeepingReplaysAndDiscoversSavedEdits() async throws {
        let remote = TestRecordStore()
        let a = await makeReplica("a", remote)
        await a.sync.synchronize()
        try a.session.replaceAll(with: "saved before upload discovery")
        try await a.session.flush()
        try FileManager.default.removeItem(at: stateURL("a"))
        let reopened = await makeReplica("a", remote)
        await reopened.sync.synchronize()
        assertExchanged(reopened.sync)
        let b = await makeReplica("b", remote)
        await b.sync.synchronize()
        XCTAssertEqual(b.session.text, reopened.session.text)
    }

    func testFailedDownloadSaveDoesNotAdvanceCursor() async throws {
        let remote = TestRecordStore()
        let a = await makeReplica("a", remote)
        let bStore = FailingSyncNoteStorage(
            backing: NoteFileStorage(directory: directory.appendingPathComponent("b"))
        )
        let b = await makeReplica("b", remote, storage: bStore)
        await b.sync.synchronize()
        let stateStore = SyncStateStorage(url: stateURL("b"))
        let before = try await stateStore.load(scope: remote.scope)
        try a.session.replaceAll(with: "remote must survive retry")
        await a.sync.synchronize()
        await bStore.setFailure(true)
        await b.sync.synchronize()
        assertFailed(b.sync)
        let afterFailure = try await stateStore.load(scope: remote.scope)
        XCTAssertEqual(afterFailure, before)
        XCTAssertEqual(b.session.text, "remote must survive retry")

        // Unsaved memory is deliberately discarded to model process loss.
        let reopened = await makeReplica("b", remote)
        await reopened.sync.synchronize()
        assertExchanged(reopened.sync)
        XCTAssertEqual(reopened.session.text, "remote must survive retry")
    }

    func testUploadOfOlderSnapshotCannotAcknowledgeLaterTyping() async throws {
        let remote = TestRecordStore()
        let a = await makeReplica("a", remote)
        try a.session.replaceAll(with: "first")
        await remote.pauseNextPublish()
        let exchange = Task { await a.sync.synchronize() }
        for _ in 0..<1_000 {
            if await remote.publishIsPaused { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let paused = await remote.publishIsPaused
        XCTAssertTrue(paused)
        try a.session.replaceAll(with: "first plus later typing")
        try await a.session.flush()
        await remote.resumePublish()
        await exchange.value
        XCTAssertEqual(a.sync.status, .pending)
        await a.sync.synchronize()
        assertExchanged(a.sync)
        let b = await makeReplica("b", remote)
        await b.sync.synchronize()
        XCTAssertEqual(b.session.text, "first plus later typing")
    }

    func testDifferentExistingNotesArePreservedAndSyncStops() async throws {
        let remote = TestRecordStore()
        let a = await makeReplica("a", remote)
        try a.session.replaceAll(with: "server note")
        await a.sync.synchronize()
        let local = NoteFileStorage(directory: directory.appendingPathComponent("b"))
        let original = try NoteDocument(text: "independent local note").snapshot()
        try await local.save(original)
        let b = await makeReplica("b", remote)
        await b.sync.synchronize()
        assertFailed(b.sync)
        XCTAssertEqual(b.session.persistedSnapshot, original)
        XCTAssertEqual(b.session.text, "independent local note")
        XCTAssertEqual(a.session.text, "server note")
    }

    func testMatchingUUIDWithoutSharedHistoryCannotMerge() throws {
        let id = UUID()
        let a = try NoteDocument(noteID: id, text: "first root")
        let b = try NoteDocument(noteID: id, text: "different root")
        XCTAssertThrowsError(try a.merge(b)) {
            XCTAssertEqual($0 as? SyncError, .disconnectedHistory)
        }
        XCTAssertEqual(try a.text, "first root")
    }

    func testAccountScopeChangeStopsBeforeNetworkWrites() async throws {
        let remote = TestRecordStore(scope: "account-a")
        let a = await makeReplica("a", remote)
        await a.sync.synchronize()
        let differentAccount = TestRecordStore(scope: "account-b")
        let next = await makeReplica("a", differentAccount)
        await next.sync.synchronize()
        assertFailed(next.sync)
        let calls = await differentAccount.bootstrapCalls
        XCTAssertEqual(calls, 0)
    }

    func testInvalidCursorReplaysFullRemoteHistory() async throws {
        let remote = TestRecordStore()
        let a = await makeReplica("a", remote)
        await a.sync.synchronize()
        let b = await makeReplica("b", remote)
        try b.session.replaceAll(with: "remote edit after checkpoint")
        await b.sync.synchronize()
        XCTAssertEqual(a.session.text, "")
        let stateStore = SyncStateStorage(url: stateURL("a"))
        var state = try await stateStore.load(scope: remote.scope)
        state.cursor = "invalid"
        try await stateStore.save(state)
        await a.sync.synchronize()
        assertExchanged(a.sync)
        XCTAssertEqual(a.session.text, "remote edit after checkpoint")
    }

    func testCorruptMetadataIsNotSilentlyReset() async throws {
        let remote = TestRecordStore()
        let a = await makeReplica("a", remote)
        await a.sync.synchronize()
        try Data("broken".utf8).write(to: stateURL("a"))
        let callsBefore = await remote.bootstrapCalls
        await a.sync.synchronize()
        assertFailed(a.sync)
        let callsAfter = await remote.bootstrapCalls
        XCTAssertEqual(callsBefore, callsAfter)
        XCTAssertEqual(try Data(contentsOf: stateURL("a")), Data("broken".utf8))
    }

    func testReopeningRestoresAcknowledgedStatusWithoutNetwork() async throws {
        let remote = TestRecordStore()
        let a = await makeReplica("a", remote)
        try a.session.replaceAll(with: "already exchanged")
        await a.sync.synchronize()
        assertExchanged(a.sync)
        let reopened = await makeReplica("a", remote)
        let calls = await remote.bootstrapCalls
        reopened.sync.noteDidSave()
        await reopened.sync.restoreStatus()
        assertExchanged(reopened.sync)
        let after = await remote.bootstrapCalls
        XCTAssertEqual(calls, after)
    }

    func testStaleEditorCommitRetainsRemoteAndComposedText() async throws {
        let remote = TestRecordStore()
        let a = await makeReplica("a", remote)
        try a.session.replaceAll(with: "hello world")
        await a.sync.synchronize()
        let b = await makeReplica("b", remote)
        await b.sync.synchronize()
        let displayed = try XCTUnwrap(b.session.editorRevision)
        try a.session.replaceText(in: NSRange(location: 0, length: 0), with: "remote ")
        await a.sync.synchronize()
        await b.sync.synchronize()
        try b.session.commitEditorText("hello world世界", basedOn: displayed)
        try await b.session.flush()
        XCTAssertEqual(b.session.text, "remote hello world世界")
        await b.sync.synchronize()
        await a.sync.synchronize()
        XCTAssertEqual(a.session.text, b.session.text)
    }

    func testSamePositionConcurrentEditsHaveStableConvergedOutcome() async throws {
        let remote = TestRecordStore()
        let a = await makeReplica("a", remote)
        let b = await makeReplica("b", remote)
        try a.session.replaceAll(with: "A")
        try b.session.replaceAll(with: "B")
        await a.sync.synchronize()
        await b.sync.synchronize()
        await a.sync.synchronize()
        XCTAssertEqual(a.session.text, b.session.text)
        XCTAssertEqual(Set(a.session.text), Set("AB"))
        XCTAssertEqual(a.session.text.count, 2)
    }

    private struct Replica {
        let session: NoteSession
        let sync: NoteSyncCoordinator
    }

    private func stateURL(_ name: String) -> URL {
        directory.appendingPathComponent(name).appendingPathComponent("sync.json")
    }

    private func makeReplica(
        _ name: String,
        _ remote: TestRecordStore,
        storage: (any NoteStorage)? = nil
    ) async -> Replica {
        let noteStore = storage ?? NoteFileStorage(
            directory: directory.appendingPathComponent(name)
        )
        let session = NoteSession(storage: SyncBootstrapStorage(
            storage: noteStore, transport: remote,
            proposalURL: directory.appendingPathComponent(name)
                .appendingPathComponent("bootstrap-proposal.json")
        ))
        await session.load()
        return Replica(session: session, sync: NoteSyncCoordinator(
            session: session, transport: remote, stateURL: stateURL(name)
        ))
    }

    private func assertExchanged(
        _ sync: NoteSyncCoordinator,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .exchanged = sync.status else {
            return XCTFail("Unexpected sync status: \(sync.status)", file: file, line: line)
        }
    }

    private func assertFailed(
        _ sync: NoteSyncCoordinator,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .failed = sync.status else {
            return XCTFail("Expected failure: \(sync.status)", file: file, line: line)
        }
    }
}

private actor TestRecordStore: SyncTransport {
    nonisolated let scope: String
    private var seed: SyncRecord?
    private var records: [SyncRecord] = []
    private var duplicateAndReverse = false
    private var loseResponse = false
    private var loseBootstrapResponse = false
    private var pausePublish = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var bootstrapCalls = 0

    init(scope: String = "test-account") { self.scope = scope }
    var recordCount: Int { records.count }
    var publishIsPaused: Bool { continuation != nil }

    func bootstrap(proposing record: SyncRecord) throws -> SyncRecord {
        bootstrapCalls += 1
        if let seed { return seed }
        try record.validate()
        seed = record
        records.append(record)
        if loseBootstrapResponse {
            loseBootstrapResponse = false
            throw SyncError.unavailable("Lost bootstrap response after remote commit")
        }
        return record
    }

    func publish(_ record: SyncRecord) async throws {
        try record.validate()
        if pausePublish {
            pausePublish = false
            await withCheckedContinuation { continuation = $0 }
        }
        if !records.contains(where: { $0.id == record.id }) { records.append(record) }
        if loseResponse {
            loseResponse = false
            throw SyncError.unavailable("Lost response after remote commit")
        }
    }

    func fetch(after cursor: String?) throws -> SyncPage {
        let offset: Int
        if let cursor {
            guard let value = Int(cursor), value >= 0, value <= records.count else {
                throw SyncError.invalidCursor
            }
            offset = value
        } else { offset = 0 }
        let end = min(offset + 2, records.count)
        var batch = Array(records[offset..<end])
        if duplicateAndReverse { batch = batch.reversed() + batch }
        return SyncPage(records: batch, cursor: String(end), hasMore: end < records.count)
    }

    func setDuplicateAndReverseDelivery(_ enabled: Bool) { duplicateAndReverse = enabled }
    func loseNextPublishResponse() { loseResponse = true }
    func loseNextBootstrapResponse() { loseBootstrapResponse = true }
    func pauseNextPublish() { pausePublish = true }
    func resumePublish() { continuation?.resume(); continuation = nil }
}

private actor FailingSyncNoteStorage: NoteStorage {
    let backing: NoteFileStorage
    var failing = false

    init(backing: NoteFileStorage) { self.backing = backing }
    func setFailure(_ value: Bool) { failing = value }
    func load() async -> NoteLoadResult { await backing.load() }
    func save(_ snapshot: NoteSnapshot) async throws {
        if failing { throw SyncError.unavailable("Injected local write failure") }
        try await backing.save(snapshot)
    }
    func recover(_ recovery: NoteRecovery) async throws -> NoteSnapshot {
        try await backing.recover(recovery)
    }
}
