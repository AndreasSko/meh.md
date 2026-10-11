import Foundation
import NoteCore
import XCTest

@testable import NotebookAppModel

@MainActor
final class NotebookSyncStatusWorkspaceTests: XCTestCase {
    func testSuccessfulTimestampSurvivesRelaunchForSameScopeAndNotebook() async throws {
        let root = temporaryRoot()
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
        let root = temporaryRoot()
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
        let root = temporaryRoot()
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
        let root = temporaryRoot()
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
        let root = temporaryRoot()
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
        try await Task.sleep(for: .milliseconds(50))
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
        transport: any SyncTransport
    ) -> NotebookWorkspace {
        NotebookWorkspace(
            directory: root.appending(path: "Notebook"),
            documentsDirectory: root.appending(path: "Documents"),
            transport: transport, automaticSync: false,
            mode: .development(URL(string: "http://127.0.0.1")!, "status-test")
        )
    }

    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        condition: @escaping @MainActor @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            if clock.now >= deadline {
                XCTFail("Timed out waiting for sync status behavior")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
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
    private var pauseFetch = false
    private var pausedFetch: CheckedContinuation<Void, Never>?

    init(scope: String, store: InMemorySyncStore = InMemorySyncStore()) {
        self.scope = scope
        base = InMemorySyncTransport(scope: scope, store: store)
    }

    var isFetchPaused: Bool { pausedFetch != nil }

    func failNextFetch() { failFetch = true }
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
