import Foundation
import NoteCore
import XCTest

@testable import NotebookAppModel

@MainActor
final class NotebookWorkspaceRecoveryTests: XCTestCase {
    func testCancelledRefreshAllowsManualRetryWithoutReconstruction() async throws {
        let factory = RecoveryTransportFactory()
        let original = HaltableRecordingTransport(
            scope: "cancelled-refresh", remoteStore: factory.remoteStore
        )
        let workspace = makeWorkspace(transport: original, factory: factory)
        await workspace.start()
        let coordinator = try XCTUnwrap(workspace.sync)
        let replica = try XCTUnwrap(workspace.replica)
        let noteID = try await replica.createNote(
            name: "cancelled.md", text: "pending local edit"
        )

        let cancelledRefresh = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await workspace.refresh(manual: true)
        }
        await cancelledRefresh.value

        XCTAssertTrue(coordinator.lastError is CancellationError)
        XCTAssertEqual(workspace.syncFailure?.retryDisposition, .manual)
        XCTAssertTrue(workspace.canRetrySync)
        XCTAssertFalse(workspace.isRefreshing)
        XCTAssertNil(workspace.syncHalt)

        await workspace.refresh(manual: true)

        XCTAssertNil(coordinator.lastError)
        XCTAssertNil(workspace.syncFailure)
        XCTAssertNotNil(workspace.lastSuccessfulSync)
        XCTAssertTrue(workspace.sync === coordinator)
        XCTAssertEqual(factory.creationCount, 0)
        let session = try await replica.openNote(noteID)
        XCTAssertEqual(session.text, "pending local edit")
    }

    func testManualRecoveryReplacesCoordinatorAndKeepsLocalEdits() async throws {
        let factory = RecoveryTransportFactory()
        let original = HaltableRecordingTransport(
            scope: "account-a", remoteStore: factory.remoteStore
        )
        let workspace = makeWorkspace(
            transport: original,
            factory: factory
        )
        await workspace.start()
        let oldCoordinator = try XCTUnwrap(workspace.sync)
        let replica = try XCTUnwrap(workspace.replica)
        let noteID = try await replica.createNote(
            name: "recovery.md", text: "saved before recovery"
        )
        let session = try await replica.openNote(noteID)
        try session.replaceAll(with: "latest local edit")
        try await session.flush()
        let oldGeneration = workspace.transportGeneration
        await original.setHalt(.localStorageFailure, underlyingError: POSIXError(.ENOSPC), recoverable: true)

        await workspace.refresh(manual: true)

        XCTAssertEqual(factory.creationCount, 1)
        XCTAssertEqual(factory.expectedScopes, ["account-a"])
        XCTAssertFalse(workspace.sync === oldCoordinator)
        XCTAssertEqual(session.text, "latest local edit")
        let replacement = try XCTUnwrap(factory.transports.first)
        let replacementPublishCount = await replacement.publishCount
        XCTAssertGreaterThan(replacementPublishCount, 0)
        XCTAssertNil(workspace.syncHalt)
        XCTAssertNil(workspace.syncFailure)
        XCTAssertNil(workspace.syncSetupError)

        let reopened = NotebookReplica(directory: workspace.directory)
        try await reopened.load()
        let reopenedSession = try await reopened.openNote(noteID)
        XCTAssertEqual(reopenedSession.text, "latest local edit")

        let currentScopeGeneration = workspace.searchScopeGeneration
        await workspace.receiveCloudActivity(.accountChanged, generation: oldGeneration)
        XCTAssertEqual(workspace.searchScopeGeneration, currentScopeGeneration)
    }

    func testAutomaticRefreshDoesNotReconstructHaltedTransport() async throws {
        let factory = RecoveryTransportFactory()
        let original = HaltableRecordingTransport(
            scope: "automatic", remoteStore: factory.remoteStore
        )
        let workspace = makeWorkspace(transport: original, factory: factory)
        await workspace.start()
        await original.setHalt(.localStorageFailure, underlyingError: POSIXError(.ENOSPC), recoverable: true)

        await workspace.refresh(manual: false)

        XCTAssertEqual(factory.creationCount, 0)
        XCTAssertEqual(workspace.syncHalt?.reason, .localStorageFailure)
        XCTAssertTrue(workspace.canRetrySync)
    }

    func testManualStartupRecoveryBootstrapsAnEmptyLocalNotebook() async throws {
        let factory = RecoveryTransportFactory()
        let original = HaltableRecordingTransport(
            scope: "empty-startup", remoteStore: factory.remoteStore
        )
        factory.previousTransport = original
        await original.setHalt(
            .localStorageFailure,
            underlyingError: POSIXError(.ENOSPC),
            recoverable: true
        )
        let workspace = makeWorkspace(transport: original, factory: factory)

        await workspace.start()

        XCTAssertEqual(factory.creationCount, 0)
        XCTAssertNil(workspace.replica?.catalogSnapshot)

        await workspace.start(manualRetry: true)

        XCTAssertEqual(factory.creationCount, 1)
        XCTAssertNotNil(workspace.replica?.catalogSnapshot)
        XCTAssertNotNil(workspace.sync)
        XCTAssertNil(workspace.syncHalt)
    }

    func testNonrecoverableAccountAndCorruptHaltsDoNotReconstruct() async throws {
        let statuses: [(CloudKitSyncHaltReason, any Error)] = [
            (.accountChanged, SyncError.scopeChanged),
            (.corruptState, CloudKitSyncTransportError.corruptState),
        ]

        for (reason, error) in statuses {
            let factory = RecoveryTransportFactory()
            let original = HaltableRecordingTransport(
                scope: "protected", remoteStore: factory.remoteStore
            )
            let workspace = makeWorkspace(transport: original, factory: factory)
            await workspace.start()
            await original.setHalt(reason, underlyingError: error, recoverable: false)

            await workspace.refresh(manual: true)

            XCTAssertEqual(factory.creationCount, 0)
            XCTAssertEqual(workspace.syncHalt?.reason, reason)
            XCTAssertFalse(workspace.canRetrySync)
        }
    }

    func testFailedConstructionCanBeRetriedManually() async throws {
        let factory = RecoveryTransportFactory()
        let original = HaltableRecordingTransport(
            scope: "retryable", remoteStore: factory.remoteStore
        )
        factory.failNextCreations = 1
        let workspace = makeWorkspace(transport: original, factory: factory)
        await workspace.start()
        await original.setHalt(.localStorageFailure, underlyingError: POSIXError(.ENOSPC), recoverable: true)

        await workspace.refresh(manual: true)
        XCTAssertEqual(factory.creationCount, 1)
        XCTAssertEqual(workspace.syncHalt?.reason, .localStorageFailure)

        await workspace.refresh(manual: true)

        XCTAssertEqual(factory.creationCount, 2)
        XCTAssertNotNil(workspace.sync)
        XCTAssertNil(workspace.syncHalt)
    }

    func testWrongReplacementScopeIsRetiredAndRejected() async throws {
        let factory = RecoveryTransportFactory()
        let original = HaltableRecordingTransport(
            scope: "expected", remoteStore: factory.remoteStore
        )
        factory.nextScopeOverride = "different"
        let workspace = makeWorkspace(transport: original, factory: factory)
        await workspace.start()
        await original.setHalt(.localStorageFailure, underlyingError: POSIXError(.ENOSPC), recoverable: true)

        await workspace.refresh(manual: true)

        XCTAssertEqual(factory.creationCount, 1)
        let wrongScope = try XCTUnwrap(factory.transports.first)
        let wrongScopeWasRetired = await wrongScope.isRetired
        XCTAssertTrue(wrongScopeWasRetired)
        XCTAssertNil(workspace.sync)
        XCTAssertTrue(workspace.syncSetupError?.contains("changed") == true)
    }

    func testCoalescedManualRequestsCreateOnlyOneReplacement() async throws {
        let factory = RecoveryTransportFactory()
        let original = HaltableRecordingTransport(
            scope: "single-replacement", remoteStore: factory.remoteStore
        )
        let workspace = makeWorkspace(transport: original, factory: factory)
        await workspace.start()
        await original.setHalt(.localStorageFailure, underlyingError: POSIXError(.ENOSPC), recoverable: true)
        factory.pauseNextCreation()

        let firstRecovery = Task { await workspace.refresh(manual: true) }
        try await waitUntil { factory.isCreationPaused }
        await workspace.refresh(manual: true)
        factory.resumeCreation()
        await firstRecovery.value
        let replacement = try XCTUnwrap(factory.transports.first)
        try await waitUntil { await replacement.fetchCount >= 2 }

        XCTAssertEqual(factory.creationCount, 1)
        XCTAssertEqual(factory.transports.count, 1)
    }

    private func makeWorkspace(
        transport: any SyncTransport,
        factory: RecoveryTransportFactory
    ) -> NotebookWorkspace {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "sync-recovery-\(UUID().uuidString)"
        )
        factory.previousTransport = transport as? HaltableRecordingTransport
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return NotebookWorkspace(
            directory: root.appending(path: "Notebook"),
            documentsDirectory: root.appending(path: "Documents"),
            transport: transport,
            automaticSync: false,
            mode: .development(URL(string: "http://127.0.0.1")!, "recovery"),
            transportFactory: { expectedScope in
                try await factory.makeTransport(expectedScope: expectedScope)
            }
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            if clock.now >= deadline {
                XCTFail("Timed out waiting for transport recovery")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor
private final class RecoveryTransportFactory {
    let remoteStore = InMemorySyncStore()
    var previousTransport: HaltableRecordingTransport?
    private(set) var creationCount = 0
    private(set) var expectedScopes: [String?] = []
    private(set) var transports: [HaltableRecordingTransport] = []
    var failNextCreations = 0
    var nextScopeOverride: String?
    private var pauseNext = false
    private var creationContinuation: CheckedContinuation<Void, Never>?
    var isCreationPaused: Bool { creationContinuation != nil }

    func pauseNextCreation() { pauseNext = true }

    func resumeCreation() {
        creationContinuation?.resume()
        creationContinuation = nil
    }

    func makeTransport(expectedScope: String?) async throws -> any SyncTransport {
        creationCount += 1
        expectedScopes.append(expectedScope)
        if pauseNext {
            pauseNext = false
            await withCheckedContinuation { creationContinuation = $0 }
        }
        if let previousTransport,
           !(await previousTransport.isRetired) {
            throw SyncError.unavailable("The previous transport is still active")
        }
        if failNextCreations > 0 {
            failNextCreations -= 1
            throw SyncError.unavailable("Transport construction failed")
        }
        let scope = nextScopeOverride ?? expectedScope ?? "replacement"
        nextScopeOverride = nil
        let transport = HaltableRecordingTransport(
            scope: scope, remoteStore: remoteStore
        )
        transports.append(transport)
        return transport
    }
}

private actor HaltableRecordingTransport: HaltableSyncTransport {
    nonisolated let scope: String
    private let base: InMemorySyncTransport
    private var currentHalt: CloudKitSyncHaltStatus?
    private(set) var publishCount = 0
    private(set) var isRetired = false

    private(set) var fetchCount = 0

    init(scope: String, remoteStore: InMemorySyncStore) {
        self.scope = scope
        base = InMemorySyncTransport(scope: scope, store: remoteStore)
    }

    func setHalt(
        _ reason: CloudKitSyncHaltReason,
        underlyingError: any Error,
        recoverable: Bool
    ) {
        currentHalt = CloudKitSyncHaltStatus(
            reason: reason,
            underlyingError: underlyingError,
            isRecoverable: recoverable
        )
    }

    func haltStatus() async -> CloudKitSyncHaltStatus? { currentHalt }
    func retire() async { isRetired = true }

    private func ensureActive() throws {
        guard !isRetired, currentHalt == nil else {
            throw SyncError.unavailable("Transport is halted or retired")
        }
    }

    func bootstrap(proposing record: SyncRecord) async throws -> SyncRecord {
        try ensureActive()
        return try await base.bootstrap(proposing: record)
    }

    func publish(_ record: SyncRecord) async throws {
        try ensureActive()
        publishCount += 1
        try await base.publish(record)
    }

    func publishBatch(_ records: [SyncRecord]) async throws -> SyncBatchResult {
        try ensureActive()
        publishCount += 1
        return try await base.publishBatch(records)
    }

    func fetch(after cursor: String?) async throws -> SyncPage {
        try ensureActive()
        fetchCount += 1
        return try await base.fetch(after: cursor)
    }

    func purgeDeletedNotes(
        _ noteIDs: Set<UUID>, notebookID: UUID
    ) async throws {
        try ensureActive()
        try await base.purgeDeletedNotes(noteIDs, notebookID: notebookID)
    }
}
