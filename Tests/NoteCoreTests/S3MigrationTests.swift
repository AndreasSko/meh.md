import Foundation
import TestSupport
import XCTest

@testable import NoteCore

/// Moving a notebook between iCloud and S3, including into storage that holds
/// another notebook. An in-memory store with a non-S3 scope stands in for
/// iCloud.
@MainActor
final class S3MigrationTests: XCTestCase {
    private var root: URL!
    private let iCloud = InMemorySyncStore()
    private let s3 = FakeS3Server()

    override func setUp() async throws {
        root = temporaryDirectory()
    }

    func testSwitchingToS3UploadsTheNotebookAndAnotherDeviceJoinsIt() async throws {
        let phone = NotebookReplica(directory: root.appending(path: "phone"))
        try await synchronize(phone, iCloudCoordinator(phone))
        let id = try await phone.createNote(name: "Groceries.md", text: "Fictional apples\n")
        try await synchronize(phone, iCloudCoordinator(phone))

        try await synchronize(phone, s3Coordinator(phone, device: "phone"))
        XCTAssertFalse(s3.keys(bucket: "notes", prefix: "meh/meh-notebook/records/").isEmpty)

        let mac = NotebookReplica(directory: root.appending(path: "mac"))
        try await mac.createNotebookForSync()
        try await synchronize(mac, s3Coordinator(mac, device: "mac"))
        XCTAssertEqual(mac.catalogSnapshot?.notebookID, phone.catalogSnapshot?.notebookID)
        let note = try await mac.openNote(id)
        XCTAssertEqual(note.text, "Fictional apples\n")
        // The adopted local identity stays readable for backups and copies.
        XCTAssertNotNil(try mac.firstSyncLocalNotebookID())

        // Both sync states survive, so switching back resumes iCloud.
        XCTAssertNotNil(try NotebookSyncCoordinator.boundScope(for: phone))
        XCTAssertEqual(
            try NotebookSyncCoordinator.boundScope(for: phone, likeScope: "s3://"),
            "s3://\(s3.host)/notes/meh"
        )
        try await synchronize(phone, iCloudCoordinator(phone))
    }

    func testFolderWithAnotherNotebookIsLeftUntouched() async throws {
        let other = NotebookReplica(directory: root.appending(path: "other"))
        try await synchronize(other, s3Coordinator(other, device: "other"))
        let before = s3.keys(bucket: "notes")

        let phone = NotebookReplica(directory: root.appending(path: "phone"))
        try await synchronize(phone, iCloudCoordinator(phone))
        _ = try await phone.createNote(name: "Private.md", text: "Fictional\n")
        let coordinator = s3Coordinator(phone, device: "phone")
        await coordinator.synchronize()

        let mismatch = try XCTUnwrap(coordinator.lastError as? NotebookStorageMismatch)
        XCTAssertEqual(mismatch.notebookID, other.catalogSnapshot?.notebookID)
        XCTAssertEqual(mismatch.noteCount, 0)
        XCTAssertEqual(s3.keys(bucket: "notes"), before)
        XCTAssertNotEqual(phone.catalogSnapshot?.notebookID, other.catalogSnapshot?.notebookID)
    }

    func testCombiningAddsThisDevicesNotesInAFolderAndMergesSharedOnes() async throws {
        // A notebook in S3 that another device created.
        let other = NotebookReplica(directory: root.appending(path: "other"))
        let otherSync = s3Coordinator(other, device: "other")
        try await synchronize(other, otherSync)
        let theirs = try await other.createNote(name: "Theirs.md", text: "Fictional S3 note\n")
        try await synchronize(other, otherSync)

        // This device used iCloud with its own notebook.
        let phone = NotebookReplica(directory: root.appending(path: "phone"))
        try await synchronize(phone, iCloudCoordinator(phone))
        let folder = try await phone.createFolder(name: "Projects")
        let mine = try await phone.createNote(
            name: "Mine.md", text: "Fictional iCloud note\n", parentID: folder)
        try await synchronize(phone, iCloudCoordinator(phone))

        let phoneS3 = s3Coordinator(phone, device: "phone")
        await phoneS3.synchronize()
        let mismatch = try XCTUnwrap(phoneS3.lastError as? NotebookStorageMismatch)
        XCTAssertEqual(mismatch.noteCount, 1)

        try await phone.chooseOtherNotebook(.combine(folderName: "From iCloud"), scope: mismatch.scope)
        try await synchronize(phone, phoneS3)
        XCTAssertEqual(phone.catalogSnapshot?.notebookID, other.catalogSnapshot?.notebookID)
        let placements = phone.placements
        let combined = try XCTUnwrap(placements.first { $0.displayName == "From iCloud" })
        let projects = try XCTUnwrap(placements.first { $0.item.id == folder })
        XCTAssertEqual(projects.parentID, combined.item.id)
        XCTAssertEqual(placements.first { $0.item.id == mine }?.parentID, folder)
        XCTAssertNotNil(placements.first { $0.item.id == theirs })
        let mineText = try await phone.openNote(mine).text
        XCTAssertEqual(mineText, "Fictional iCloud note\n")

        // The other device receives the combined notebook.
        try await synchronize(other, otherSync)
        let received = try await other.openNote(mine).text
        XCTAssertEqual(received, "Fictional iCloud note\n")
        XCTAssertEqual(other.placements, phone.placements)
        XCTAssertFalse(try phone.mayJoinAnotherNotebook())

        // A second device with the same iCloud notebook combines too. Its
        // notes are already there, so they merge instead of duplicating.
        let iPad = NotebookReplica(directory: root.appending(path: "ipad"))
        try await iPad.createNotebookForSync()
        try await synchronize(iPad, iCloudCoordinator(iPad))
        let iPadS3 = s3Coordinator(iPad, device: "ipad")
        await iPadS3.synchronize()
        let iPadMismatch = try XCTUnwrap(iPadS3.lastError as? NotebookStorageMismatch)
        try await iPad.chooseOtherNotebook(
            .combine(folderName: "From iCloud"), scope: iPadMismatch.scope)
        try await synchronize(iPad, iPadS3)
        XCTAssertEqual(iPad.placements.count { $0.item.id == mine }, 1)
        XCTAssertEqual(iPad.placements.count { $0.displayName == "From iCloud" }, 1)
    }

    func testUsingTheStoredNotebookKeepsTheOldStorageUntouched() async throws {
        let other = NotebookReplica(directory: root.appending(path: "other"))
        let otherSync = s3Coordinator(other, device: "other")
        try await synchronize(other, otherSync)
        let theirs = try await other.createNote(name: "Theirs.md", text: "Fictional\n")
        try await synchronize(other, otherSync)

        let phone = NotebookReplica(directory: root.appending(path: "phone"))
        let phoneICloud = iCloudCoordinator(phone)
        try await synchronize(phone, phoneICloud)
        let mine = try await phone.createNote(name: "Mine.md", text: "Fictional\n")
        try await synchronize(phone, phoneICloud)
        let iCloudNotebook = phone.catalogSnapshot?.notebookID

        let phoneS3 = s3Coordinator(phone, device: "phone")
        await phoneS3.synchronize()
        let mismatch = try XCTUnwrap(phoneS3.lastError as? NotebookStorageMismatch)
        try await phone.chooseOtherNotebook(.replace, scope: mismatch.scope)
        try await synchronize(phone, phoneS3)

        XCTAssertEqual(phone.catalogSnapshot?.notebookID, other.catalogSnapshot?.notebookID)
        XCTAssertNotNil(phone.placements.first { $0.item.id == theirs })
        XCTAssertNil(phone.placements.first { $0.item.id == mine })
        // iCloud still holds the old notebook for the other iCloud devices.
        let iPad = NotebookReplica(directory: root.appending(path: "ipad"))
        try await iPad.createNotebookForSync()
        try await synchronize(iPad, iCloudCoordinator(iPad))
        XCTAssertEqual(iPad.catalogSnapshot?.notebookID, iCloudNotebook)
        XCTAssertNotNil(iPad.placements.first { $0.item.id == mine })
    }

    func testUsingTheStoredNotebookDoesNotApplyThisDevicesDeletions() async throws {
        // The welcome note has the same ID in every notebook.
        let other = NotebookReplica(directory: root.appending(path: "other"))
        let otherSync = s3Coordinator(other, device: "other")
        try await synchronize(other, otherSync)
        _ = try await other.addMissingWelcomeNote()
        try await synchronize(other, otherSync)
        let welcome = NotebookWelcomeNote.id

        let phone = NotebookReplica(directory: root.appending(path: "phone"))
        let phoneICloud = iCloudCoordinator(phone)
        try await synchronize(phone, phoneICloud)
        _ = try await phone.addMissingWelcomeNote()
        try await phone.setTrashed(welcome, true)
        try await phone.permanentlyDelete(try phone.deletionSelection())
        try await synchronize(phone, phoneICloud)

        let phoneS3 = s3Coordinator(phone, device: "phone")
        await phoneS3.synchronize()
        let mismatch = try XCTUnwrap(phoneS3.lastError as? NotebookStorageMismatch)
        try await phone.chooseOtherNotebook(.replace, scope: mismatch.scope)
        try await synchronize(phone, phoneS3)
        try await synchronize(other, otherSync)
        XCTAssertNotNil(phone.placements.first { $0.item.id == welcome })
        XCTAssertNotNil(other.placements.first { $0.item.id == welcome })
    }

    func testChoiceForOneStorageIsNotUsedForAnother() async throws {
        let phone = NotebookReplica(directory: root.appending(path: "phone"))
        try await synchronize(phone, iCloudCoordinator(phone))
        _ = try await phone.createNote(name: "Mine.md", text: "Fictional\n")
        try await phone.chooseOtherNotebook(.replace, scope: "s3://elsewhere/notes/")
        XCTAssertFalse(try phone.mayJoinAnotherNotebook(in: "icloud"))
        try await synchronize(phone, iCloudCoordinator(phone))
        try phone.withdrawOtherNotebookChoice()
        XCTAssertFalse(try phone.mayJoinAnotherNotebook())
    }

    // MARK: - Helpers

    private func iCloudCoordinator(_ replica: NotebookReplica) -> NotebookSyncCoordinator {
        NotebookSyncCoordinator(
            replica: replica, transport: InMemorySyncTransport(scope: "icloud", store: iCloud)
        )
    }

    private func s3Coordinator(
        _ replica: NotebookReplica, device: String
    ) -> NotebookSyncCoordinator {
        NotebookSyncCoordinator(replica: replica, transport: S3SyncTransport(
            configuration: S3SyncConfiguration(
                endpoint: s3.endpoint, region: "us-east-1", bucket: "notes", prefix: "meh"
            ),
            credentials: S3Credentials(accessKeyID: "test", secretAccessKey: "test"),
            stateDirectory: replica.directory.appending(path: "S3"),
            session: s3.session
        ))
    }

    private func synchronize(
        _ replica: NotebookReplica, _ coordinator: NotebookSyncCoordinator
    ) async throws {
        await coordinator.synchronize()
        if let error = coordinator.lastError { throw error }
    }
}
