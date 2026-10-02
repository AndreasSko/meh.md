import CloudKit
import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class NotebookOfflineJoinTests: XCTestCase {
    nonisolated(unsafe) private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    func testOfflineNotesBecomeTheFirstCloudNotebookWithoutChangingBodies() async throws {
        let local = NotebookReplica(directory: directory())
        try await local.createNotebookForSync()
        let originalID = try XCTUnwrap(local.catalogSnapshot).notebookID
        let noteID = try await local.createNote(name: "First.md", text: "# Café 👋🏽\r\n")
        let session = try await local.openNote(noteID)
        try session.replaceAll(with: "# Café 👋🏽\r\n\r\nWritten offline.\r\n")
        try await session.flush()
        let before = session.currentSnapshot
        let transport = InMemorySyncTransport(scope: "first-cloud")
        let sync = NotebookSyncCoordinator(replica: local, transport: transport)

        await sync.synchronize()

        assertSuccess(sync)
        XCTAssertTrue(try sync.hasDurableBinding())
        XCTAssertEqual(local.catalogSnapshot?.notebookID, originalID)
        XCTAssertEqual(session.currentSnapshot, before)
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            local.directory.appending(path: "offline-notebook.json").path))
        let second = NotebookReplica(directory: directory())
        let secondSync = NotebookSyncCoordinator(replica: second, transport: transport)
        await secondSync.synchronize()
        assertSuccess(secondSync)
        let received = try await second.openNote(noteID)
        XCTAssertEqual(received.text, session.text)
        XCTAssertEqual(received.currentSnapshot?.heads, before?.heads)
    }

    func testExistingCloudKeepsOfflineHierarchyTemplatesLinksTrashAndHistory() async throws {
        let transport = InMemorySyncTransport(scope: "existing-cloud")
        let remote = NotebookReplica(directory: directory())
        let remoteSync = NotebookSyncCoordinator(replica: remote, transport: transport)
        await remoteSync.synchronize()
        let cloudNote = try await remote.createNote(name: "Plan.md", text: "Existing cloud note")
        await remoteSync.synchronize()
        let cloudID = try XCTUnwrap(remote.catalogSnapshot).notebookID

        let local = NotebookReplica(directory: directory())
        try await local.createNotebookForSync()
        let folder = try await local.createFolder(name: "Offline")
        let noteID = try await local.createNote(name: "Draft.md", text: "[[Old]]", parentID: folder)
        let old = try await local.createNote(name: "Old.md", text: "Original", parentID: folder)
        try await local.rename(old, to: "Renamed.md")
        try await local.setTemplateSource(folder, enabled: true)
        try await local.setTemplateSettings(.init(destination: .folder(folder),
            filenamePattern: "{{date}} {{template}}"), for: folder)
        try await local.setDefaultNewNoteParentID(folder)
        try await local.setPinnedInRecents(true, for: noteID)
        let trashed = try await local.createNote(name: "Trash.md", text: "Still recoverable")
        _ = try await local.trashItems([trashed])
        let deleted = try await local.createNote(name: "Deleted.md", text: "Do not revive")
        _ = try await local.trashItems([deleted])
        try await local.permanentlyDelete(local.deletionSelection(rootIDs: [deleted]))
        let session = try await local.openNote(noteID)
        try session.replaceAll(with: "[[Old]]\n\nLatest offline revision")
        try await session.flush()
        let before = session.currentSnapshot
        let templates = local.templates
        let links = local.linkNotes
        let sync = NotebookSyncCoordinator(replica: local, transport: transport)

        await sync.synchronize()

        assertSuccess(sync)
        XCTAssertEqual(local.catalogSnapshot?.notebookID, cloudID)
        XCTAssertTrue(try sync.hasDurableBinding())
        let stillOpen = try await local.openNote(noteID)
        XCTAssertTrue(stillOpen === session)
        XCTAssertEqual(session.currentSnapshot, before)
        XCTAssertEqual(local.templates, templates)
        XCTAssertEqual(local.defaultNewNoteParentID, folder)
        XCTAssertTrue(local.recentNotes.contains { $0.id == noteID && $0.isPinned })
        XCTAssertEqual(local.linkNotes.filter { $0.id != cloudNote }, links)
        XCTAssertTrue(local.placements.contains { $0.item.id == trashed && $0.isInTrash })
        XCTAssertTrue(try local.deletedIDs.contains(deleted))
        let cloudBody = try await local.openNote(cloudNote)
        XCTAssertEqual(cloudBody.text, "Existing cloud note")
        await remoteSync.synchronize()
        assertSuccess(remoteSync)
        let uploaded = try await remote.openNote(noteID)
        XCTAssertEqual(uploaded.currentSnapshot?.heads, before?.heads)
        XCTAssertEqual(remote.templates, templates)

        let reopened = NotebookReplica(directory: local.directory)
        try await reopened.load()
        XCTAssertEqual(reopened.catalogSnapshot?.notebookID, cloudID)
        XCTAssertTrue(try reopened.deletedIDs.contains(deleted))
        let reopenedBody = try await reopened.openNote(noteID)
        XCTAssertEqual(reopenedBody.text, session.text)
    }

    func testTwoIndependentOfflineDevicesConvergeInEitherConnectionOrder() async throws {
        for reversed in [false, true] {
            let transport = InMemorySyncTransport(scope: "two-\(reversed)")
            let left = NotebookReplica(directory: directory())
            let right = NotebookReplica(directory: directory())
            try await left.createNotebookForSync()
            try await right.createNotebookForSync()
            let a = try await left.createNote(name: "Same.md", text: "From left")
            let b = try await right.createNote(name: "Same.md", text: "From right")
            let first = reversed ? right : left
            let second = reversed ? left : right
            let firstSync = NotebookSyncCoordinator(replica: first, transport: transport)
            let secondSync = NotebookSyncCoordinator(replica: second, transport: transport)

            await firstSync.synchronize()
            await secondSync.synchronize()
            await firstSync.synchronize()

            assertSuccess(firstSync)
            assertSuccess(secondSync)
            XCTAssertEqual(left.catalogSnapshot?.notebookID, right.catalogSnapshot?.notebookID)
            XCTAssertEqual(Set(left.placements.map { $0.item.id }), [a, b])
            XCTAssertEqual(Set(right.placements.map { $0.item.id }), [a, b])
            XCTAssertEqual(Set(left.placements.map(\.displayName)).count, 2)
            let aBody = try await right.openNote(a)
            let bBody = try await left.openNote(b)
            XCTAssertEqual(aBody.text, "From left")
            XCTAssertEqual(bBody.text, "From right")
        }
    }

    func testEveryInterruptedJoinStageResumesOnceAfterRestart() async throws {
        for stage in NotebookOfflineJoinStage.allCases {
            let transport = InMemorySyncTransport(scope: "interrupted-\(stage)")
            let remote = NotebookReplica(directory: directory())
            let remoteSync = NotebookSyncCoordinator(replica: remote, transport: transport)
            await remoteSync.synchronize()
            let remoteID = try await remote.createNote(name: "Cloud.md", text: "Cloud")
            await remoteSync.synchronize()
            let local = NotebookReplica(directory: directory())
            try await local.createNotebookForSync()
            let localID = try await local.createNote(name: "Local.md", text: "Local")
            let session = try await local.openNote(localID)
            try session.replaceAll(with: "Latest unsynced body")
            // Leave the idle save pending: recovery must preserve typing
            // instead of using reset's intentional save cancellation.
            if stage == .bindingSaved { try await session.flush() }
            local.offlineJoinFaultInjector = { observed in
                if observed == stage { throw POSIXError(.EIO) }
            }
            let failed = NotebookSyncCoordinator(replica: local, transport: transport)

            await failed.synchronize()
            XCTAssertNotNil(failed.lastError, "\(stage)")
            if stage != .bindingSaved {
                let interrupted = try XCTUnwrap(
                    failed.lastError as? NotebookOfflineJoinInterrupted)
                XCTAssertEqual((interrupted.underlyingError as? POSIXError)?.code, .EIO)
                XCTAssertTrue(local.localEditsSuspended)
                XCTAssertEqual(session.persistedSnapshot, session.currentSnapshot)
                let explanation = SyncFailurePresentation(error: interrupted,
                    retryWillOccurAutomatically: true)
                XCTAssertEqual(String(localized: explanation.title),
                               "Restart to finish sync setup")
                XCTAssertEqual(explanation.retryDisposition, .unavailable)
            }
            let reopened = NotebookReplica(directory: local.directory)
            try await reopened.load()
            let resumed = NotebookSyncCoordinator(replica: reopened, transport: transport)
            await resumed.synchronize()
            assertSuccess(resumed)
            await resumed.synchronize()
            assertSuccess(resumed)
            XCTAssertEqual(Set(reopened.placements.map { $0.item.id }), [localID, remoteID])
            let body = try await reopened.openNote(localID)
            XCTAssertEqual(body.text, "Latest unsynced body", "\(stage)")
            XCTAssertTrue(try resumed.hasDurableBinding())
        }
    }

    func testBoundNotebookDoesNotMoveToAnotherAccount() async throws {
        let local = NotebookReplica(directory: directory())
        try await local.createNotebookForSync()
        let note = try await local.createNote(name: "Private.md", text: "Account A only")
        let original = NotebookSyncCoordinator(replica: local,
            transport: InMemorySyncTransport(scope: "account-a"))
        await original.synchronize()
        assertSuccess(original)
        let before = local.catalogSnapshot
        let otherTransport = InMemorySyncTransport(scope: "account-b")
        let other = NotebookSyncCoordinator(replica: local, transport: otherTransport)

        await other.synchronize()

        XCTAssertEqual(other.lastError as? SyncError, .scopeChanged)
        XCTAssertEqual(local.catalogSnapshot, before)
        let fresh = NotebookReplica(directory: directory())
        let freshSync = NotebookSyncCoordinator(replica: fresh, transport: otherTransport)
        await freshSync.synchronize()
        assertSuccess(freshSync)
        XCTAssertFalse(fresh.placements.contains { $0.item.id == note })
    }

    func testCorruptReceiptCannotAuthorizeReplacingLocalNotes() async throws {
        let local = NotebookReplica(directory: directory())
        try await local.createNotebookForSync()
        _ = try await local.createNote(name: "Keep.md", text: "Keep me")
        let before = local.catalogSnapshot
        try Data("broken".utf8).write(to:
            local.directory.appending(path: "offline-notebook.json"))
        let sync = NotebookSyncCoordinator(replica: local,
            transport: InMemorySyncTransport(scope: "damaged-receipt"))

        await sync.synchronize()

        XCTAssertNotNil(sync.lastError)
        XCTAssertEqual(local.catalogSnapshot, before)
    }

    func testRealCloudKitAdapterJoinsExistingNotebookAfterAccountBecomesAvailable() async throws {
        let server = try FakeCloudKitServer(directory: directory())
        let remote = NotebookReplica(directory: directory())
        let remoteTransport = try await CloudKitSyncTransport.makeNotebook(
            services: server.services, containerIdentifier: server.containerIdentifier,
            stateDirectory: remote.directory.appending(path: "CloudKit"))
        let remoteSync = NotebookSyncCoordinator(replica: remote, transport: remoteTransport)
        await remoteSync.synchronize()
        let remoteID = try await remote.createNote(name: "Cloud.md", text: "Already synced")
        await remoteSync.synchronize()
        assertSuccess(remoteSync)
        let local = NotebookReplica(directory: directory())
        try await local.createNotebookForSync()
        let localID = try await local.createNote(name: "Local.md", text: "Before account activation")

        server.setAccountStatus(.noAccount)
        do {
            _ = try await CloudKitSyncTransport.makeNotebook(
                services: server.services, containerIdentifier: server.containerIdentifier,
                stateDirectory: local.directory.appending(path: "CloudKit"))
            XCTFail("Expected unavailable-account setup failure")
        } catch {
            XCTAssertEqual(error as? CloudKitSyncTransportError, .accountUnavailable)
        }
        let offline = try await local.openNote(localID)
        XCTAssertEqual(offline.text, "Before account activation")
        server.setAccountStatus(.available)
        let localTransport = try await CloudKitSyncTransport.makeNotebook(
            services: server.services, containerIdentifier: server.containerIdentifier,
            stateDirectory: local.directory.appending(path: "CloudKit"))
        let localSync = NotebookSyncCoordinator(replica: local, transport: localTransport)
        await localSync.synchronize()
        assertSuccess(localSync)
        await remoteSync.synchronize()
        assertSuccess(remoteSync)

        XCTAssertEqual(Set(local.placements.map { $0.item.id }), [localID, remoteID])
        XCTAssertEqual(Set(remote.placements.map { $0.item.id }), [localID, remoteID])
        let uploaded = try await remote.openNote(localID)
        XCTAssertEqual(uploaded.text, offline.text)
        await localTransport.retire()
        await remoteTransport.retire()
    }

    func testInterruptedImportWaitsForRecoveryAndKeepsImportedLinkScope() async throws {
        let transport = InMemorySyncTransport(scope: "import-first-join")
        let remote = NotebookReplica(directory: directory())
        let remoteSync = NotebookSyncCoordinator(replica: remote, transport: transport)
        await remoteSync.synchronize()
        let local = NotebookReplica(directory: directory())
        try await local.createNotebookForSync()
        let folderID = UUID()
        let noteID = UUID()
        let plan = NotebookImportPlan(id: UUID(), entries: [
            .init(id: folderID, kind: .folder, name: "Imported", parentID: nil, text: nil),
            .init(id: noteID, kind: .note, name: "Example.md", parentID: folderID,
                  text: "# Imported\r\n[[Example]]\r\n")
        ], skippedPaths: [])
        local.importFaultInjector = { stage in
            if stage == .beforeCatalog { throw POSIXError(.EIO) }
        }
        do { try await local.importMarkdown(plan); XCTFail("Expected interrupted import") }
        catch { XCTAssertTrue(local.hasPendingImport) }
        let before = local.catalogSnapshot
        let sync = NotebookSyncCoordinator(replica: local, transport: transport)
        await sync.synchronize()
        XCTAssertEqual(sync.lastError as? NotebookImportError, .pendingImportExists)
        XCTAssertEqual(local.catalogSnapshot, before)
        XCTAssertFalse(local.localEditsSuspended)

        local.importFaultInjector = nil
        try await local.resumePendingImport()
        await sync.synchronize()
        assertSuccess(sync)

        XCTAssertEqual(local.placements.first { $0.item.id == noteID }?.item.importRootID, folderID)
        let body = try await local.openNote(noteID)
        XCTAssertEqual(body.text, "# Imported\r\n[[Example]]\r\n")
    }

    func testRetainedImportRecoveryAndPostJoinEditsSurviveBindingRestart() async throws {
        let transport = InMemorySyncTransport(scope: "retained-import")
        let remote = NotebookReplica(directory: directory())
        let remoteSync = NotebookSyncCoordinator(replica: remote, transport: transport)
        await remoteSync.synchronize()
        let local = NotebookReplica(directory: directory())
        try await local.createNotebookForSync()
        let id = UUID()
        let plan = NotebookImportPlan(id: UUID(), entries: [
            .init(id: id, kind: .note, name: "Original.md", parentID: nil, text: "Retained import")
        ], skippedPaths: [])
        local.importFaultInjector = { stage in
            if stage == .catalogSaved { throw POSIXError(.EIO) }
        }
        do { try await local.importMarkdown(plan); XCTFail("Expected retained import") }
        catch { XCTAssertTrue(local.hasPendingImport) }
        local.importFaultInjector = nil
        let retained = try await local.setAsidePendingImport()
        local.offlineJoinFaultInjector = { stage in
            if stage == .bindingSaved { throw POSIXError(.EIO) }
        }
        await NotebookSyncCoordinator(replica: local, transport: transport).synchronize()
        let rebound = try JSONDecoder().decode(NotebookImportJournal.self, from: Data(contentsOf: retained))
        XCTAssertEqual(rebound.notebookID, remote.catalogSnapshot?.notebookID)
        local.offlineJoinFaultInjector = nil
        try await local.rename(id, to: "Edited after joining.md")
        let next = try await local.createNote(name: "Later.md", text: "After the catalog handoff")
        let reopened = NotebookReplica(directory: local.directory)
        try await reopened.load()
        let sync = NotebookSyncCoordinator(replica: reopened, transport: transport)
        await sync.synchronize()
        assertSuccess(sync)
        XCTAssertEqual(reopened.placements.first { $0.item.id == id }?.item.name,
                       "Edited after joining.md")
        XCTAssertTrue(reopened.placements.contains { $0.item.id == next })
        _ = try await reopened.trashItems([id])
        try await reopened.permanentlyDelete(reopened.deletionSelection(rootIDs: [id]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: retained.path))
    }

    func testMarkdownCopiesResumeAfterJoinRestartAndRejectAnotherNotebooksFolder() async throws {
        let transport = InMemorySyncTransport(scope: "markdown-join")
        let remote = NotebookReplica(directory: directory())
        let remoteSync = NotebookSyncCoordinator(replica: remote, transport: transport)
        await remoteSync.synchronize()
        let local = NotebookReplica(directory: directory())
        try await local.createNotebookForSync()
        _ = try await local.createNote(name: "Local.md", text: "# Locally saved\r\n")
        let copies = NotebookMarkdownPublisher(directory: directory())
        try await copies.publish(catalog: XCTUnwrap(local.catalogSnapshot),
                                placements: local.placements, notes: local.persistedNoteSnapshots())
        let sync = NotebookSyncCoordinator(replica: local, transport: transport)
        await sync.synchronize()
        assertSuccess(sync)
        let reopened = NotebookReplica(directory: local.directory)
        try await reopened.load()
        try await reopened.prepareMarkdownCopiesForFirstSync(copies)
        try await reopened.prepareMarkdownCopiesForFirstSync(copies)
        try await copies.publish(catalog: XCTUnwrap(reopened.catalogSnapshot),
                                 placements: reopened.placements, notes: reopened.persistedNoteSnapshots())
        XCTAssertEqual(try Data(contentsOf: copies.directory.appending(path: "Markdown/Local.md")),
                       Data("# Locally saved\r\n".utf8))

        let foreign = NotebookReplica(directory: directory())
        try await foreign.createLocalNotebook()
        _ = try await foreign.createNote(name: "Foreign.md", text: "Do not touch")
        let foreignCopies = NotebookMarkdownPublisher(directory: directory())
        try await foreignCopies.publish(catalog: XCTUnwrap(foreign.catalogSnapshot),
            placements: foreign.placements, notes: foreign.persistedNoteSnapshots())
        do {
            try await reopened.prepareMarkdownCopiesForFirstSync(foreignCopies)
            XCTFail("Expected foreign notebook refusal")
        } catch {
            XCTAssertEqual(error as? NotebookMarkdownPublisherError, .notebookIdentityMismatch)
        }
        XCTAssertEqual(try String(contentsOf: foreignCopies.directory.appending(path: "Markdown/Foreign.md"),
                                  encoding: .utf8), "Do not touch")
    }

    private func directory() -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        roots.append(root)
        return root
    }

    private func assertSuccess(_ sync: NotebookSyncCoordinator,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(sync.lastError, "\(String(describing: sync.lastError))", file: file, line: line)
        guard case .exchanged = sync.status else {
            return XCTFail("Expected completed sync: \(sync.status)", file: file, line: line)
        }
    }
}
