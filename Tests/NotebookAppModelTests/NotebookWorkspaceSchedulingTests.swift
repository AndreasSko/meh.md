import Foundation
import NoteCore
import XCTest

@testable import NotebookAppModel

@MainActor
final class NotebookWorkspaceSchedulingTests: XCTestCase {
    func testSavedEditsCoalesceIntoOneAutomaticExchange() async throws {
        let transport = RecordingTransport(scope: "coalesced")
        let workspace = makeWorkspace(transport: transport)
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

        try await waitUntil {
            await transport.fetchCount > baselineFetches
        }
        try await Task.sleep(for: .milliseconds(250))
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
        try await Task.sleep(for: .seconds(1))

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

    func testBackgroundFlushesOnceAndForegroundResumes() async throws {
        let transport = RecordingTransport(scope: "foreground")
        let workspace = makeWorkspace(transport: transport)
        await workspace.start()
        let baselineFetches = await transport.fetchCount

        _ = try await workspace.replica?.createNote(
            name: "paused.md", text: "paused"
        )
        workspace.contentDidSave()
        workspace.sceneActivityChanged(isActive: false)
        try await waitUntil {
            await transport.fetchCount > baselineFetches
        }
        let backgroundFetches = await transport.fetchCount

        workspace.sceneActivityChanged(isActive: false)
        try await Task.sleep(for: .milliseconds(250))
        let repeatedBackgroundFetches = await transport.fetchCount
        XCTAssertEqual(repeatedBackgroundFetches, backgroundFetches)

        workspace.sceneActivityChanged(isActive: true)
        try await waitUntil {
            await transport.fetchCount > backgroundFetches
        }
    }

    func testCloudFailureDoesNotEchoButRemoteChangesReconcile() async {
        let transport = RecordingTransport(scope: "cloud-activity")
        let workspace = makeWorkspace(transport: transport)
        await workspace.start()
        let baselineOperations = await transport.operationCount
        let baselineFetches = await transport.fetchCount

        await workspace.receiveCloudActivity(.failed("Account changed"))
        await workspace.receiveCloudActivity(.failed("Account changed"))

        let operationsAfterFailures = await transport.operationCount
        XCTAssertEqual(operationsAfterFailures, baselineOperations)
        XCTAssertEqual(workspace.syncSetupError, "Account changed")

        await workspace.receiveCloudActivity(
            .remoteChanges(recordCount: 1, deletionCount: 0, reason: .scheduled)
        )

        let fetchesAfterRemoteChanges = await transport.fetchCount
        XCTAssertEqual(fetchesAfterRemoteChanges, baselineFetches + 1)
        XCTAssertTrue(workspace.syncEventLog.entries.contains {
            $0.event == "cloud scheduled changes delivered"
        })
    }

    private func makeWorkspace(
        transport: any SyncTransport,
        automaticSync: Bool = true
    ) -> NotebookWorkspace {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return NotebookWorkspace(
            directory: root.appending(path: "Notebook"),
            documentsDirectory: root.appending(path: "Documents"),
            transport: transport,
            automaticSync: automaticSync
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            if clock.now >= deadline {
                XCTFail("Timed out waiting for workspace scheduling")
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}

private actor RecordingTransport: SyncTransport {
    nonisolated let scope: String
    private let base: InMemorySyncTransport
    private(set) var bootstrapCount = 0
    private(set) var publishCount = 0
    private(set) var fetchCount = 0
    private(set) var purgeCount = 0

    var operationCount: Int {
        bootstrapCount + publishCount + fetchCount + purgeCount
    }

    init(scope: String) {
        self.scope = scope
        base = InMemorySyncTransport(scope: scope)
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
