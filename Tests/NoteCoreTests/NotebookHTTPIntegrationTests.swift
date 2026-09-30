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

    private func assertSuccess(_ coordinator: NotebookSyncCoordinator) throws {
        if case .failed(let message) = coordinator.status {
            XCTFail(message)
            throw SyncError.unavailable(message)
        }
    }
}
