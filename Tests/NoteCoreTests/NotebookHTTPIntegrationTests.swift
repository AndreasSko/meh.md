import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class NotebookHTTPIntegrationTests: XCTestCase {
    func testRealServiceRoundTripAcrossReplicaRestarts() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["MEH_NOTEBOOK_HTTP_URL"],
            let url = URL(string: endpoint), url.host == "127.0.0.1"
        else {
            throw XCTSkip("Set MEH_NOTEBOOK_HTTP_URL to a disposable loopback service")
        }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = LocalSyncTransport(
            baseURL: url, workspace: "notebook-\(UUID().uuidString)", pageSize: 1,
            protocolVersion: 2)
        let left = NotebookReplica(directory: root.appending(path: "left"))
        let right = NotebookReplica(directory: root.appending(path: "right"))
        let a = NotebookSyncCoordinator(replica: left, transport: transport)
        let b = NotebookSyncCoordinator(replica: right, transport: transport)
        await a.synchronize()
        await b.synchronize()
        try assertSuccess(a)
        try assertSuccess(b)
        let folder = try await left.createFolder(name: "Café")
        let id = try await left.createNote(name: "Unicode.md", text: "one two 👋🏽", parentID: folder)
        await a.synchronize()
        await b.synchronize()
        try assertSuccess(b)
        let leftNote = try await left.openNote(id)
        let rightNote = try await right.openNote(id)
        try leftNote.replaceText(in: NSRange(location: 0, length: 3), with: "ONE")
        try rightNote.replaceText(in: NSRange(location: 4, length: 3), with: "TWO")
        try await leftNote.flush()
        try await rightNote.flush()
        let reopenedLeft = NotebookReplica(directory: left.directory)
        let reopenedRight = NotebookReplica(directory: right.directory)
        let reopenedA = NotebookSyncCoordinator(replica: reopenedLeft, transport: transport)
        let reopenedB = NotebookSyncCoordinator(replica: reopenedRight, transport: transport)
        await reopenedA.synchronize()
        await reopenedB.synchronize()
        await reopenedA.synchronize()
        try assertSuccess(reopenedA)
        try assertSuccess(reopenedB)
        let finalLeft = try await reopenedLeft.openNote(id)
        let finalRight = try await reopenedRight.openNote(id)
        XCTAssertEqual(finalLeft.text, "ONE TWO 👋🏽")
        XCTAssertEqual(finalLeft.text, finalRight.text)
        XCTAssertEqual(reopenedLeft.placements, reopenedRight.placements)
    }

    func testLegacyActivationAndFolderSyncAcrossDevices() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["MEH_NOTEBOOK_HTTP_URL"],
              let url = URL(string: endpoint), url.host == "127.0.0.1" else {
            throw XCTSkip("Set MEH_NOTEBOOK_HTTP_URL to a disposable loopback service")
        }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = "activation-\(UUID().uuidString)"
        let v1 = LocalSyncTransport(baseURL: url, workspace: workspace)
        let v2 = LocalSyncTransport(baseURL: url, workspace: workspace, protocolVersion: 2)
        let oldDirectory = root.appending(path: "old")
        let old = NoteSession(storage: NoteFileStorage(directory: oldDirectory))
        await old.load()
        try old.replaceAll(with: "Existing note")
        try await old.flush()
        let oldSync = NoteSyncCoordinator(session: old, transport: v1,
            stateURL: oldDirectory.appending(path: "sync-state.json"))
        await oldSync.synchronize()
        if case .failed(let message) = oldSync.status { XCTFail(message) }
        let bridge = NotebookLegacyBridge(directory: root.appending(path: "bridge"),
            legacyDirectory: oldDirectory)
        let legacy = try await bridge.synchronize(legacyTransport: v1, notebookScope: v2.scope)
        let left = NotebookReplica(directory: root.appending(path: "left"))
        let a = NotebookSyncCoordinator(replica: left, transport: v2)
        await a.synchronize(legacyNote: legacy)
        try assertSuccess(a)
        let folder = try await left.createFolder(name: "Work")
        let id = try await left.createNote(name: "Plan.md", text: "Folder content", parentID: folder)
        await a.synchronize(legacyNote: legacy)
        try assertSuccess(a)
        let secondBridge = NotebookLegacyBridge(directory: root.appending(path: "bridge2"),
            legacyDirectory: root.appending(path: "empty"))
        let secondLegacy = try await secondBridge.synchronize(
            legacyTransport: v1, notebookScope: v2.scope)
        let right = NotebookReplica(directory: root.appending(path: "right"))
        let b = NotebookSyncCoordinator(replica: right, transport: v2)
        await b.synchronize(legacyNote: secondLegacy)
        try assertSuccess(b)
        XCTAssertEqual(left.placements, right.placements)
        let note = try await right.openNote(id)
        XCTAssertEqual(note.text, "Folder content")
        let imported = try await right.openNote(legacy.noteID)
        XCTAssertEqual(imported.text, "Existing note")
        try old.replaceAll(with: "Late old-client edit")
        try await old.flush()
        await oldSync.synchronize()
        let late = try await bridge.synchronize(legacyTransport: v1, notebookScope: v2.scope)
        await a.synchronize(legacyNote: late)
        await b.synchronize(legacyNote: secondLegacy)
        try assertSuccess(a)
        try assertSuccess(b)
        XCTAssertEqual(imported.text, "Late old-client edit")
        XCTAssertEqual(note.text, "Folder content")
    }

    private func assertSuccess(_ coordinator: NotebookSyncCoordinator) throws {
        if case .failed(let message) = coordinator.status {
            XCTFail(message)
            throw SyncError.unavailable(message)
        }
    }
}
