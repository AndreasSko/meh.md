import CloudKit
import Foundation
import XCTest

@testable import NoteCore

/// One device removes redundant iCloud copies right after creating and
/// editing a note. The other device must still receive the note.
@MainActor
final class NotebookSnapshotCleanupSyncTests: XCTestCase {
    private var root: URL!
    private var server: FakeCloudKitServer!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "SnapshotCleanupSync-\(UUID())"
        )
        server = try FakeCloudKitServer(directory: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testNoteCreatedAndEditedAroundCleanupReachesPeer() async throws {
        let mac = try await open("mac")
        var phone = try await open("phone")
        await mac.coordinator.synchronize()
        await phone.coordinator.synchronize()
        let older = try await mac.replica.createNote(name: "older.md", text: "older\n")
        await mac.coordinator.synchronize()
        _ = try await mac.coordinator.cleanupSnapshots()

        // The phone is suspended while it fetches, then relaunched.
        server.inject(.crashAfterFetchedChanges)
        await phone.coordinator.synchronize()
        phone = try await phone.restarted(server: server)

        let new = try await mac.replica.createNote(name: "new.md", text: "new\n")
        await mac.coordinator.synchronize()
        let session = try await mac.replica.openNote(new)
        try session.replaceText(
            in: NSRange(location: session.text.utf16.count, length: 0),
            with: "edited\n"
        )
        try await session.flush()
        await mac.coordinator.synchronize()
        _ = try await mac.coordinator.cleanupSnapshots()

        phone = try await phone.restarted(server: server)
        for _ in 0..<3 { await phone.coordinator.synchronize() }

        assertExchanged(phone.coordinator.status)
        let ids = Set(phone.replica.placements.map(\.item.id))
        XCTAssertTrue(ids.contains(older))
        XCTAssertTrue(ids.contains(new))
        let text = try await phone.replica.openNote(new).text
        XCTAssertEqual(text, "new\nedited\n")
    }

    /// The phone syncs at each point of the Mac's create, edit and cleanup
    /// sequence, including a cleanup interrupted after deleting on iCloud.
    func testPeerReceivesNoteWhenSyncingDuringCleanupSequence() async throws {
        for stop in 0..<5 {
            try? FileManager.default.removeItem(at: root)
            try setUpWithError()
            try await runInterleaved(phoneSyncsAfter: stop)
        }
    }

    private func runInterleaved(phoneSyncsAfter stop: Int) async throws {
        let mac = try await open("mac")
        var phone = try await open("phone")
        await mac.coordinator.synchronize()
        await phone.coordinator.synchronize()
        var step = 0
        func checkpoint() async throws {
            if step == stop {
                await phone.coordinator.synchronize()
                phone = try await phone.restarted(server: server)
            }
            step += 1
        }

        let new = try await mac.replica.createNote(name: "new.md", text: "new\n")
        await mac.coordinator.synchronize()
        try await checkpoint()
        server.inject(.crashAfterServerDelete)
        _ = try? await mac.coordinator.cleanupSnapshots()
        server.clearFaults()
        try await checkpoint()
        let session = try await mac.replica.openNote(new)
        try session.replaceText(
            in: NSRange(location: session.text.utf16.count, length: 0),
            with: "edited\n"
        )
        try await session.flush()
        await mac.coordinator.synchronize()
        try await checkpoint()
        _ = try await mac.coordinator.cleanupSnapshots()
        try await checkpoint()
        await mac.coordinator.synchronize()
        try await checkpoint()

        for _ in 0..<3 { await phone.coordinator.synchronize() }
        assertExchanged(phone.coordinator.status)
        XCTAssertTrue(
            phone.replica.placements.contains { $0.item.id == new },
            "Phone is missing the note when syncing after step \(stop)"
        )
        let text = try? await phone.replica.openNote(new).text
        XCTAssertEqual(text, "new\nedited\n", "Step \(stop)")
    }

    private func open(_ name: String) async throws -> FakeCloudKitDevice {
        try await FakeCloudKitDevice.open(root.appending(path: name), server: server)
    }

    private func assertExchanged(
        _ status: NotebookSyncCoordinator.Status,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .exchanged = status else {
            return XCTFail("Expected exchanged, got \(status)", file: file, line: line)
        }
    }
}
