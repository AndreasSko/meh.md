import Foundation
import NoteCore
import XCTest

@testable import NotebookAppModel
import TestSupport

@MainActor
final class NotebookSyncStatusWorkspaceTests: XCTestCase {
    private let clock = ManualClock()

    func testLocalSaveWaitClearsThroughScheduledRetry() async throws {
        let transport = StatusWorkspaceTransport(scope: "local-wait")
        let workspace = makeWorkspace(
            root: temporaryDirectory(), transport: transport, automaticSync: true
        )
        await workspace.start()
        let sceneID = UUID()
        workspace.sceneActivityChanged(id: sceneID, isActive: true)
        defer {
            workspace.localStorageResetWasScheduled()
            workspace.sceneDidClose(id: sceneID)
        }
        try await waitUntil { !workspace.isRefreshing }
        await transport.failFetches(with: SyncError.localSaveRequired, count: 1)

        await workspace.requestSyncFromStatus()

        XCTAssertTrue(workspace.syncFailure?.isWaitingForLocalSave == true)
        XCTAssertTrue(workspace.isWaitingForLocalSave(at: Date()))
        XCTAssertNotNil(workspace.syncRetryNotBefore)
        let failedFetchCount = await transport.fetchCount
        clock.advance(by: .seconds(60))
        try await waitUntil {
            let fetchCount = await transport.fetchCount
            return workspace.syncFailure == nil && !workspace.isRefreshing
                && fetchCount > failedFetchCount
        }
        XCTAssertNil(workspace.syncWaitStartedAt)
    }

    func testRepeatedLocalWaitRetainsGraceStartUntilRecovery() async throws {
        let transport = StatusWorkspaceTransport(scope: "repeated-wait")
        let workspace = makeWorkspace(
            root: temporaryDirectory(), transport: transport, automaticSync: true
        )
        await workspace.start()
        let sceneID = UUID()
        workspace.sceneActivityChanged(id: sceneID, isActive: true)
        defer {
            workspace.localStorageResetWasScheduled()
            workspace.sceneDidClose(id: sceneID)
        }
        try await waitUntil { !workspace.isRefreshing }
        await transport.failFetches(with: SyncError.localSaveRequired, count: 2)
        await workspace.requestSyncFromStatus()
        let started = try XCTUnwrap(workspace.syncWaitStartedAt)
        let failedFetchCount = await transport.fetchCount

        clock.advance(by: .seconds(60))
        try await waitUntil {
            await transport.fetchCount > failedFetchCount && !workspace.isRefreshing
        }

        XCTAssertEqual(workspace.syncWaitStartedAt, started)
        XCTAssertTrue(workspace.isWaitingForLocalSave(at: started.addingTimeInterval(59)))
        XCTAssertFalse(workspace.isWaitingForLocalSave(at: started.addingTimeInterval(60)))
        XCTAssertFalse(workspace.isWaitingForLocalSave(at: started.addingTimeInterval(61)))
        clock.advance(by: .seconds(60))
        try await waitUntil {
            workspace.syncFailure == nil && !workspace.isRefreshing
        }
        XCTAssertNil(workspace.syncWaitStartedAt)
    }

    func testRealSaveFailureWarnsImmediatelyWithAutomaticRetry() async throws {
        let transport = StatusWorkspaceTransport(scope: "disk-full")
        let workspace = makeWorkspace(
            root: temporaryDirectory(), transport: transport, automaticSync: true
        )
        await workspace.start()
        let sceneID = UUID()
        workspace.sceneActivityChanged(id: sceneID, isActive: true)
        defer {
            workspace.localStorageResetWasScheduled()
            workspace.sceneDidClose(id: sceneID)
        }
        try await waitUntil { !workspace.isRefreshing }
        await transport.failFetches(
            with: LocalNoteSaveFailure(underlyingError: POSIXError(.ENOSPC)),
            count: 1
        )

        await workspace.requestSyncFromStatus()

        let failure = try XCTUnwrap(workspace.syncFailure)
        XCTAssertEqual(String(localized: failure.title), "Device storage is full")
        XCTAssertFalse(failure.isWaitingForLocalSave)
        XCTAssertFalse(workspace.isWaitingForLocalSave(at: Date()))
        XCTAssertNil(workspace.syncWaitStartedAt)
        XCTAssertNotNil(workspace.syncRetryNotBefore)
        clock.advance(by: .seconds(60))
        try await waitUntil {
            workspace.syncFailure == nil && !workspace.isRefreshing
        }
    }

    func testSuccessfulTimestampSurvivesRelaunchForSameScopeAndNotebook() async throws {
        let root = temporaryDirectory()
        let store = InMemorySyncStore()
        let firstTransport = StatusWorkspaceTransport(scope: "account-a", store: store)
        let first = makeWorkspace(root: root, transport: firstTransport)
        await first.start()
        let savedDate = try XCTUnwrap(first.lastSuccessfulSync)

        let failing = StatusWorkspaceTransport(scope: "account-a", store: store)
        await failing.failNextFetch()
        let second = makeWorkspace(
            root: root, transport: failing
        )
        await second.start()

        XCTAssertEqual(second.lastSuccessfulSync, savedDate)
    }

    func testOfflineTransportPreparationRetainsLocallyBoundTimestamp() async throws {
        let root = temporaryDirectory()
        let first = makeWorkspace(
            root: root, transport: StatusWorkspaceTransport(scope: "account-a")
        )
        await first.start()
        let savedDate = try XCTUnwrap(first.lastSuccessfulSync)
        let relaunched = NotebookWorkspace(
            directory: root.appending(path: "Notebook"),
            documentsDirectory: root.appending(path: "Documents"),
            transport: nil, automaticSync: false,
            mode: .development(URL(string: "http://127.0.0.1")!, "status-test"),
            transportFactory: { _ in
                throw SyncError.unavailable("Offline before account discovery")
            }
        )

        await relaunched.start()

        XCTAssertNotNil(relaunched.syncSetupError)
        XCTAssertEqual(relaunched.lastSuccessfulSync, savedDate)
    }

    func testTimestampIsIgnoredForDifferentScopeOrNotebookIdentity() async throws {
        let root = temporaryDirectory()
        let store = InMemorySyncStore()
        let first = makeWorkspace(
            root: root,
            transport: StatusWorkspaceTransport(scope: "account-a", store: store)
        )
        await first.start()
        let savedDate = try XCTUnwrap(first.lastSuccessfulSync)
        let stampURL = first.directory.appending(path: "last-successful-sync.json")

        let otherScope = makeWorkspace(
            root: root,
            transport: StatusWorkspaceTransport(scope: "account-b", store: store)
        )
        await otherScope.start()
        XCTAssertNil(otherScope.lastSuccessfulSync)

        var stamp = try JSONDecoder().decode(Stamp.self, from: Data(contentsOf: stampURL))
        stamp.notebookID = UUID()
        try JSONEncoder().encode(stamp).write(to: stampURL, options: .atomic)
        let failing = StatusWorkspaceTransport(scope: "account-a", store: store)
        await failing.failNextFetch()
        let otherIdentity = makeWorkspace(root: root, transport: failing)
        await otherIdentity.start()

        XCTAssertNil(otherIdentity.lastSuccessfulSync)
        XCTAssertEqual(savedDate, stamp.date)
    }

    func testFailurePreservesLastSuccessfulTimestamp() async throws {
        let root = temporaryDirectory()
        let transport = StatusWorkspaceTransport(scope: "account-a")
        let workspace = makeWorkspace(root: root, transport: transport)
        await workspace.start()
        let successfulDate = try XCTUnwrap(workspace.lastSuccessfulSync)
        await transport.failNextFetch()

        await workspace.requestSyncFromStatus()

        XCTAssertEqual(workspace.lastSuccessfulSync, successfulDate)
        let failedFetchCount = await transport.fetchCount
        XCTAssertNotNil(workspace.syncRetryNotBefore)

        await workspace.requestSyncFromStatus()

        let fetchCountDuringCooldown = await transport.fetchCount
        XCTAssertEqual(fetchCountDuringCooldown, failedFetchCount)
    }

    func testStatusTapDoesNotQueueButOrdinaryRefreshStillCoalesces() async throws {
        let root = temporaryDirectory()
        let transport = StatusWorkspaceTransport(scope: "account-a")
        let workspace = makeWorkspace(root: root, transport: transport)
        await workspace.start()
        let baseline = await transport.fetchCount

        await transport.pauseNextFetch()
        let firstTap = Task { await workspace.requestSyncFromStatus() }
        try await waitUntil { await transport.isFetchPaused }
        await workspace.requestSyncFromStatus()
        await transport.resumeFetch()
        await firstTap.value
        try await waitUntil { !workspace.isRefreshing }
        XCTAssertFalse(workspace.hasPendingRefresh)
        let afterStatusTaps = await transport.fetchCount
        XCTAssertEqual(afterStatusTaps, baseline + 1)

        await transport.pauseNextFetch()
        let ordinaryRefresh = Task { await workspace.refresh(manual: true) }
        try await waitUntil { await transport.isFetchPaused }
        await workspace.refresh(manual: true)
        await transport.resumeFetch()
        await ordinaryRefresh.value
        try await waitUntil { !workspace.isRefreshing }
        try await waitUntil { await transport.fetchCount >= baseline + 3 }
        let afterOrdinaryRefreshes = await transport.fetchCount
        XCTAssertEqual(afterOrdinaryRefreshes, baseline + 3)
    }

    private func makeWorkspace(
        root: URL,
        transport: any SyncTransport,
        automaticSync: Bool = false
    ) -> NotebookWorkspace {
        NotebookWorkspace(
            directory: root.appending(path: "Notebook"),
            documentsDirectory: root.appending(path: "Documents"),
            transport: transport, automaticSync: automaticSync,
            mode: .development(URL(string: "http://127.0.0.1")!, "status-test"),
            syncClock: .manual(clock)
        )
    }
}

private struct Stamp: Codable {
    let date: Date
    let scope: String
    var notebookID: UUID
}

private actor StatusWorkspaceTransport: SyncTransport {
    nonisolated let scope: String
    private let base: InMemorySyncTransport
    private(set) var fetchCount = 0
    private var failFetch = false
    private var injectedError: (any Error)?
    private var failuresRemaining = 0
    private var pauseFetch = false
    private var pausedFetch: CheckedContinuation<Void, Never>?

    init(scope: String, store: InMemorySyncStore = InMemorySyncStore()) {
        self.scope = scope
        base = InMemorySyncTransport(scope: scope, store: store)
    }

    var isFetchPaused: Bool { pausedFetch != nil }

    func failNextFetch() { failFetch = true }
    func failFetches(with error: any Error, count: Int) {
        injectedError = error
        failuresRemaining = count
    }
    func pauseNextFetch() { pauseFetch = true }
    func resumeFetch() {
        pausedFetch?.resume()
        pausedFetch = nil
    }

    func bootstrap(proposing record: SyncRecord) async throws -> SyncRecord {
        try await base.bootstrap(proposing: record)
    }

    func publish(_ record: SyncRecord) async throws {
        try await base.publish(record)
    }

    func fetch(after cursor: String?) async throws -> SyncPage {
        fetchCount += 1
        if failuresRemaining > 0, let injectedError {
            failuresRemaining -= 1
            throw injectedError
        }
        if failFetch {
            failFetch = false
            throw SyncError.unavailable("Temporary test failure")
        }
        if pauseFetch {
            pauseFetch = false
            await withCheckedContinuation { pausedFetch = $0 }
        }
        return try await base.fetch(after: cursor)
    }
}
