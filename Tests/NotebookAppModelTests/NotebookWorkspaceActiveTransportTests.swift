import Foundation
import XCTest

@testable import NoteCore
@testable import NotebookAppModel
import TestSupport

/// The workspace reacts to any transport that syncs on its own, not only to
/// CloudKit. These checks use a backend-neutral test transport.
@MainActor
final class NotebookWorkspaceActiveTransportTests: XCTestCase {
    func testActivityFromAnyActiveTransportDrivesExchanges() async throws {
        let transport = ActiveTestTransport(scope: "active-transport")
        let workspace = makeWorkspace(transport: transport)
        workspace.sceneActivityChanged(id: UUID(), isActive: true)
        await workspace.start()
        XCTAssertTrue(workspace.syncEventLog.entries.contains {
            $0.event == "test transport state repaired"
        })

        try await waitUntil { await !workspace.isRefreshing && !workspace.hasPendingRefresh }
        let baseline = await transport.fetchCount
        transport.send(.remoteChanges(recordCount: 1, deletionCount: 0, reason: .scheduled))
        try await waitUntil {
            await transport.fetchCount > baseline
                && !workspace.isRefreshing && !workspace.hasPendingRefresh
        }
        XCTAssertTrue(workspace.syncEventLog.entries.contains {
            $0.event == "cloud scheduled changes delivered"
        })

        transport.send(.failed("Server unreachable"))
        try await waitUntil { workspace.syncSetupError == "Server unreachable" }
        workspace.localStorageResetWasScheduled()
    }

    func testManualSyncAsksActiveTransportToCheckTheServer() async throws {
        let transport = ActiveTestTransport(scope: "server-check")
        let workspace = makeWorkspace(transport: transport, automaticSync: false)
        await workspace.start()
        let before = await transport.serverCheckCount

        await workspace.refresh(manual: true)

        let after = await transport.serverCheckCount
        XCTAssertEqual(after, before + 1)
        workspace.localStorageResetWasScheduled()
    }

    private func makeWorkspace(
        transport: ActiveTestTransport, automaticSync: Bool = true
    ) -> NotebookWorkspace {
        let root = temporaryDirectory()
        addTeardownBlock { transport.finish() }
        // A factory, not a preset transport, so the workspace subscribes to
        // activity exactly as it does for a newly created cloud transport.
        return NotebookWorkspace(
            directory: root.appending(path: "Notebook"),
            documentsDirectory: root.appending(path: "Documents"),
            transport: nil,
            automaticSync: automaticSync,
            syncSchedule: .init(
                idleDelay: .milliseconds(20), coalescingDelay: .milliseconds(20)
            ),
            transportFactory: { _ in transport }
        )
    }
}

private actor ActiveTestTransport: ActiveSyncTransport {
    nonisolated let scope: String
    nonisolated let activity: AsyncStream<SyncActivity>
    private nonisolated let continuation: AsyncStream<SyncActivity>.Continuation
    private let base: InMemorySyncTransport
    private(set) var fetchCount = 0
    private(set) var serverCheckCount = 0

    init(scope: String) {
        self.scope = scope
        (activity, continuation) = AsyncStream.makeStream()
        base = InMemorySyncTransport(scope: scope)
    }

    nonisolated func send(_ activity: SyncActivity) {
        continuation.yield(activity)
    }

    nonisolated func finish() {
        continuation.finish()
    }

    func bootstrap(proposing record: SyncRecord) async throws -> SyncRecord {
        try await base.bootstrap(proposing: record)
    }

    func publish(_ record: SyncRecord) async throws {
        try await base.publish(record)
    }

    func fetch(after cursor: String?) async throws -> SyncPage {
        fetchCount += 1
        return try await base.fetch(after: cursor)
    }

    func lastFailure() -> (any Error)? { nil }

    func requestServerCheck() { serverCheckCount += 1 }

    func recoveryEvents() -> [String] { ["test transport state repaired"] }
}
