import Foundation
import XCTest

@testable import NoteCore
@testable import NotebookAppModel
import TestSupport

@MainActor
final class NotebookWorkspaceSchedulingTests: XCTestCase {
    private let clock = ManualClock()

    func testActualScenePhasesAreLoggedOnceWithoutRefreshReasons() {
        let workspace = makeWorkspace(
            transport: RecordingTransport(scope: "scene-phases"),
            automaticSync: false
        )
        let scene = UUID()
        workspace.sceneActivityChanged(id: scene, phase: .active)
        workspace.sceneActivityChanged(id: scene, phase: .inactive)
        workspace.sceneActivityChanged(id: scene, phase: .inactive)
        workspace.sceneActivityChanged(id: scene, phase: .background)
        workspace.sceneDidClose(id: scene)
        workspace.sceneDidClose(id: scene)

        XCTAssertEqual(workspace.syncEventLog.entries.map(\.event), [
            "scene phase changed: active",
            "scene phase changed: inactive",
            "scene phase changed: background",
            "scene closed"
        ])
        XCTAssertFalse(workspace.syncEventLog.entries.contains {
            $0.event.contains(scene.uuidString)
        })
    }

    func testScenePhaseDiagnosticsCountAllActiveWindows() {
        let workspace = makeWorkspace(
            transport: RecordingTransport(scope: "phase-counts"),
            automaticSync: false
        )
        let firstScene = UUID()
        let secondScene = UUID()
        workspace.sceneActivityChanged(id: firstScene, phase: .active)
        workspace.sceneActivityChanged(id: secondScene, phase: .active)
        workspace.sceneActivityChanged(id: firstScene, phase: .background)
        workspace.sceneDidClose(id: secondScene)

        XCTAssertEqual(workspace.syncEventLog.entries.map {
            $0.counts["active_scenes"]
        }, [1, 2, 1, 0])
    }

    func testForegroundResumptionRecordsUnfinishedManualSync() async throws {
        let transport = RecordingTransport(scope: "foreground-resumption")
        let workspace = makeWorkspace(
            transport: transport, automaticSync: false
        )
        let scene = UUID()
        workspace.sceneActivityChanged(id: scene, phase: .active)
        await workspace.start()
        await transport.pauseNextFetch()
        let exchange = Task { await workspace.refresh(manual: true) }
        try await waitUntil { await transport.isFetchPaused }

        workspace.sceneActivityChanged(id: scene, phase: .inactive)
        workspace.sceneActivityChanged(id: scene, phase: .background)
        workspace.sceneActivityChanged(id: scene, phase: .active)
        workspace.sceneActivityChanged(id: UUID(), phase: .active)
        let resumptions = workspace.syncEventLog.entries.filter {
            $0.event.hasPrefix("foreground resumed unfinished sync: ")
        }
        XCTAssertEqual(resumptions.count, 1)
        XCTAssertEqual(resumptions.first?.event,
                       "foreground resumed unfinished sync: receiving")
        XCTAssertGreaterThanOrEqual(resumptions.first?.counts["elapsed_ms"] ?? -1, 0)

        await transport.resumeFetch()
        await exchange.value
        workspace.sceneActivityChanged(id: scene, phase: .background)
        workspace.sceneActivityChanged(id: scene, phase: .active)
        XCTAssertEqual(workspace.syncEventLog.entries.filter {
            $0.event.hasPrefix("foreground resumed unfinished sync: ")
        }.count, 1)
    }

    func testSavedEditsCoalesceIntoOneAutomaticExchange() async throws {
        let transport = RecordingTransport(scope: "coalesced")
        let workspace = makeWorkspace(transport: transport)
        workspace.sceneActivityChanged(id: UUID(), isActive: true)
        await workspace.start()
        let baselineFetches = await transport.fetchCount

        _ = try await workspace.replica?.createNote(
            name: "first.md", text: "first"
        )
        workspace.contentDidSave(trigger: "first save")
        _ = try await workspace.replica?.createNote(
            name: "second.md", text: "second"
        )
        workspace.contentDidSave(trigger: "second save")
        XCTAssertTrue(workspace.hasPendingRefresh)

        clock.advance(by: .seconds(1))
        try await waitUntil {
            await transport.fetchCount > baselineFetches
                && !workspace.isRefreshing && !workspace.hasPendingRefresh
        }
        let fetches = await transport.fetchCount
        XCTAssertEqual(fetches, baselineFetches + 1)
    }

    func testAutomaticSyncOptOutRequiresManualRefresh() async throws {
        let transport = RecordingTransport(scope: "manual")
        let workspace = makeWorkspace(
            transport: transport, automaticSync: false
        )
        await workspace.start()
        let baseline = await transport.operationCount

        _ = try await workspace.replica?.createNote(
            name: "manual.md", text: "manual"
        )
        workspace.contentDidSave()
        // With automatic sync off, the timer only publishes Markdown copies.
        XCTAssertTrue(workspace.hasPendingRefresh)
        clock.advance(by: .seconds(60))
        try await waitUntil {
            guard let copies = workspace.copiesURL else { return false }
            return FileManager.default.fileExists(
                atPath: copies.appending(path: "manual.md").path
            )
        }

        let operationsBeforeManualRefresh = await transport.operationCount
        XCTAssertEqual(operationsBeforeManualRefresh, baseline)
        await workspace.refresh(manual: true)
        let operationsAfterManualRefresh = await transport.operationCount
        XCTAssertGreaterThan(operationsAfterManualRefresh, baseline)
    }

    func testTransientFailureUsesTransportRetryDeadline() async throws {
        let serverDeadline = Date().addingTimeInterval(30)
        let transport = FailingTransport(
            scope: "retry", retryNotBefore: serverDeadline
        )
        let workspace = makeWorkspace(transport: transport)

        await workspace.start()

        let deadline = try XCTUnwrap(workspace.syncRetryNotBefore)
        XCTAssertGreaterThanOrEqual(deadline, serverDeadline)
        await workspace.refresh()
        let bootstrapCount = await transport.bootstrapCount
        XCTAssertEqual(bootstrapCount, 1)
    }

    func testPrestartCooldownReadsCannotPostponeTransportCreation()
        async throws {
        let transport = RecordingTransport(scope: "startup-cooldown")
        var attempts = 0
        let root = temporaryDirectory()
        let workspace = NotebookWorkspace(
            directory: root.appending(path: "Notebook"),
            documentsDirectory: root.appending(path: "Documents"),
            transport: nil, automaticSync: true, mode: .cloud,
            transportFactory: { _ in
                attempts += 1
                if attempts == 1 { throw SyncError.scopeChanged }
                return transport
            }
        )
        let cloudDirectory = workspace.directory.appending(path: "CloudKit")
        var cooldown = try CloudKitAvailabilityCooldownStore(
            directory: cloudDirectory
        )
        try cooldown.merge(retryAfter: 30, now: Date())

        await workspace.start()
        XCTAssertEqual(attempts, 1)
        XCTAssertNil(workspace.sync)
        _ = try CloudKitSyncTransport.persistedRetryNotBefore(
            stateDirectory: cloudDirectory
        )
        _ = try CloudKitSyncTransport.persistedRetryNotBefore(
            stateDirectory: cloudDirectory
        )

        await workspace.refresh()

        XCTAssertEqual(attempts, 2)
        XCTAssertNotNil(workspace.sync)
    }

    func testBackgroundFlushesOnceAndForegroundResumes() async throws {
        let transport = RecordingTransport(scope: "foreground")
        let workspace = makeWorkspace(transport: transport)
        let sceneID = UUID()
        workspace.sceneActivityChanged(id: sceneID, isActive: true)
        await workspace.start()
        let baselineFetches = await transport.fetchCount

        _ = try await workspace.replica?.createNote(
            name: "paused.md", text: "paused"
        )
        workspace.noteDidEdit()
        workspace.contentDidSave()
        workspace.sceneActivityChanged(id: sceneID, isActive: false)
        try await waitUntil {
            await transport.fetchCount > baselineFetches
                && !workspace.isRefreshing && !workspace.hasPendingRefresh
        }
        let backgroundFetches = await transport.fetchCount

        workspace.sceneActivityChanged(id: sceneID, isActive: false)
        XCTAssertFalse(workspace.isRefreshing)
        XCTAssertFalse(workspace.hasPendingRefresh)
        let repeatedBackgroundFetches = await transport.fetchCount
        XCTAssertEqual(repeatedBackgroundFetches, backgroundFetches)

        // The resumed exchange waits for the idle delay after the edit.
        workspace.sceneActivityChanged(id: sceneID, isActive: true)
        clock.advance(by: .seconds(10))
        try await waitUntil {
            await transport.fetchCount > backgroundFetches
        }
    }

    func testOneInactiveSceneDoesNotBackgroundActiveScene() async throws {
        let transport = RecordingTransport(scope: "multiple-scenes")
        let workspace = makeWorkspace(transport: transport)
        let firstScene = UUID()
        let secondScene = UUID()
        workspace.sceneActivityChanged(id: firstScene, isActive: true)
        workspace.sceneActivityChanged(id: secondScene, isActive: true)
        await workspace.start()
        let baselineFetches = await transport.fetchCount

        workspace.sceneActivityChanged(id: firstScene, isActive: false)
        workspace.sceneDidClose(id: firstScene)
        XCTAssertFalse(workspace.isRefreshing)
        XCTAssertFalse(workspace.hasPendingRefresh)
        let fetchesWhileActive = await transport.fetchCount
        XCTAssertEqual(fetchesWhileActive, baselineFetches)

        workspace.sceneDidClose(id: secondScene)
        try await waitUntil {
            await transport.fetchCount > baselineFetches
        }
    }

    func testAdditionalWindowStartDoesNotRefreshAgain() async throws {
        let transport = RecordingTransport(scope: "additional-window")
        let workspace = makeWorkspace(transport: transport)
        await workspace.start()
        let baselineFetches = await transport.fetchCount

        await workspace.start()

        let fetches = await transport.fetchCount
        XCTAssertEqual(fetches, baselineFetches)
    }

    func testBackgroundLaunchDefersScheduledWorkUntilSceneActivates() async throws {
        let transport = RecordingTransport(scope: "background-launch")
        let workspace = makeWorkspace(transport: transport)
        await workspace.start()
        let baselineFetches = await transport.fetchCount

        workspace.contentDidSave()
        XCTAssertFalse(workspace.hasPendingRefresh)
        let backgroundFetches = await transport.fetchCount
        XCTAssertEqual(backgroundFetches, baselineFetches)

        workspace.sceneActivityChanged(id: UUID(), isActive: true)
        clock.advance(by: .seconds(1))
        try await waitUntil {
            await transport.fetchCount > baselineFetches
        }
    }

    func testCloudFailureDoesNotEchoButRemoteChangesReconcile() async throws {
        let transport = RecordingTransport(scope: "cloud-activity")
        let workspace = makeWorkspace(transport: transport)
        workspace.sceneActivityChanged(id: UUID(), isActive: true)
        await workspace.start()
        let baselineOperations = await transport.operationCount
        let baselineFetches = await transport.fetchCount

        await workspace.receiveCloudActivity(.failed("Account changed"))
        await workspace.receiveCloudActivity(.failed("Account changed"))

        XCTAssertFalse(workspace.isRefreshing)
        XCTAssertFalse(workspace.hasPendingRefresh)
        let operationsAfterFailures = await transport.operationCount
        XCTAssertEqual(operationsAfterFailures, baselineOperations)
        XCTAssertEqual(workspace.syncSetupError, "Account changed")

        await workspace.receiveCloudActivity(
            .remoteChanges(recordCount: 1, deletionCount: 0, reason: .scheduled)
        )

        clock.advance(by: .seconds(1))
        try await waitUntil {
            await transport.fetchCount > baselineFetches
                && !workspace.isRefreshing && !workspace.hasPendingRefresh
        }
        let fetchesAfterRemoteChanges = await transport.fetchCount
        XCTAssertEqual(fetchesAfterRemoteChanges, baselineFetches + 1)
        XCTAssertTrue(workspace.syncEventLog.entries.contains {
            $0.event == "cloud scheduled changes delivered"
        })
    }

    func testTypingDefersSavesAndCloudEventsButManualSyncIsImmediate() async throws {
        let transport = RecordingTransport(scope: "typing")
        let workspace = makeWorkspace(transport: transport)
        workspace.sceneActivityChanged(id: UUID(), isActive: true)
        await workspace.start()
        let baseline = await transport.fetchCount
        workspace.noteDidEdit()
        workspace.contentDidSave()
        await workspace.receiveCloudActivity(
            .remoteChanges(recordCount: 1, deletionCount: 0, reason: .scheduled)
        )
        // The ten-second idle delay after typing has not passed yet.
        try await waitUntil { self.clock.sleeperCount == 1 }
        XCTAssertEqual(clock.advance(by: .seconds(9)), 0)
        XCTAssertTrue(workspace.hasPendingRefresh)
        let deferred = await transport.fetchCount
        XCTAssertEqual(deferred, baseline)
        await workspace.refresh(manual: true)
        let manual = await transport.fetchCount
        XCTAssertEqual(manual, baseline + 1)
    }

    func testManualRequestDuringExchangeRunsImmediateFollowUp() async throws {
        let transport = RecordingTransport(scope: "in-flight")
        let workspace = makeWorkspace(transport: transport)
        workspace.sceneActivityChanged(id: UUID(), isActive: true)
        await workspace.start()
        let baseline = await transport.fetchCount
        await transport.pauseNextFetch()
        let exchange = Task { await workspace.refresh(manual: true) }
        try await waitUntil { await transport.isFetchPaused }
        workspace.noteDidEdit()
        workspace.contentDidSave()
        await workspace.refresh(manual: true)
        await transport.resumeFetch()
        await exchange.value
        try await waitUntil { await transport.fetchCount >= baseline + 2 }
        let fetches = await transport.fetchCount
        XCTAssertEqual(fetches, baseline + 2)
    }

    func testPendingResetRejectsManualAndAutomaticRefresh() async throws {
        let transport = RecordingTransport(scope: "reset-pending")
        let workspace = makeWorkspace(transport: transport)
        workspace.sceneActivityChanged(id: UUID(), isActive: true)
        await workspace.start()
        let replica = try XCTUnwrap(workspace.replica)
        let noteID = try await replica.createNote(name: "draft.md", text: "saved")
        let session = try await replica.openNote(noteID)
        let baseline = await transport.operationCount

        workspace.contentDidSave()
        workspace.localStorageResetWasScheduled()
        XCTAssertTrue(workspace.isResetPending)
        XCTAssertFalse(session.isEditingEnabled)
        do {
            _ = try await replica.createNote(name: "later.md")
            XCTFail("Creating a note after reset scheduling should fail")
        } catch {
            XCTAssertEqual(error as? NotebookReplicaError, .resetPending)
        }
        do {
            _ = try await replica.openNote(noteID)
            XCTFail("Opening a note after reset scheduling should fail")
        } catch {
            XCTAssertEqual(error as? NotebookReplicaError, .resetPending)
        }
        await workspace.refresh(manual: true)
        workspace.requestAutomaticRefresh(trigger: "network restored")
        await workspace.receiveCloudActivity(
            .remoteChanges(recordCount: 1, deletionCount: 0, reason: .scheduled)
        )
        XCTAssertFalse(workspace.hasPendingRefresh)

        let after = await transport.operationCount
        XCTAssertEqual(after, baseline)
    }

    func testLocalModePublishesSavedMarkdownWithoutSync() async throws {
        let transport = RecordingTransport(scope: "local-copies")
        let workspace = makeWorkspace(transport: transport, mode: .local)
        await workspace.start()
        let replica = try XCTUnwrap(workspace.replica)
        let copies = try XCTUnwrap(workspace.copiesURL)
        let noteID = try await replica.createNote(name: "local.md", text: "first")
        workspace.noteDidEdit()
        workspace.contentDidSave()
        clock.advance(by: .seconds(1))
        let copy = copies.appending(path: "local.md")
        try await waitUntil {
            (try? String(contentsOf: copy, encoding: .utf8)) == "first"
        }

        let session = try await replica.openNote(noteID)
        try session.replaceAll(with: "updated")
        workspace.noteDidEdit()
        try await session.flush()
        workspace.contentDidSave()
        clock.advance(by: .seconds(1))
        try await waitUntil {
            (try? String(contentsOf: copy, encoding: .utf8)) == "updated"
        }
        XCTAssertNil(workspace.copyError)
        let operations = await transport.operationCount
        XCTAssertEqual(operations, 0)
    }

    func testPublicationHintsCoalesceAndAutomaticallyPublishSavedWork() async throws {
        let transport = RecordingTransport(scope: "publication-retry")
        let workspace = makeWorkspace(transport: transport)
        workspace.sceneActivityChanged(id: UUID(), isActive: true)
        await workspace.start()
        let baseline = await transport.fetchCount
        let replica = try XCTUnwrap(workspace.replica)
        let noteID = try await replica.createNote(name: "pending.md", text: "durable edit")
        await transport.setRetryDeadline(clock.now().addingTimeInterval(5.3))

        await workspace.receiveCloudActivity(.publicationPending)
        let deadline = try XCTUnwrap(workspace.syncRetryNotBefore)
        await workspace.receiveCloudActivity(.publicationPending)
        let repeatedDeadline = try XCTUnwrap(workspace.syncRetryNotBefore)
        XCTAssertEqual(repeatedDeadline.timeIntervalSince(deadline), 0, accuracy: 0.05)
        await workspace.refresh()
        let beforeDeadline = await transport.fetchCount
        XCTAssertEqual(beforeDeadline, baseline)

        clock.advance(by: .seconds(6))
        try await waitUntil {
            await transport.containsPublishedNote(noteID) && !workspace.isRefreshing
        }
        let fetches = await transport.fetchCount
        XCTAssertEqual(fetches, baseline + 1)
        XCTAssertNil(workspace.syncFailure)
    }

    func testBackgroundPublicationHintResumesAtForegroundWithCooldown() async throws {
        let transport = RecordingTransport(scope: "background-publication")
        let workspace = makeWorkspace(transport: transport)
        await workspace.start()
        let baseline = await transport.fetchCount
        await transport.setRetryDeadline(clock.now().addingTimeInterval(5.3))
        await workspace.receiveCloudActivity(.publicationPending)
        let deadline = try XCTUnwrap(workspace.syncRetryNotBefore)
        XCTAssertFalse(workspace.hasPendingRefresh)
        let background = await transport.fetchCount
        XCTAssertEqual(background, baseline)
        workspace.sceneActivityChanged(id: UUID(), isActive: true)
        await workspace.refresh()
        let beforeDeadline = await transport.fetchCount
        XCTAssertEqual(beforeDeadline, baseline)
        XCTAssertGreaterThan(deadline, clock.now())
        clock.advance(by: .seconds(6))
        try await waitUntil {
            await transport.fetchCount > baseline
        }
    }

    func testPublicationHintHonorsOptOutResetAndStaleGeneration() async throws {
        for automaticSync in [false, true] {
            let transport = RecordingTransport(scope: "guarded-\(automaticSync)")
            let workspace = makeWorkspace(transport: transport, automaticSync: automaticSync)
            await workspace.start()
            let baseline = await transport.operationCount
            if automaticSync {
                await workspace.receiveCloudActivity(.publicationPending, generation: UUID())
                XCTAssertNil(workspace.syncRetryNotBefore)
                workspace.localStorageResetWasScheduled()
            }
            await workspace.receiveCloudActivity(.publicationPending)
            XCTAssertNil(workspace.syncRetryNotBefore)
            let operations = await transport.operationCount
            XCTAssertEqual(operations, baseline)
        }
    }

    func testUnsupportedTransportRejectsPublicationRetry() async throws {
        let transport = RecordingTransport(scope: "unsupported-publication")
        let workspace = makeWorkspace(transport: transport)
        workspace.sceneActivityChanged(id: UUID(), isActive: true)
        await workspace.start()
        await transport.setHalt(SyncHaltStatus(
            reason: .updateRequired,
            underlyingError: SyncError.updateRequired(requiredVersion: 3),
            isRecoverable: false
        ))
        await workspace.receiveCloudActivity(.failed("Update required"))
        let baseline = await transport.operationCount
        await workspace.receiveCloudActivity(.publicationPending)
        XCTAssertTrue(workspace.isSyncUpdateRequired)
        XCTAssertNil(workspace.syncRetryNotBefore)
        let operations = await transport.operationCount
        XCTAssertEqual(operations, baseline)
    }

    func testManualCleanupReceivesFirstAndNewSyncWaitsForCancellation() async throws {
        let transport = RecordingTransport(scope: "fictional-maintenance")
        await transport.enableMaintenance()
        let workspace = makeWorkspace(transport: transport, automaticSync: false)
        workspace.sceneActivityChanged(id: UUID(), isActive: true)
        await workspace.start()
        try await waitUntil { await MainActor.run {
            workspace.snapshotMaintenanceStatus != nil
        } }
        let firstFetchCount = await transport.fetchCount
        await workspace.requestCloudCopyCleanup()
        try await waitUntil { await transport.cleanupStarted }
        let manualFetchCount = await transport.fetchCount
        XCTAssertGreaterThan(manualFetchCount, firstFetchCount)
        XCTAssertTrue(workspace.isCleaningCloudCopies)
        XCTAssertFalse(workspace.isSyncing)

        await workspace.refresh(manual: true, trigger: "fictional incoming edit")
        let events = await transport.maintenanceEvents
        let cancellation = try XCTUnwrap(events.firstIndex(of: "cleanup cancelled"))
        let resumedFetch = try XCTUnwrap(events.lastIndex(of: "fetch"))
        XCTAssertLessThan(cancellation, resumedFetch)
        XCTAssertNil(workspace.cloudCleanupError)
        XCTAssertNil(workspace.syncFailure)
        workspace.localStorageResetWasScheduled()
    }

    func testManualCleanupSurvivesSyncPreemptionUntilCompleted() async throws {
        let transport = RecordingTransport(scope: "resumed-maintenance")
        await transport.enableMaintenance()
        let workspace = makeWorkspace(transport: transport, automaticSync: false)
        workspace.sceneActivityChanged(id: UUID(), isActive: true)
        await workspace.start()
        try await waitUntil { await MainActor.run {
            workspace.snapshotMaintenanceStatus != nil
        } }
        await workspace.requestCloudCopyCleanup()
        try await waitUntil { await transport.cleanupStarted }
        await transport.allowNextCleanupToComplete()

        await workspace.refresh(manual: true, trigger: "preempt manual cleanup")
        try await waitUntil { await transport.cleanupCompletionCount == 1 }
        try await waitUntil { await MainActor.run {
            !workspace.isCleaningCloudCopies
        } }
        let starts = await transport.cleanupStartCount
        XCTAssertEqual(starts, 2)
        await workspace.refresh(manual: true)
        let finalStarts = await transport.cleanupStartCount
        XCTAssertEqual(finalStarts, 2, "A completed manual request is consumed")
        XCTAssertNil(workspace.cloudCleanupError)
        workspace.localStorageResetWasScheduled()
    }

    func testAccountNotificationCancelsMaintenanceWithAutomaticSyncOff()
        async throws {
        let transport = RecordingTransport(scope: "account-maintenance")
        await transport.enableMaintenance()
        let workspace = makeWorkspace(transport: transport, automaticSync: false)
        workspace.sceneActivityChanged(id: UUID(), isActive: true)
        await workspace.start()
        try await waitUntil { await MainActor.run {
            workspace.snapshotMaintenanceStatus != nil
        } }
        await workspace.requestCloudCopyCleanup()
        try await waitUntil { await transport.cleanupStarted }
        let previousFetches = await transport.fetchCount

        workspace.cloudAccountAvailabilityChanged()

        XCTAssertNil(workspace.snapshotMaintenanceStatus)
        try await waitUntil {
            await transport.maintenanceEvents.contains("cleanup cancelled")
        }
        try await waitUntil { await MainActor.run {
            !workspace.isCleaningCloudCopies
        } }
        let fetches = await transport.fetchCount
        XCTAssertEqual(fetches, previousFetches,
                       "Opt-out still prevents an automatic account refresh")
        XCTAssertNil(workspace.snapshotMaintenanceStatus)
        XCTAssertNil(workspace.cloudCleanupError)
        workspace.localStorageResetWasScheduled()
    }

    func testLeavingForegroundCancelsManualCleanupEvenWithAutomaticSyncOff()
        async throws {
        let transport = RecordingTransport(scope: "background-maintenance")
        await transport.enableMaintenance()
        let workspace = makeWorkspace(transport: transport, automaticSync: false)
        let scene = UUID()
        workspace.sceneActivityChanged(id: scene, isActive: true)
        await workspace.start()
        try await waitUntil { await MainActor.run {
            workspace.snapshotMaintenanceStatus != nil
        } }
        await workspace.requestCloudCopyCleanup()
        try await waitUntil { await transport.cleanupStarted }

        workspace.sceneActivityChanged(id: scene, phase: .background)
        try await waitUntil {
            await transport.maintenanceEvents.contains("cleanup cancelled")
        }
        try await waitUntil { await MainActor.run {
            !workspace.isCleaningCloudCopies
        } }
        XCTAssertNil(workspace.cloudCleanupError)
        await transport.allowNextCleanupToComplete()
        workspace.sceneActivityChanged(id: scene, isActive: true)
        try await waitUntil { await transport.cleanupCompletionCount == 1 }
        let starts = await transport.cleanupStartCount
        XCTAssertEqual(starts, 2, "Foreground resumes the authorized manual request")
        workspace.localStorageResetWasScheduled()
    }

    private func makeWorkspace(
        transport: any SyncTransport,
        automaticSync: Bool = true,
        mode: NotebookWorkspace.Mode? = nil
    ) -> NotebookWorkspace {
        let root = temporaryDirectory()
        return NotebookWorkspace(
            directory: root.appending(path: "Notebook"),
            documentsDirectory: root.appending(path: "Documents"),
            transport: transport,
            automaticSync: automaticSync, mode: mode,
            syncClock: .manual(clock)
        )
    }
}

private actor RecordingTransport: HaltableSyncTransport {
    nonisolated let scope: String
    private let base: InMemorySyncTransport
    private(set) var bootstrapCount = 0
    private(set) var publishCount = 0
    private(set) var fetchCount = 0
    private(set) var purgeCount = 0
    private var retryDeadline: Date?
    private var halt: SyncHaltStatus?
    func setRetryDeadline(_ deadline: Date?) { retryDeadline = deadline }
    func retryNotBefore() async -> Date? { retryDeadline }
    func setHalt(_ value: SyncHaltStatus) { halt = value }
    func haltStatus() async -> SyncHaltStatus? { halt }
    func retire() async {}
    func containsPublishedNote(_ id: UUID) async -> Bool {
        guard let page = try? await base.fetch(after: nil) else { return false }
        return page.records.contains { $0.kind == .note && $0.snapshot.noteID == id }
    }
    private var shouldPauseFetch = false
    private var pausedFetch: CheckedContinuation<Void, Never>?
    var isFetchPaused: Bool { pausedFetch != nil }

    func pauseNextFetch() { shouldPauseFetch = true }
    func resumeFetch() {
        pausedFetch?.resume()
        pausedFetch = nil
    }

    var operationCount: Int {
        bootstrapCount + publishCount + fetchCount + purgeCount
    }

    init(scope: String) {
        self.scope = scope
        base = InMemorySyncTransport(scope: scope)
    }

    private var maintenanceEnabled = false
    private(set) var cleanupStarted = false
    private(set) var cleanupStartCount = 0
    private(set) var cleanupCompletionCount = 0
    private var nextCleanupCompletes = false
    func allowNextCleanupToComplete() { nextCleanupCompletes = true }
    private(set) var maintenanceEvents: [String] = []
    func enableMaintenance() { maintenanceEnabled = true }

    func snapshotMaintenanceStatus(notebookID: UUID) async throws
        -> SyncSnapshotMaintenanceStatus? {
        guard maintenanceEnabled else { return nil }
        return SyncSnapshotMaintenanceStatus(
            lastSuccessfulCleanup: Date(), maximumSnapshotsPerDocument: 2,
            retainedSnapshotBytes: 1, hasPendingCleanup: true
        )
    }

    func cleanupRedundantSnapshots(notebookID: UUID) async throws
        -> SyncSnapshotCleanupReport {
        cleanupStarted = true
        cleanupStartCount += 1
        maintenanceEvents.append("cleanup started")
        if nextCleanupCompletes {
            nextCleanupCompletes = false
            cleanupCompletionCount += 1
            return SyncSnapshotCleanupReport()
        }
        do { try await Task.sleep(for: .seconds(30)) }
        catch {
            maintenanceEvents.append("cleanup cancelled")
            throw error
        }
        return SyncSnapshotCleanupReport()
    }

    func bootstrap(proposing record: SyncRecord) async throws -> SyncRecord {
        bootstrapCount += 1
        return try await base.bootstrap(proposing: record)
    }

    func publish(_ record: SyncRecord) async throws {
        publishCount += 1
        try await base.publish(record)
    }

    func publishBatch(_ records: [SyncRecord]) async throws -> SyncBatchResult {
        publishCount += 1
        return try await base.publishBatch(records)
    }

    func fetch(after cursor: String?) async throws -> SyncPage {
        fetchCount += 1
        maintenanceEvents.append("fetch")
        if shouldPauseFetch {
            shouldPauseFetch = false
            await withCheckedContinuation { pausedFetch = $0 }
        }
        return try await base.fetch(after: cursor)
    }

    func purgeDeletedNotes(
        _ noteIDs: Set<UUID>, notebookID: UUID
    ) async throws {
        purgeCount += 1
        try await base.purgeDeletedNotes(noteIDs, notebookID: notebookID)
    }
}

private actor FailingTransport: SyncTransport {
    nonisolated let scope: String
    private let deadline: Date
    private(set) var bootstrapCount = 0

    init(scope: String, retryNotBefore: Date) {
        self.scope = scope
        deadline = retryNotBefore
    }

    func bootstrap(proposing record: SyncRecord) async throws -> SyncRecord {
        bootstrapCount += 1
        throw SyncError.unavailable("Temporarily unavailable")
    }

    func publish(_ record: SyncRecord) async throws {
        throw SyncError.unavailable("Temporarily unavailable")
    }

    func fetch(after cursor: String?) async throws -> SyncPage {
        throw SyncError.unavailable("Temporarily unavailable")
    }

    func retryNotBefore() async -> Date? { deadline }
}
