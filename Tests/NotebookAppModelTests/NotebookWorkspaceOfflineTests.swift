import Foundation
import NoteCore
import XCTest

@testable import NotebookAppModel

@MainActor
final class NotebookWorkspaceOfflineTests: XCTestCase {
    func testRepeatedLaunchesWithoutAnAccountKeepSavingCopiesAndBackups() async throws {
        let root = directory()
        let factory = OfflineAccountFactory()
        var noteID: UUID?
        var notebookID: UUID?
        var expectedText: String?

        for revision in 1...3 {
            let workspace = makeWorkspace(root: root, factory: factory)
            workspace.sceneActivityChanged(id: UUID(), isActive: true)
            await workspace.start()
            let replica = try XCTUnwrap(workspace.replica)
            XCTAssertFalse(replica.localEditsSuspended)
            if let notebookID {
                XCTAssertEqual(replica.catalogSnapshot?.notebookID, notebookID)
            } else {
                notebookID = replica.catalogSnapshot?.notebookID
            }
            if noteID == nil {
                noteID = try await replica.createNote(name: "Offline.md", text: "")
            }
            let session = try await replica.openNote(try XCTUnwrap(noteID))
            if let expectedText { XCTAssertEqual(session.text, expectedText) }
            let text = "# Café 👋🏽\r\n\r\nOffline revision \(revision).\r\n"
            try session.replaceAll(with: text)
            try await session.flush()
            expectedText = text
            workspace.contentDidSave(trigger: "offline revision saved")
            workspace.cloudAccountAvailabilityChanged()
            let copy = rootCopyDirectory(for: workspace).appending(path: "Offline.md")
            try await waitUntil {
                (try? Data(contentsOf: copy)) == Data(text.utf8) && !workspace.isRefreshing
            }
            try await workspace.backupNow()

            XCTAssertEqual(workspace.lastBackup?.notebookID, notebookID)
            XCTAssertNil(workspace.lastSuccessfulSync)
            XCTAssertNil(workspace.sync)
            XCTAssertNotNil(workspace.syncSetupError)
            XCTAssertNil(workspace.copyError)
            workspace.localStorageResetWasScheduled()
        }
        XCTAssertFalse(factory.isAvailable)
        XCTAssertGreaterThanOrEqual(factory.attempts, 3)
    }

    func testFreshNoAccountNotebookSavesAndReopensBeforeAutomaticJoining() async throws {
        let root = directory()
        let factory = OfflineAccountFactory()
        let workspace = makeWorkspace(root: root, factory: factory)
        await workspace.start()

        let replica = try XCTUnwrap(workspace.replica)
        XCTAssertNotNil(replica.catalogSnapshot)
        XCTAssertFalse(replica.localEditsSuspended)
        XCTAssertNotNil(workspace.syncSetupError)
        XCTAssertNil(workspace.syncRetryNotBefore)
        let noteID = try await replica.createNote(name: "First.md", text: "Written without iCloud")
        let session = try await replica.openNote(noteID)
        try session.replaceAll(with: "Saved locally, before signing in")
        try await session.flush()
        let snapshot = session.currentSnapshot
        workspace.localStorageResetWasScheduled()

        let reopened = makeWorkspace(root: root, factory: factory)
        await reopened.start()
        let restored = try XCTUnwrap(reopened.replica)
        let restoredNote = try await restored.openNote(noteID)
        XCTAssertEqual(restoredNote.text, "Saved locally, before signing in")
        factory.isAvailable = true
        reopened.sceneActivityChanged(id: UUID(), isActive: true)
        reopened.cloudAccountAvailabilityChanged()
        // The exchange succeeds before refresh clears its old error state.
        try await waitUntil { reopened.lastSuccessfulSync != nil && !reopened.isRefreshing }

        XCTAssertNil(reopened.syncFailure)
        XCTAssertNil(reopened.syncSetupError)
        XCTAssertEqual(restoredNote.currentSnapshot, snapshot)
        XCTAssertTrue(try XCTUnwrap(reopened.sync).hasDurableBinding())
        let remote = NotebookReplica(directory: directory())
        let remoteSync = NotebookSyncCoordinator(replica: remote, transport: factory.transport)
        await remoteSync.synchronize()
        XCTAssertNil(remoteSync.lastError)
        let remoteNote = try await remote.openNote(noteID)
        XCTAssertEqual(remoteNote.text, restoredNote.text)
        reopened.localStorageResetWasScheduled()
    }

    func testForegroundAfterEnablingAccountJoinsExistingCloudWithoutManualSync() async throws {
        let factory = OfflineAccountFactory()
        let remote = NotebookReplica(directory: directory())
        let remoteSync = NotebookSyncCoordinator(replica: remote, transport: factory.transport)
        await remoteSync.synchronize()
        let cloudNote = try await remote.createNote(name: "Cloud.md", text: "Already in iCloud")
        await remoteSync.synchronize()
        let workspace = makeWorkspace(root: directory(), factory: factory)
        await workspace.start()
        let replica = try XCTUnwrap(workspace.replica)
        let localNote = try await replica.createNote(name: "Local.md", text: "Before iCloud")
        let offlineNotebookID = replica.catalogSnapshot?.notebookID
        try await workspace.backupNow()

        factory.isAvailable = true
        workspace.sceneActivityChanged(id: UUID(), isActive: true)
        // Refresh publishes the Markdown copies after the cloud exchange.
        try await waitUntil { workspace.lastSuccessfulSync != nil && !workspace.isRefreshing }

        XCTAssertEqual(Set(replica.placements.map { $0.item.id }), [localNote, cloudNote])
        XCTAssertEqual(replica.catalogSnapshot?.notebookID, remote.catalogSnapshot?.notebookID)
        let localBody = try await replica.openNote(localNote)
        XCTAssertEqual(localBody.text, "Before iCloud")
        let cloudBody = try await replica.openNote(cloudNote)
        XCTAssertEqual(cloudBody.text, "Already in iCloud")
        XCTAssertNil(workspace.copyError)
        let copies = rootCopyDirectory(for: workspace)
        XCTAssertEqual(try String(contentsOf: copies.appending(path: "Local.md"), encoding: .utf8),
                       "Before iCloud")
        XCTAssertEqual(try String(contentsOf: copies.appending(path: "Cloud.md"), encoding: .utf8),
                       "Already in iCloud")
        await workspace.reloadBackupInfo()
        XCTAssertEqual(workspace.lastBackup?.notebookID, offlineNotebookID)
        workspace.localStorageResetWasScheduled()
    }

    func testAutomaticSyncOptOutKeepsAccountChangeFromStartingSync() async throws {
        let factory = OfflineAccountFactory()
        let workspace = makeWorkspace(root: directory(), factory: factory, automaticSync: false)
        await workspace.start()
        let initialAttempts = factory.attempts
        factory.isAvailable = true
        workspace.sceneActivityChanged(id: UUID(), isActive: true)
        workspace.cloudAccountAvailabilityChanged()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(factory.attempts, initialAttempts)
        XCTAssertNil(workspace.lastSuccessfulSync)
        await workspace.refresh(manual: true)
        XCTAssertNotNil(workspace.lastSuccessfulSync)
        workspace.localStorageResetWasScheduled()
    }

    private func makeWorkspace(root: URL, factory: OfflineAccountFactory,
                               automaticSync: Bool = true) -> NotebookWorkspace {
        NotebookWorkspace(directory: root.appending(path: "Notebook"),
            documentsDirectory: root.appending(path: "Documents"), transport: nil,
            automaticSync: automaticSync, mode: .cloud,
            syncSchedule: .init(idleDelay: .milliseconds(20), coalescingDelay: .milliseconds(20)),
            transportFactory: { _ in
                factory.attempts += 1
                guard factory.isAvailable else { throw CloudKitSyncTransportError.accountUnavailable }
                return factory.transport
            })
    }

    private func directory() -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "offline-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func rootCopyDirectory(for workspace: NotebookWorkspace) -> URL {
        workspace.backupDirectory.deletingLastPathComponent().appending(path: "Notebook Copies/Markdown")
    }

    private func waitUntil(condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for automatic first sync")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor
private final class OfflineAccountFactory {
    let transport = InMemorySyncTransport(scope: "same-account")
    var isAvailable = false
    var attempts = 0
}
