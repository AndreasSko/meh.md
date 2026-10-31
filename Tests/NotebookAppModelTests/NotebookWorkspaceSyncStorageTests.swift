import Foundation
import XCTest

@testable import NoteCore
@testable import NotebookAppModel
import TestSupport

/// Switching the running workspace between iCloud, S3, and no sync. An
/// in-memory store stands in for iCloud.
@MainActor
final class NotebookWorkspaceSyncStorageTests: XCTestCase {
    private let iCloud = InMemorySyncStore()
    private let s3 = FakeS3Server()
    private var root: URL!

    override func setUp() async throws {
        root = temporaryDirectory()
    }

    func testSwitchingToS3MovesTheNotebookAndBackToICloudResumes() async throws {
        let workspace = makeWorkspace()
        await workspace.start()
        let replica = try XCTUnwrap(workspace.replica)
        let id = try await replica.createNote(name: "Trip.md", text: "Fictional packing list\n")
        await workspace.refresh(manual: true)

        try await workspace.changeSyncStorage(.s3, s3: configuration, credentials: credentials)
        XCTAssertEqual(workspace.syncStorage, .s3)
        XCTAssertEqual(workspace.syncStorageName, "S3")
        XCTAssertNil(workspace.syncFailure)
        XCTAssertNotNil(workspace.lastSuccessfulSync)
        XCTAssertEqual(workspace.sync.map { $0.status == .pending }, false)

        let laptop = try await joinS3(named: "laptop")
        let copy = try await laptop.replica.openNote(id)
        XCTAssertEqual(copy.text, "Fictional packing list\n")

        // A change that only reaches S3 arrives through the next exchange.
        let added = try await laptop.replica.createNote(name: "Laptop.md", text: "Fictional\n")
        await laptop.coordinator.synchronize()
        await workspace.refresh(manual: true)
        XCTAssertTrue(replica.placements.contains { $0.item.id == added })

        try await workspace.changeSyncStorage(.iCloud)
        XCTAssertEqual(workspace.syncStorage, .iCloud)
        XCTAssertNil(workspace.syncFailure)
        let phone = try await joinICloud(named: "phone")
        XCTAssertTrue(phone.placements.contains { $0.item.id == added })
        workspace.localStorageResetWasScheduled()
    }

    func testTurningSyncOffKeepsNotesAndStopsExchanges() async throws {
        let workspace = makeWorkspace()
        await workspace.start()
        let replica = try XCTUnwrap(workspace.replica)
        try await workspace.changeSyncStorage(.off)
        XCTAssertFalse(workspace.usesSync)
        XCTAssertNotNil(workspace.lastBackup, "turning sync off makes a backup too")
        let id = try await replica.createNote(name: "Local.md", text: "Fictional\n")
        await workspace.refresh(manual: true)
        let phone = try await joinICloud(named: "phone")
        XCTAssertFalse(phone.placements.contains { $0.item.id == id })

        try await workspace.changeSyncStorage(.iCloud)
        XCTAssertTrue(workspace.usesSync)
        XCTAssertNil(workspace.syncFailure)
        let laptop = try await joinICloud(named: "laptop")
        XCTAssertTrue(laptop.placements.contains { $0.item.id == id })
        workspace.localStorageResetWasScheduled()
    }

    func testStorageWithAnotherNotebookOffersToCombineAfterABackup() async throws {
        let other = try await joinS3(named: "other")
        let theirs = try await other.replica.createNote(name: "Theirs.md", text: "Fictional\n")
        await other.coordinator.synchronize()

        let workspace = makeWorkspace()
        await workspace.start()
        let replica = try XCTUnwrap(workspace.replica)
        let mine = try await replica.createNote(name: "Mine.md", text: "Fictional\n")
        await workspace.refresh(manual: true)

        try await workspace.changeSyncStorage(.s3, s3: configuration, credentials: credentials)
        let mismatch = try XCTUnwrap(workspace.storageMismatch)
        XCTAssertEqual(mismatch.noteCount, 1)
        XCTAssertEqual(workspace.previousSyncStorage, .iCloud)
        XCTAssertEqual(workspace.recentStorageSwitch?.to, .s3)
        XCTAssertNotNil(workspace.lastBackup, "a backup was made before switching")
        XCTAssertFalse(replica.placements.contains { $0.item.id == theirs })

        try await workspace.resolveStorageMismatch(.combine)
        XCTAssertNil(workspace.storageMismatch)
        XCTAssertNil(workspace.syncFailure)
        let folder = try XCTUnwrap(replica.placements.first { $0.displayName == "From iCloud" })
        XCTAssertEqual(replica.placements.first { $0.item.id == mine }?.parentID, folder.item.id)
        XCTAssertTrue(replica.placements.contains { $0.item.id == theirs })

        await other.coordinator.synchronize()
        XCTAssertTrue(other.replica.placements.contains { $0.item.id == mine })

        // Back in iCloud, which still holds the old notebook, the choice
        // comes up again instead of failing.
        try await workspace.changeSyncStorage(.iCloud)
        XCTAssertNotNil(workspace.storageMismatch)
        try await workspace.resolveStorageMismatch(.switchBack)
        XCTAssertEqual(workspace.syncStorage, .s3)
        XCTAssertNil(workspace.storageMismatch)
        XCTAssertNil(workspace.recentStorageSwitch, "nothing reached iCloud")
        XCTAssertNil(workspace.previousSyncStorage)
        XCTAssertNil(workspace.syncFailure)
        workspace.localStorageResetWasScheduled()
    }

    func testFailedBackupLeavesStorageUnchanged() async throws {
        let workspace = makeWorkspace()
        await workspace.start()
        // A file where the backup folder belongs makes the backup fail.
        let backups = root.appending(path: "Documents/Backups")
        try? FileManager.default.removeItem(at: backups)
        try FileManager.default.createDirectory(
            at: root.appending(path: "Documents"), withIntermediateDirectories: true)
        try Data().write(to: backups)
        do {
            try await workspace.changeSyncStorage(.s3, s3: configuration, credentials: credentials)
            XCTFail("Switched without a backup")
        } catch {
            XCTAssertTrue(error is NotebookStorageChangeError)
        }
        XCTAssertEqual(workspace.syncStorage, .iCloud)
        XCTAssertEqual(s3.keys(bucket: "notes"), [])
        workspace.localStorageResetWasScheduled()
    }

    func testS3IsCheckedRegularlyWhileTheAppIsOpen() async throws {
        let workspace = makeWorkspace(automaticSync: true)
        workspace.storagePollInterval = .milliseconds(50)
        workspace.sceneActivityChanged(id: UUID(), isActive: true)
        await workspace.start()
        try await workspace.changeSyncStorage(.s3, s3: configuration, credentials: credentials)
        try await waitUntil { !workspace.isRefreshing }

        let laptop = try await joinS3(named: "laptop")
        let id = try await laptop.replica.createNote(name: "Later.md", text: "Fictional\n")
        await laptop.coordinator.synchronize()
        try await waitUntil { workspace.replica?.placements.contains { $0.item.id == id } == true }
        workspace.localStorageResetWasScheduled()
    }

    // MARK: - Helpers

    private var configuration: S3SyncConfiguration {
        S3SyncConfiguration(endpoint: s3.endpoint, region: "us-east-1", bucket: "notes")
    }

    private let credentials = S3Credentials(accessKeyID: "test", secretAccessKey: "test")

    private func s3Transport(_ directory: URL) -> S3SyncTransport {
        S3SyncTransport(
            configuration: configuration, credentials: credentials,
            stateDirectory: directory, session: s3.session
        )
    }

    private func makeWorkspace(automaticSync: Bool = false) -> NotebookWorkspace {
        let directory = root.appending(path: "Notebook")
        return NotebookWorkspace(
            directory: directory,
            documentsDirectory: root.appending(path: "Documents"),
            transport: nil,
            automaticSync: automaticSync,
            syncSchedule: .init(idleDelay: .milliseconds(20), coalescingDelay: .milliseconds(20)),
            transportFactory: { [iCloud] _ in InMemorySyncTransport(scope: "icloud", store: iCloud) },
            s3TransportFactory: { [unowned self] in
                s3Transport(directory.appending(path: "S3"))
            }
        )
    }

    private func joinS3(
        named name: String
    ) async throws -> (replica: NotebookReplica, coordinator: NotebookSyncCoordinator) {
        let directory = root.appending(path: name)
        let replica = NotebookReplica(directory: directory)
        try await replica.createNotebookForSync()
        let coordinator = NotebookSyncCoordinator(
            replica: replica, transport: s3Transport(directory.appending(path: "S3"))
        )
        await coordinator.synchronize()
        if let error = coordinator.lastError { throw error }
        return (replica, coordinator)
    }

    private func joinICloud(named name: String) async throws -> NotebookReplica {
        let replica = NotebookReplica(directory: root.appending(path: name))
        try await replica.createNotebookForSync()
        let coordinator = NotebookSyncCoordinator(
            replica: replica, transport: InMemorySyncTransport(scope: "icloud", store: iCloud)
        )
        await coordinator.synchronize()
        if let error = coordinator.lastError { throw error }
        return replica
    }
}
