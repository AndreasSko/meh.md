import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class NotebookSyncCoordinatorTests: XCTestCase {
    nonisolated(unsafe) private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    func testFreshClientsAdoptCanonicalBootstrap() async throws {
        let store = InMemorySyncStore()
        let transport = InMemorySyncTransport(scope: "shared", store: store)
        let left = NotebookReplica(directory: directory())
        let right = NotebookReplica(directory: directory())

        await NotebookSyncCoordinator(
            replica: left,
            transport: transport
        ).synchronize()
        await NotebookSyncCoordinator(
            replica: right,
            transport: transport
        ).synchronize()

        XCTAssertEqual(
            left.catalogSnapshot?.notebookID,
            right.catalogSnapshot?.notebookID
        )
        XCTAssertNotNil(left.catalogSnapshot)
    }

    func testDurableBindingRequiresAcceptedCanonicalSeed() async throws {
        let root = directory()
        let replica = NotebookReplica(directory: root)
        try await replica.createLocalNotebook()
        let coordinator = NotebookSyncCoordinator(
            replica: replica,
            transport: InMemorySyncTransport(scope: "binding")
        )

        XCTAssertFalse(try coordinator.hasDurableBinding())
        await coordinator.synchronize()
        XCTAssertTrue(try coordinator.hasDurableBinding())

        let reopened = NotebookReplica(directory: root)
        try await reopened.load()
        XCTAssertTrue(
            try NotebookSyncCoordinator(
                replica: reopened,
                transport: InMemorySyncTransport(scope: "binding")
            ).hasDurableBinding()
        )
        XCTAssertThrowsError(
            try NotebookSyncCoordinator(
                replica: reopened,
                transport: InMemorySyncTransport(scope: "other-binding")
            ).hasDurableBinding()
        ) { XCTAssertEqual($0 as? SyncError, .scopeChanged) }
    }

    func testLostBootstrapAcknowledgementReusesDurableProposal() async throws {
        let store = InMemorySyncStore()
        let transport = InMemorySyncTransport(scope: "shared", store: store)
        let root = directory()
        await store.loseNextAcknowledgement()
        await NotebookSyncCoordinator(
            replica: NotebookReplica(directory: root),
            transport: transport
        ).synchronize()
        let proposalURL = root.appending(path: "notebook-proposal.json")
        let original = try Data(contentsOf: proposalURL)

        let restarted = NotebookReplica(directory: root)
        let coordinator = NotebookSyncCoordinator(
            replica: restarted,
            transport: transport
        )
        await coordinator.synchronize()

        XCTAssertEqual(try Data(contentsOf: proposalURL), original)
        XCTAssertNotNil(restarted.catalogSnapshot)
        assertExchanged(coordinator.status)
    }

    func testIndependentNotesAndCatalogEditsConvergeAfterReopen() async throws {
        let store = InMemorySyncStore()
        let transport = InMemorySyncTransport(scope: "shared", store: store)
        let leftRoot = directory()
        let rightRoot = directory()
        let left = NotebookReplica(directory: leftRoot)
        let right = NotebookReplica(directory: rightRoot)
        let leftSync = NotebookSyncCoordinator(replica: left, transport: transport)
        let rightSync = NotebookSyncCoordinator(replica: right, transport: transport)
        await leftSync.synchronize()
        await rightSync.synchronize()

        let folder = try await left.createFolder(name: "Work")
        let leftNote = try await left.createNote(name: "left.md", text: "left")
        let rightNote = try await right.createNote(name: "right.md", text: "right")
        try await left.rename(leftNote, to: "renamed.md")
        try await left.move(leftNote, to: folder)
        let rightSession = try await right.openNote(rightNote)
        try rightSession.replaceText(
            in: NSRange(location: 0, length: 5),
            with: "right edited"
        )
        try await rightSession.flush()

        await leftSync.synchronize()
        await rightSync.synchronize()
        await leftSync.synchronize()

        let reopened = NotebookReplica(directory: leftRoot)
        await NotebookSyncCoordinator(
            replica: reopened,
            transport: transport
        ).synchronize()
        let names = Dictionary(
            uniqueKeysWithValues: reopened.placements.map {
                ($0.item.id, $0.item.name)
            }
        )
        XCTAssertEqual(names[leftNote], "renamed.md")
        XCTAssertEqual(names[rightNote], "right.md")
        XCTAssertEqual(
            reopened.placements.first { $0.item.id == leftNote }?.parentID,
            folder
        )
        let reopenedSession = try await reopened.openNote(rightNote)
        XCTAssertEqual(reopenedSession.text, "right edited")
    }

    func testFetchOrderDoesNotLeaveReferencedNoteUnavailable() async throws {
        for noteFirst in [true, false] {
            let notebookID = UUID()
            let seed = try NotebookCatalogDocument(notebookID: notebookID)
            let note = try NoteDocument(text: "arrived")
            let catalog = try seed.fork()
            try catalog.add(id: note.noteID, kind: .note, name: "arrived.md")
            let body = SyncRecord(snapshot: note.snapshot(), notebookID: notebookID)
            let metadata = SyncRecord(catalog: catalog.snapshot())
            let transport = OrderedTransport(
                seed: SyncRecord(catalog: seed.snapshot()),
                records: noteFirst ? [body, metadata] : [metadata, body]
            )
            let replica = NotebookReplica(directory: directory())

            await NotebookSyncCoordinator(
                replica: replica,
                transport: transport
            ).synchronize()

            let session = try await replica.openNote(note.noteID)
            XCTAssertEqual(session.text, "arrived")
        }
    }

    func testMissingReferencedNoteCannotCreateEmptyDocument() async throws {
        let catalog = try NotebookCatalogDocument()
        let missing = try catalog.add(kind: .note, name: "missing.md")
        let replica = NotebookReplica(directory: directory())
        try await replica.acceptSeed(SyncRecord(catalog: catalog.snapshot()))

        do {
            _ = try await replica.openNote(missing)
            XCTFail("Expected the referenced note body to be unavailable")
        } catch let error as NotebookReplicaError {
            XCTAssertEqual(error, .noteUnavailable(missing))
        }
        let storage = replica.noteStorage(missing)
        guard case .firstLaunch = await storage.load() else {
            return XCTFail("Opening a missing note created local content")
        }
    }

    func testScopeChangeStopsBeforeNetworkMutation() async throws {
        let root = directory()
        let initial = InMemorySyncTransport(scope: "first")
        await NotebookSyncCoordinator(
            replica: NotebookReplica(directory: root),
            transport: initial
        ).synchronize()
        let changed = CountingTransport(scope: "second")
        let coordinator = NotebookSyncCoordinator(
            replica: NotebookReplica(directory: root),
            transport: changed
        )

        await coordinator.synchronize()

        let mutationCount = await changed.currentMutationCount()
        XCTAssertEqual(mutationCount, 0)
        guard case .failed = coordinator.status else {
            return XCTFail("Expected a scope-change failure")
        }
    }

    func testUnrelatedLocalNotebookConflictsWithoutReplacement() async throws {
        let store = InMemorySyncStore()
        let transport = InMemorySyncTransport(scope: "shared", store: store)
        let remote = NotebookReplica(directory: directory())
        await NotebookSyncCoordinator(replica: remote, transport: transport)
            .synchronize()
        let local = NotebookReplica(directory: directory())
        try await local.createLocalNotebook()
        let original = try XCTUnwrap(local.catalogSnapshot)
        let coordinator = NotebookSyncCoordinator(
            replica: local,
            transport: transport
        )

        await coordinator.synchronize()

        guard case .failed = coordinator.status else {
            return XCTFail("Expected unrelated notebook conflict")
        }
        XCTAssertEqual(local.catalogSnapshot, original)
    }

    func testPreviousFileRollbackForcesReplayFromNilCursor() async throws {
        let store = InMemorySyncStore()
        let base = InMemorySyncTransport(scope: "rollback", store: store)
        let root = directory()
        let replica = NotebookReplica(directory: root)
        let coordinator = NotebookSyncCoordinator(replica: replica, transport: base)
        await coordinator.synchronize()
        let noteID = try await replica.createNote(name: "note.md", text: "one")
        await coordinator.synchronize()
        let session = try await replica.openNote(noteID)
        try session.replaceAll(with: "two")
        try await session.flush()
        await coordinator.synchronize()

        let storage = replica.noteStorage(noteID)
        try Data(contentsOf: storage.previousURL).write(
            to: storage.currentURL,
            options: .atomic
        )
        let recording = RecordingTransport(base: base)
        await NotebookSyncCoordinator(
            replica: NotebookReplica(directory: root),
            transport: recording
        ).synchronize()

        let cursors = await recording.fetchCursors
        XCTAssertEqual(cursors.first!, nil)
    }

    func testCatalogPreviousFileRollbackAlsoForcesReplay() async throws {
        let base = InMemorySyncTransport(scope: "catalog-rollback")
        let root = directory()
        let replica = NotebookReplica(directory: root)
        let coordinator = NotebookSyncCoordinator(replica: replica, transport: base)
        await coordinator.synchronize()
        let folder = try await replica.createFolder(name: "Before")
        await coordinator.synchronize()
        let storage = NotebookCatalogStorage(directory: root)
        let beforeRename = try Data(contentsOf: storage.currentURL)
        try await replica.rename(folder, to: "After")
        await coordinator.synchronize()
        try beforeRename.write(
            to: storage.currentURL,
            options: .atomic
        )
        let recording = RecordingTransport(base: base)
        let reopened = NotebookReplica(directory: root)

        await NotebookSyncCoordinator(replica: reopened, transport: recording)
            .synchronize()

        let cursors = await recording.fetchCursors
        XCTAssertEqual(cursors.first!, nil)
        XCTAssertEqual(
            reopened.placements.first { $0.item.id == folder }?.item.name,
            "After"
        )
    }

    func testFailedRemoteSaveDoesNotAdvanceCursor() async throws {
        let notebookID = UUID()
        let seed = try NotebookCatalogDocument(notebookID: notebookID)
        let note = try NoteDocument(text: "remote")
        let updated = try seed.fork()
        try updated.add(id: note.noteID, kind: .note, name: "remote.md")
        let transport = OrderedTransport(
            seed: SyncRecord(catalog: seed.snapshot()),
            records: [
                SyncRecord(snapshot: note.snapshot(), notebookID: notebookID),
                SyncRecord(catalog: updated.snapshot()),
            ]
        )
        let root = directory()
        let notesURL = root.appending(path: "notes")
        try FileManager.default.createDirectory(
            at: notesURL,
            withIntermediateDirectories: true
        )
        try Data("blocks directory".utf8).write(
            to: notesURL.appending(path: note.noteID.uuidString)
        )
        let coordinator = NotebookSyncCoordinator(
            replica: NotebookReplica(directory: root),
            transport: transport
        )

        await coordinator.synchronize()

        guard case .failed = coordinator.status else {
            return XCTFail("Expected durable note save failure")
        }
        let state = try JSONDecoder().decode(
            NotebookSyncState.self,
            from: Data(
                contentsOf: root.appending(path: "notebook-sync-state.json")
            )
        )
        XCTAssertNil(state.cursor)
    }

    func testTypingDuringUploadLeavesCoordinatorPending() async throws {
        let base = InMemorySyncTransport(scope: "pending")
        let transport = PausingPublishTransport(base: base)
        let replica = NotebookReplica(directory: directory())
        try await replica.createLocalNotebook()
        let noteID = try await replica.createNote(name: "note.md", text: "before")
        let session = try await replica.openNote(noteID)
        let coordinator = NotebookSyncCoordinator(
            replica: replica,
            transport: transport
        )

        let sync = Task { await coordinator.synchronize() }
        await transport.waitUntilPublishStarts()
        try session.replaceAll(with: "during upload")
        try await session.flush()
        await transport.resumePublish()
        await sync.value

        XCTAssertEqual(coordinator.status, .pending)
    }

    func testPermanentDeletionBlocksStaleNoteAndRecoversNewChild() async throws {
        let store = InMemorySyncStore()
        let transport = InMemorySyncTransport(scope: "deletions", store: store)
        let left = NotebookReplica(directory: directory())
        let right = NotebookReplica(directory: directory())
        let leftSync = NotebookSyncCoordinator(replica: left, transport: transport)
        let rightSync = NotebookSyncCoordinator(replica: right, transport: transport)
        await leftSync.synchronize()
        let folder = try await left.createFolder(name: "Folder")
        let stale = try await left.createNote(
            name: "stale.md",
            text: "stale",
            parentID: folder
        )
        await leftSync.synchronize()
        await rightSync.synchronize()
        let staleSession = try await right.openNote(stale)

        try await left.markPermanentlyDeleted([folder, stale])
        let survivor = try await right.createNote(
            name: "survivor.md",
            text: "survivor",
            parentID: folder
        )
        await leftSync.synchronize()
        await rightSync.synchronize()
        await leftSync.synchronize()

        XCTAssertTrue(staleSession.isPermanentlyDeleted)
        XCTAssertFalse(staleSession.isEditingEnabled)
        let placement = try XCTUnwrap(
            left.placements.first { $0.item.id == survivor }
        )
        XCTAssertNil(placement.parentID)
        XCTAssertTrue(placement.issues.contains(.missingParent))
        XCTAssertFalse(left.placements.contains { $0.item.id == folder })
        do {
            _ = try await left.openNote(stale)
            XCTFail("Permanently deleted note reopened")
        } catch let error as NotebookReplicaError {
            XCTAssertEqual(error, .permanentlyDeleted(stale))
        }
    }

    func testLegacyRevisionsJoinAndNewerProposalSurvivesRestart() async throws {
        let store = InMemorySyncStore()
        let transport = InMemorySyncTransport(scope: "legacy", store: store)
        let original = try NoteDocument(text: "original")
        let newer = try original.fork()
        try newer.replaceAll(with: "newer")
        let first = NotebookReplica(directory: directory())
        await NotebookSyncCoordinator(replica: first, transport: transport)
            .synchronize(legacyNote: original.snapshot())
        let secondRoot = directory()
        let second = NotebookReplica(directory: secondRoot)
        await NotebookSyncCoordinator(replica: second, transport: transport)
            .synchronize(legacyNote: newer.snapshot())

        let restarted = NotebookReplica(directory: secondRoot)
        await NotebookSyncCoordinator(replica: restarted, transport: transport)
            .synchronize()
        let session = try await restarted.openNote(original.noteID)
        XCTAssertEqual(session.text, "newer")
        await NotebookSyncCoordinator(replica: first, transport: transport)
            .synchronize(legacyNote: original.snapshot())
        let firstSession = try await first.openNote(original.noteID)
        XCTAssertEqual(firstSession.text, "newer")
    }

    func testLegacyProposalReadoptsAfterPreCheckpointRollback() async throws {
        let base = InMemorySyncTransport(scope: "legacy-rollback")
        let original = try NoteDocument(text: "original")
        let newer = try original.fork()
        try newer.replaceAll(with: "newer")
        let root = directory()
        let first = NotebookReplica(directory: root)
        await NotebookSyncCoordinator(replica: first, transport: base)
            .synchronize(legacyNote: original.snapshot())
        let interrupted = NotebookReplica(directory: root)
        await NotebookSyncCoordinator(
            replica: interrupted,
            transport: FailingFetchTransport(base: base)
        ).synchronize(legacyNote: newer.snapshot())
        let storage = interrupted.noteStorage(original.noteID)
        try Data(contentsOf: storage.previousURL).write(
            to: storage.currentURL,
            options: .atomic
        )

        let restarted = NotebookReplica(directory: root)
        await NotebookSyncCoordinator(replica: restarted, transport: base)
            .synchronize()

        let session = try await restarted.openNote(original.noteID)
        XCTAssertEqual(session.text, "newer")
    }

    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "NotebookSyncCoordinatorTests-\(UUID().uuidString)"
        )
        roots.append(url)
        return url
    }

    private func assertExchanged(
        _ status: NoteSyncCoordinator.Status,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .exchanged = status else {
            return XCTFail("Expected exchanged, got \(status)", file: file, line: line)
        }
    }
}

private actor OrderedTransport: SyncTransport {
    nonisolated let scope = "ordered-v2"
    let seed: SyncRecord
    let records: [SyncRecord]

    init(seed: SyncRecord, records: [SyncRecord]) {
        self.seed = seed
        self.records = records
    }

    func bootstrap(proposing record: SyncRecord) -> SyncRecord { seed }
    func publish(_ record: SyncRecord) {}
    func fetch(after cursor: String?) -> SyncPage {
        SyncPage(records: cursor == nil ? records : [], cursor: "done", hasMore: false)
    }
}

private actor CountingTransport: SyncTransport {
    nonisolated let scope: String
    private(set) var mutationCount = 0

    init(scope: String) { self.scope = scope }

    func currentMutationCount() -> Int { mutationCount }

    func bootstrap(proposing record: SyncRecord) throws -> SyncRecord {
        mutationCount += 1
        throw SyncError.unavailable("Unexpected bootstrap")
    }
    func publish(_ record: SyncRecord) { mutationCount += 1 }
    func fetch(after cursor: String?) -> SyncPage {
        SyncPage(records: [], cursor: "done", hasMore: false)
    }
}

private actor RecordingTransport: SyncTransport {
    nonisolated let scope: String
    private let base: InMemorySyncTransport
    private(set) var fetchCursors: [String?] = []

    init(base: InMemorySyncTransport) {
        self.base = base
        scope = base.scope
    }

    func bootstrap(proposing record: SyncRecord) async throws -> SyncRecord {
        try await base.bootstrap(proposing: record)
    }

    func publish(_ record: SyncRecord) async throws {
        try await base.publish(record)
    }

    func fetch(after cursor: String?) async throws -> SyncPage {
        fetchCursors.append(cursor)
        return try await base.fetch(after: cursor)
    }
}

private actor PausingPublishTransport: SyncTransport {
    nonisolated let scope: String
    private let base: InMemorySyncTransport
    private var pauseNext = true
    private var publishStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    init(base: InMemorySyncTransport) {
        self.base = base
        scope = base.scope
    }

    func bootstrap(proposing record: SyncRecord) async throws -> SyncRecord {
        try await base.bootstrap(proposing: record)
    }

    func publish(_ record: SyncRecord) async throws {
        if pauseNext {
            pauseNext = false
            publishStarted = true
            let waiters = startWaiters
            startWaiters = []
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { continuation in
                resumeContinuation = continuation
            }
        }
        try await base.publish(record)
    }

    func fetch(after cursor: String?) async throws -> SyncPage {
        try await base.fetch(after: cursor)
    }

    func waitUntilPublishStarts() async {
        if publishStarted { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resumePublish() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private actor FailingFetchTransport: SyncTransport {
    nonisolated let scope: String
    private let base: InMemorySyncTransport

    init(base: InMemorySyncTransport) {
        self.base = base
        scope = base.scope
    }

    func bootstrap(proposing record: SyncRecord) async throws -> SyncRecord {
        try await base.bootstrap(proposing: record)
    }

    func publish(_ record: SyncRecord) async throws {
        try await base.publish(record)
    }

    func fetch(after cursor: String?) throws -> SyncPage {
        throw SyncError.unavailable("Interrupted before first checkpoint")
    }
}
