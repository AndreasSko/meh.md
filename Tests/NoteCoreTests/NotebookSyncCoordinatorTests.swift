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
        let log = NotebookSyncEventLog(directory: root)
        await NotebookSyncCoordinator(
            replica: NotebookReplica(directory: root),
            transport: recording,
            diagnosticLog: log
        ).synchronize()

        let cursors = await recording.fetchCursors
        XCTAssertEqual(try XCTUnwrap(cursors.first), nil)
        XCTAssertTrue(log.entries.contains { $0.event == "replay_missing_history" })
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
        XCTAssertEqual(try XCTUnwrap(cursors.first), nil)
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

    func testUploadsNotesInChunksBeforeCatalog() async throws {
        let base = InMemorySyncTransport(scope: "batch-order")
        let transport = BatchRecordingTransport(base: base)
        let replica = NotebookReplica(directory: directory())
        let coordinator = NotebookSyncCoordinator(replica: replica, transport: transport)
        await coordinator.synchronize()
        await transport.clearBatches()
        for index in 0..<51 {
            _ = try await replica.createNote(name: "\(index).md", text: "\(index)")
        }

        await coordinator.synchronize()

        let batches = await transport.recordedBatches()
        XCTAssertEqual(batches.map(\.count), [50, 1, 1])
        guard batches.count == 3 else { return }
        XCTAssertTrue(batches[0].allSatisfy { $0.kind == .note })
        XCTAssertTrue(batches[1].allSatisfy { $0.kind == .note })
        XCTAssertEqual(batches[2].map(\.kind), [.catalog])
        assertExchanged(coordinator.status)
    }

    func testPartialAcknowledgementCheckpointsBeforeErrorAndRestart() async throws {
        let base = InMemorySyncTransport(scope: "partial-batch")
        let transport = BatchRecordingTransport(base: base)
        let root = directory()
        let replica = NotebookReplica(directory: root)
        let coordinator = NotebookSyncCoordinator(replica: replica, transport: transport)
        await coordinator.synchronize()
        var noteIDs: [UUID] = []
        for index in 0..<3 {
            noteIDs.append(
                try await replica.createNote(name: "\(index).md", text: "\(index)")
            )
        }
        await transport.clearBatches()
        await transport.failNextNoteBatchPartially()

        await coordinator.synchronize()

        guard case .failed = coordinator.status else {
            return XCTFail("Expected the partial batch error")
        }
        XCTAssertEqual(coordinator.progress?.completedNotes, 1)
        XCTAssertEqual(coordinator.progress?.totalNotes, 3)
        let recorded = await transport.recordedBatches()
        let firstBatch = try XCTUnwrap(recorded.first)
        let acknowledged = try XCTUnwrap(firstBatch.first)
        let state = try JSONDecoder().decode(
            NotebookSyncState.self,
            from: Data(contentsOf: root.appending(path: "notebook-sync-state.json"))
        )
        XCTAssertEqual(
            state.acknowledgedHeads[acknowledged.documentKey],
            acknowledged.snapshot.heads
        )
        XCTAssertEqual(noteIDs.count, 3)

        await transport.clearBatches()
        await coordinator.synchronize()

        let retriedNotes = await transport.recordedBatches().flatMap { $0 }
            .filter { $0.kind == .note }
        XCTAssertEqual(retriedNotes.count, 2)
        XCTAssertFalse(retriedNotes.contains { $0.id == acknowledged.id })
        assertExchanged(coordinator.status)
    }

    func testDiagnosticLogExplainsPendingHeadsAndPartialRetry() async throws {
        let base = InMemorySyncTransport(scope: "diagnostic-retry")
        let transport = BatchRecordingTransport(base: base)
        let root = directory()
        let replica = NotebookReplica(directory: root)
        let log = NotebookSyncEventLog(directory: root)
        let coordinator = NotebookSyncCoordinator(
            replica: replica,
            transport: transport,
            diagnosticLog: log
        )
        await coordinator.synchronize()
        log.clear()
        _ = try await replica.createNote(name: "one.md", text: "one")
        _ = try await replica.createNote(name: "two.md", text: "two")
        await transport.failNextNoteBatchPartially()

        await coordinator.synchronize()

        let pending = try XCTUnwrap(
            log.entries.first { $0.event == "pending_notes" }
        )
        XCTAssertEqual(pending.counts["total"], 2)
        XCTAssertEqual(pending.counts["noAcknowledgement"], 2)
        XCTAssertEqual(
            pending.counts["matchingAppliedWithoutAcknowledgement"],
            2
        )
        let failedBatch = try XCTUnwrap(
            log.entries.first { $0.event == "note_batch_result" }
        )
        XCTAssertEqual(failedBatch.counts["acknowledged"], 1)
        XCTAssertEqual(failedBatch.counts["error"], 1)
        XCTAssertTrue(log.entries.contains { $0.event.hasPrefix("pass_error:") })

        log.clear()
        await coordinator.synchronize()

        let retryCheckpoint = try XCTUnwrap(
            log.entries.first { $0.event == "checkpoints_loaded" }
        )
        XCTAssertGreaterThanOrEqual(
            retryCheckpoint.counts["acknowledgedDocuments"] ?? 0,
            1
        )
        let retryBatch = try XCTUnwrap(
            log.entries.first { $0.event == "note_batch_result" }
        )
        XCTAssertEqual(retryBatch.counts["requested"], 1)
        XCTAssertEqual(retryBatch.counts["acknowledged"], 1)
        XCTAssertTrue(log.entries.contains { $0.event == "pass_end" })
        assertExchanged(coordinator.status)
    }

    func testCatalogFailureRetainsCompletedNoteProgress() async throws {
        let base = InMemorySyncTransport(scope: "catalog-failure")
        let transport = BatchRecordingTransport(base: base)
        let replica = NotebookReplica(directory: directory())
        let coordinator = NotebookSyncCoordinator(replica: replica, transport: transport)
        await coordinator.synchronize()
        _ = try await replica.createNote(name: "one.md", text: "one")
        _ = try await replica.createNote(name: "two.md", text: "two")
        await transport.failNextCatalogBatch()

        await coordinator.synchronize()

        guard case .failed = coordinator.status else {
            return XCTFail("Expected catalog publication to fail")
        }
        XCTAssertEqual(coordinator.progress?.phase, .uploadingCatalog)
        XCTAssertEqual(coordinator.progress?.completedNotes, 2)
        XCTAssertEqual(coordinator.progress?.totalNotes, 2)
    }

    func testProgressTracksChunkAcknowledgementsAndClearsOnSuccess() async throws {
        let base = InMemorySyncTransport(scope: "batch-progress")
        let transport = PausingBatchTransport(base: base)
        let replica = NotebookReplica(directory: directory())
        let coordinator = NotebookSyncCoordinator(replica: replica, transport: transport)
        await coordinator.synchronize()
        for index in 0..<51 {
            _ = try await replica.createNote(name: "\(index).md", text: "\(index)")
        }
        await transport.startPausing()

        let synchronization = Task { await coordinator.synchronize() }
        await transport.waitForBatch(1)
        let first = try XCTUnwrap(coordinator.progress)
        XCTAssertEqual(first.phase, .uploadingNotes)
        XCTAssertEqual(first.completedNotes, 0)
        XCTAssertEqual(first.totalNotes, 51)
        await transport.resumeBatch()

        await transport.waitForBatch(2)
        let second = try XCTUnwrap(coordinator.progress)
        XCTAssertEqual(second.completedNotes, 50)
        XCTAssertGreaterThanOrEqual(second.lastProgressAt, first.lastProgressAt)
        await transport.resumeBatch()

        await transport.waitForBatch(3)
        let catalog = try XCTUnwrap(coordinator.progress)
        XCTAssertEqual(catalog.phase, .uploadingCatalog)
        XCTAssertEqual(catalog.completedNotes, 51)
        XCTAssertGreaterThanOrEqual(catalog.lastProgressAt, second.lastProgressAt)
        await transport.resumeBatch()
        await synchronization.value

        XCTAssertNil(coordinator.progress)
        assertExchanged(coordinator.status)
    }

    func testCheckingAndReceivingProgressAreIndeterminate() async throws {
        let base = InMemorySyncTransport(scope: "phase-progress")
        let transport = PhasePausingTransport(base: base)
        let coordinator = NotebookSyncCoordinator(
            replica: NotebookReplica(directory: directory()),
            transport: transport
        )

        let synchronization = Task { await coordinator.synchronize() }
        await transport.waitForBootstrap()
        let checking = try XCTUnwrap(coordinator.progress)
        XCTAssertEqual(checking.phase, .checking)
        XCTAssertEqual(checking.totalNotes, 0)
        await transport.resumeBootstrap()

        await transport.waitForFetch()
        let receiving = try XCTUnwrap(coordinator.progress)
        XCTAssertEqual(receiving.phase, .receiving)
        XCTAssertEqual(receiving.totalNotes, 0)
        XCTAssertGreaterThanOrEqual(receiving.lastProgressAt, checking.lastProgressAt)
        await transport.resumeFetch()
        await synchronization.value

        XCTAssertNil(coordinator.progress)
        assertExchanged(coordinator.status)
    }

    func testRetryResetsFailureCountsBeforeCheckingAndReceiving() async throws {
        let base = InMemorySyncTransport(scope: "retry-progress")
        let transport = PhasePausingTransport(
            base: base,
            pausesImmediately: false
        )
        let replica = NotebookReplica(directory: directory())
        let coordinator = NotebookSyncCoordinator(replica: replica, transport: transport)
        await coordinator.synchronize()
        _ = try await replica.createNote(name: "one.md", text: "one")
        _ = try await replica.createNote(name: "two.md", text: "two")
        await transport.failNextNoteBatchPartially()
        await coordinator.synchronize()
        XCTAssertEqual(coordinator.progress?.completedNotes, 1)
        XCTAssertEqual(coordinator.progress?.totalNotes, 2)

        await transport.pauseNextPhases()
        let retry = Task { await coordinator.synchronize() }
        await transport.waitForBootstrap()
        XCTAssertEqual(coordinator.progress?.phase, .checking)
        XCTAssertEqual(coordinator.progress?.receivedRecords, 0)
        XCTAssertEqual(coordinator.progress?.completedNotes, 0)
        XCTAssertEqual(coordinator.progress?.totalNotes, 0)
        await transport.resumeBootstrap()

        await transport.waitForFetch()
        XCTAssertEqual(coordinator.progress?.phase, .receiving)
        XCTAssertEqual(coordinator.progress?.receivedRecords, 0)
        XCTAssertEqual(coordinator.progress?.completedNotes, 0)
        XCTAssertEqual(coordinator.progress?.totalNotes, 0)
        await transport.resumeFetch()
        await retry.value

        XCTAssertNil(coordinator.progress)
        assertExchanged(coordinator.status)
    }

    func testFetchedExactRevisionIsNotPublishedAgain() async throws {
        let notebookID = UUID()
        let seed = try NotebookCatalogDocument(notebookID: notebookID)
        let note = try NoteDocument(text: "remote")
        let catalog = try seed.fork()
        try catalog.add(id: note.noteID, kind: .note, name: "remote.md")
        let transport = RemoteBatchRecordingTransport(
            seed: SyncRecord(catalog: seed.snapshot()),
            records: [
                SyncRecord(snapshot: note.snapshot(), notebookID: notebookID),
                SyncRecord(catalog: catalog.snapshot()),
            ]
        )
        let coordinator = NotebookSyncCoordinator(
            replica: NotebookReplica(directory: directory()),
            transport: transport
        )

        await coordinator.synchronize()

        let publishedRecordCount = await transport.publishedRecordCount()
        XCTAssertEqual(publishedRecordCount, 0)
        assertExchanged(coordinator.status)
    }

    func testFetchedRevisionMergedWithLocalEditIsPublished() async throws {
        let store = InMemorySyncStore()
        let base = InMemorySyncTransport(scope: "merged-fetch", store: store)
        let left = NotebookReplica(directory: directory())
        let right = NotebookReplica(directory: directory())
        let leftSync = NotebookSyncCoordinator(replica: left, transport: base)
        let rightSync = NotebookSyncCoordinator(replica: right, transport: base)
        await leftSync.synchronize()
        let noteID = try await left.createNote(name: "note.md", text: "original")
        await leftSync.synchronize()
        await rightSync.synchronize()

        let leftEditor = try await left.openNote(noteID)
        try leftEditor.replaceAll(with: "left")
        try await leftEditor.flush()
        let rightEditor = try await right.openNote(noteID)
        try rightEditor.replaceAll(with: "right")
        try await rightEditor.flush()
        await rightSync.synchronize()
        let rightRecords = try await right.records()
        let remoteHeads = try XCTUnwrap(
            rightRecords.first { $0.snapshot.noteID == noteID }?.snapshot.heads
        )

        let recording = BatchRecordingTransport(base: base)
        await NotebookSyncCoordinator(replica: left, transport: recording).synchronize()

        let publishedNotes = await recording.recordedBatches().flatMap { $0 }
            .filter { $0.kind == .note }
        XCTAssertEqual(publishedNotes.count, 1)
        let publishedNote = try XCTUnwrap(publishedNotes.first)
        XCTAssertNotEqual(publishedNote.snapshot.heads, remoteHeads)
    }

    func testUnexpectedAcknowledgementDoesNotCheckpointBatch() async throws {
        let base = InMemorySyncTransport(scope: "unexpected-ack")
        let transport = BatchRecordingTransport(base: base)
        let root = directory()
        let replica = NotebookReplica(directory: root)
        let coordinator = NotebookSyncCoordinator(replica: replica, transport: transport)
        await coordinator.synchronize()
        let noteID = try await replica.createNote(name: "note.md", text: "note")
        await transport.returnUnexpectedAcknowledgement()

        await coordinator.synchronize()

        guard case .failed = coordinator.status else {
            return XCTFail("Expected an invalid acknowledgement failure")
        }
        let state = try JSONDecoder().decode(
            NotebookSyncState.self,
            from: Data(contentsOf: root.appending(path: "notebook-sync-state.json"))
        )
        XCTAssertNil(state.acknowledgedHeads["note:\(noteID.uuidString)"])
        XCTAssertEqual(coordinator.progress?.completedNotes, 0)
    }

    func testUnacknowledgedBatchWithoutErrorFailsAsIncomplete() async throws {
        let base = InMemorySyncTransport(scope: "missing-ack")
        let transport = BatchRecordingTransport(base: base)
        let replica = NotebookReplica(directory: directory())
        let coordinator = NotebookSyncCoordinator(replica: replica, transport: transport)
        await coordinator.synchronize()
        _ = try await replica.createNote(name: "note.md", text: "note")
        await transport.returnNoAcknowledgements()

        await coordinator.synchronize()

        guard case .failed(let message) = coordinator.status else {
            return XCTFail("Expected an incomplete acknowledgement failure")
        }
        XCTAssertTrue(message.contains("did not acknowledge"))
        XCTAssertEqual(coordinator.progress?.completedNotes, 0)
        XCTAssertEqual(coordinator.progress?.totalNotes, 1)
    }

    func testDeletionWhileFirstChunkUploadsSkipsQueuedBody() async throws {
        let base = InMemorySyncTransport(scope: "delete-during-batch")
        let transport = PausingBatchTransport(base: base)
        let replica = NotebookReplica(directory: directory())
        let coordinator = NotebookSyncCoordinator(replica: replica, transport: transport)
        await coordinator.synchronize()
        for index in 0..<51 {
            _ = try await replica.createNote(name: "\(index).md", text: "\(index)")
        }
        await transport.startPausing()

        let synchronization = Task { await coordinator.synchronize() }
        await transport.waitForBatch(1)
        let firstBatch = await transport.currentPausedBatch()
        let firstIDs = Set(firstBatch.map { $0.snapshot.noteID })
        let outgoing = try await replica.records()
        let queued = try XCTUnwrap(outgoing.first {
            $0.kind == .note && !firstIDs.contains($0.snapshot.noteID)
        })
        try await replica.markPermanentlyDeleted([queued.snapshot.noteID])
        await transport.resumeBatch()

        await transport.waitForBatch(2)
        let secondBatch = await transport.currentPausedBatch()
        XCTAssertEqual(secondBatch.map(\.kind), [.catalog])
        XCTAssertEqual(coordinator.progress?.phase, .uploadingCatalog)
        XCTAssertEqual(coordinator.progress?.completedNotes, 50)
        XCTAssertEqual(coordinator.progress?.totalNotes, 50)
        await transport.resumeBatch()
        await synchronization.value

        let publishedIDs = await transport.publishedIDs()
        XCTAssertFalse(publishedIDs.contains(queued.id))
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

private actor BatchRecordingTransport: SyncTransport {
    nonisolated let scope: String
    private let base: InMemorySyncTransport
    private var batches: [[SyncRecord]] = []
    private var partialNoteFailure = false
    private var catalogFailure = false
    private var unexpectedAcknowledgement = false
    private var missingAcknowledgements = false

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

    func publishBatch(_ records: [SyncRecord]) async throws -> SyncBatchResult {
        batches.append(records)
        if partialNoteFailure, records.first?.kind == .note {
            partialNoteFailure = false
            guard let first = records.first else {
                return SyncBatchResult(acknowledgedIDs: [], error: BatchTestError.failed)
            }
            try await base.publish(first)
            return SyncBatchResult(
                acknowledgedIDs: [first.id],
                error: BatchTestError.failed
            )
        }
        if catalogFailure, records.first?.kind == .catalog {
            catalogFailure = false
            return SyncBatchResult(acknowledgedIDs: [], error: BatchTestError.failed)
        }
        if unexpectedAcknowledgement, records.first?.kind == .note {
            unexpectedAcknowledgement = false
            return SyncBatchResult(
                acknowledgedIDs: Set(records.map(\.id)).union(["unexpected"]),
                error: nil
            )
        }
        if missingAcknowledgements, records.first?.kind == .note {
            missingAcknowledgements = false
            return SyncBatchResult(acknowledgedIDs: [], error: nil)
        }
        return try await base.publishBatch(records)
    }

    func fetch(after cursor: String?) async throws -> SyncPage {
        try await base.fetch(after: cursor)
    }

    func recordedBatches() -> [[SyncRecord]] { batches }
    func clearBatches() { batches = [] }
    func failNextNoteBatchPartially() { partialNoteFailure = true }
    func failNextCatalogBatch() { catalogFailure = true }
    func returnUnexpectedAcknowledgement() { unexpectedAcknowledgement = true }
    func returnNoAcknowledgements() { missingAcknowledgements = true }
}

private actor PausingBatchTransport: SyncTransport {
    nonisolated let scope: String
    private let base: InMemorySyncTransport
    private var shouldPause = false
    private var pausedBatchCount = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?
    private var pausedBatch: [SyncRecord] = []
    private var published: Set<String> = []

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

    func publishBatch(_ records: [SyncRecord]) async throws -> SyncBatchResult {
        if shouldPause {
            pausedBatchCount += 1
            pausedBatch = records
            let ready = waiters.filter { $0.0 <= pausedBatchCount }
            waiters.removeAll { $0.0 <= pausedBatchCount }
            for (_, waiter) in ready { waiter.resume() }
            await withCheckedContinuation { continuation in
                resumeContinuation = continuation
            }
        }
        let result = try await base.publishBatch(records)
        published.formUnion(result.acknowledgedIDs)
        return result
    }

    func fetch(after cursor: String?) async throws -> SyncPage {
        try await base.fetch(after: cursor)
    }

    func startPausing() {
        shouldPause = true
        pausedBatchCount = 0
    }

    func waitForBatch(_ number: Int) async {
        if pausedBatchCount >= number { return }
        await withCheckedContinuation { continuation in
            waiters.append((number, continuation))
        }
    }

    func resumeBatch() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }

    func currentPausedBatch() -> [SyncRecord] { pausedBatch }
    func publishedIDs() -> Set<String> { published }
}

private actor RemoteBatchRecordingTransport: SyncTransport {
    nonisolated let scope = "remote-exact"
    private let seed: SyncRecord
    private let records: [SyncRecord]
    private var published = 0

    init(seed: SyncRecord, records: [SyncRecord]) {
        self.seed = seed
        self.records = records
    }

    func bootstrap(proposing record: SyncRecord) -> SyncRecord { seed }
    func publish(_ record: SyncRecord) { published += 1 }

    func publishBatch(_ records: [SyncRecord]) -> SyncBatchResult {
        published += records.count
        return SyncBatchResult(
            acknowledgedIDs: Set(records.map(\.id)),
            error: nil
        )
    }

    func fetch(after cursor: String?) -> SyncPage {
        SyncPage(records: cursor == nil ? records : [], cursor: "done", hasMore: false)
    }

    func publishedRecordCount() -> Int { published }
}

private actor PhasePausingTransport: SyncTransport {
    nonisolated let scope: String
    private let base: InMemorySyncTransport
    private var bootstrapStarted = false
    private var fetchStarted = false
    private var bootstrapWaiters: [CheckedContinuation<Void, Never>] = []
    private var fetchWaiters: [CheckedContinuation<Void, Never>] = []
    private var bootstrapContinuation: CheckedContinuation<Void, Never>?
    private var fetchContinuation: CheckedContinuation<Void, Never>?
    private var shouldPauseBootstrap: Bool
    private var shouldPauseFetch: Bool
    private var partialNoteFailure = false

    init(base: InMemorySyncTransport, pausesImmediately: Bool = true) {
        self.base = base
        scope = base.scope
        shouldPauseBootstrap = pausesImmediately
        shouldPauseFetch = pausesImmediately
    }

    func bootstrap(proposing record: SyncRecord) async throws -> SyncRecord {
        if shouldPauseBootstrap {
            shouldPauseBootstrap = false
            bootstrapStarted = true
            for waiter in bootstrapWaiters { waiter.resume() }
            bootstrapWaiters = []
            await withCheckedContinuation { continuation in
                bootstrapContinuation = continuation
            }
        }
        return try await base.bootstrap(proposing: record)
    }

    func publish(_ record: SyncRecord) async throws {
        try await base.publish(record)
    }

    func publishBatch(_ records: [SyncRecord]) async throws -> SyncBatchResult {
        if partialNoteFailure, records.first?.kind == .note {
            partialNoteFailure = false
            guard let first = records.first else {
                return SyncBatchResult(acknowledgedIDs: [], error: BatchTestError.failed)
            }
            try await base.publish(first)
            return SyncBatchResult(
                acknowledgedIDs: [first.id],
                error: BatchTestError.failed
            )
        }
        return try await base.publishBatch(records)
    }

    func fetch(after cursor: String?) async throws -> SyncPage {
        if shouldPauseFetch {
            shouldPauseFetch = false
            fetchStarted = true
            for waiter in fetchWaiters { waiter.resume() }
            fetchWaiters = []
            await withCheckedContinuation { continuation in
                fetchContinuation = continuation
            }
        }
        return try await base.fetch(after: cursor)
    }

    func waitForBootstrap() async {
        if bootstrapStarted { return }
        await withCheckedContinuation { continuation in
            bootstrapWaiters.append(continuation)
        }
    }

    func resumeBootstrap() {
        bootstrapContinuation?.resume()
        bootstrapContinuation = nil
    }

    func waitForFetch() async {
        if fetchStarted { return }
        await withCheckedContinuation { continuation in
            fetchWaiters.append(continuation)
        }
    }

    func resumeFetch() {
        fetchContinuation?.resume()
        fetchContinuation = nil
    }

    func failNextNoteBatchPartially() { partialNoteFailure = true }

    func pauseNextPhases() {
        bootstrapStarted = false
        fetchStarted = false
        shouldPauseBootstrap = true
        shouldPauseFetch = true
    }
}

private enum BatchTestError: Error {
    case failed
}
