import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class MarkdownCopyControllerTests: XCTestCase {
    private let noteID = UUID(
        uuidString: "93E3DA38-F4A5-4A34-8E1A-F591EF2646B0"
    )!

    func testStartRequiresMacDestination() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = fixture.controller()

        await controller.start()

        XCTAssertEqual(controller.status, .notConfigured)
        XCTAssertNil(controller.destinationURL)
        XCTAssertFalse(controller.isBusy)
    }

    func testChosenDestinationPublishesLatestPersistedSnapshot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = fixture.controller()
        await controller.start()
        try await controller.chooseDirectory(fixture.firstDestination)

        controller.submit(try snapshot(text: "first"))
        controller.submit(try snapshot(text: "latest 👨‍👩‍👧‍👦"))
        await controller.waitForPendingWork()

        XCTAssertEqual(controller.status, .current)
        XCTAssertEqual(
            try String(contentsOf: fixture.firstCopy, encoding: .utf8),
            "latest 👨‍👩‍👧‍👦"
        )
        XCTAssertEqual(controller.destinationURL, fixture.firstCopy)
    }

    func testInFlightOlderSnapshotNeverReportsCurrent() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = OperationGate()
        var completedStatuses: [MarkdownCopyController.Status] = []
        let controller = fixture.controller(
            beforeOperation: { await gate.wait() },
            operationStatusChanged: { completedStatuses.append($0) }
        )
        await controller.start()
        try await controller.chooseDirectory(fixture.firstDestination)

        controller.submit(try snapshot(text: "first"))
        await gate.waitUntilEntered()
        controller.submit(try snapshot(text: "latest"))
        await gate.open()
        await controller.waitForPendingWork()

        XCTAssertEqual(completedStatuses, [.updating, .current])
        XCTAssertEqual(
            try String(contentsOf: fixture.firstCopy, encoding: .utf8),
            "latest"
        )
    }

    func testRestartOverwritesExternalEditsWithSavedText() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = fixture.controller()
        await original.start()
        try await original.chooseDirectory(fixture.firstDestination)
        let persisted = try snapshot(text: "saved")
        original.submit(persisted)
        await original.waitForPendingWork()
        try Data("outside".utf8).write(to: fixture.firstCopy)

        let restarted = fixture.controller()
        restarted.submit(persisted)
        await restarted.start()
        await restarted.waitForPendingWork()

        XCTAssertEqual(restarted.status, .current)
        XCTAssertEqual(
            try String(contentsOf: fixture.firstCopy, encoding: .utf8),
            "saved"
        )
    }

    func testActivationRestoresAnExternallyDeletedCopy() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = fixture.controller()
        await controller.start()
        try await controller.chooseDirectory(fixture.firstDestination)
        controller.submit(try snapshot(text: "saved"))
        await controller.waitForPendingWork()
        try FileManager.default.removeItem(at: fixture.firstCopy)

        controller.reconcileOnActivation()
        await controller.waitForPendingWork()

        XCTAssertEqual(controller.status, .current)
        XCTAssertEqual(try Data(contentsOf: fixture.firstCopy), Data("saved".utf8))
    }

    func testRestartPublishesNewerPersistedSnapshot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = fixture.controller()
        await original.start()
        try await original.chooseDirectory(fixture.firstDestination)
        original.submit(try snapshot(text: "old"))
        await original.waitForPendingWork()

        let restarted = fixture.controller()
        restarted.submit(try snapshot(text: "newer saved text"))
        await restarted.start()
        await restarted.waitForPendingWork()

        XCTAssertEqual(restarted.status, .current)
        XCTAssertEqual(
            try String(contentsOf: fixture.firstCopy, encoding: .utf8),
            "newer saved text"
        )
    }

    func testPreexistingFileIsNeverClaimed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("belongs to someone else".utf8).write(
            to: fixture.firstCopy
        )
        let controller = fixture.controller()
        await controller.start()
        try await controller.chooseDirectory(fixture.firstDestination)

        controller.submit(try snapshot(text: "saved note"))
        await controller.waitForPendingWork()

        XCTAssertEqual(controller.status, .paused(.preexistingFile))
        XCTAssertEqual(
            try String(contentsOf: fixture.firstCopy, encoding: .utf8),
            "belongs to someone else"
        )
    }

    func testNewDestinationPreservesOldCopyAndUsesNewMetadata() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = fixture.controller()
        await controller.start()
        try await controller.chooseDirectory(fixture.firstDestination)
        controller.submit(try snapshot(text: "portable"))
        await controller.waitForPendingWork()
        let firstID = try fixture.destinationUUID()

        try await controller.chooseDirectory(fixture.secondDestination)
        await controller.waitForPendingWork()
        let secondID = try fixture.destinationUUID()

        XCTAssertNotEqual(firstID, secondID)
        XCTAssertEqual(
            try String(contentsOf: fixture.firstCopy, encoding: .utf8),
            "portable"
        )
        XCTAssertEqual(
            try String(contentsOf: fixture.secondCopy, encoding: .utf8),
            "portable"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.metadataDirectory(for: firstID).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.metadataDirectory(for: secondID).path
            )
        )
    }

    func testChangedFolderIdentityRequiresReconnect() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = fixture.controller()
        await controller.start()
        try await controller.chooseDirectory(fixture.firstDestination)
        try fixture.changePersistedInode()

        let restarted = fixture.controller()
        await restarted.start()

        guard case .reconnectRequired = restarted.status else {
            return XCTFail("A different folder identity must require reconnect")
        }
        XCTAssertNil(restarted.destinationURL)
    }

    func testRegrantingSameFolderReusesManagedDestination() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = fixture.controller()
        await original.start()
        try await original.chooseDirectory(fixture.firstDestination)
        let persisted = try snapshot(text: "managed")
        original.submit(persisted)
        await original.waitForPendingWork()
        let destinationID = try fixture.destinationUUID()
        try fixture.invalidateBookmark()

        let restarted = fixture.controller()
        restarted.submit(persisted)
        await restarted.start()
        guard case .reconnectRequired = restarted.status else {
            return XCTFail("An invalid bookmark must require reconnect")
        }

        try await restarted.chooseDirectory(fixture.firstDestination)
        await restarted.waitForPendingWork()

        XCTAssertEqual(restarted.status, .current)
        XCTAssertEqual(try fixture.destinationUUID(), destinationID)
        XCTAssertEqual(
            try String(contentsOf: fixture.firstCopy, encoding: .utf8),
            "managed"
        )
    }

    func testInvalidConfigurationDoesNotClaimExistingCopy() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.support,
            withIntermediateDirectories: true
        )
        try Data("invalid configuration".utf8).write(
            to: fixture.configurationURL
        )
        try Data("existing copy".utf8).write(to: fixture.firstCopy)
        let controller = fixture.controller()

        await controller.start()
        controller.submit(try snapshot(text: "saved note"))
        await controller.waitForPendingWork()

        guard case .reconnectRequired = controller.status else {
            return XCTFail("Invalid configuration must require reconnect")
        }
        XCTAssertEqual(
            try String(contentsOf: fixture.firstCopy, encoding: .utf8),
            "existing copy"
        )
    }

    private func snapshot(text: String) throws -> NoteSnapshot {
        try NoteDocument(noteID: noteID, text: text).snapshot()
    }
}

private struct Fixture {
    let root: URL
    let support: URL
    let documents: URL
    let firstDestination: URL
    let secondDestination: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "MarkdownCopyControllerTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        support = root.appending(path: "support", directoryHint: .isDirectory)
        documents = root.appending(
            path: "documents",
            directoryHint: .isDirectory
        )
        firstDestination = root.appending(
            path: "first",
            directoryHint: .isDirectory
        )
        secondDestination = root.appending(
            path: "second",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: documents,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: firstDestination,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: secondDestination,
            withIntermediateDirectories: true
        )
    }

    var firstCopy: URL { firstDestination.appending(path: "note.md") }
    var secondCopy: URL { secondDestination.appending(path: "note.md") }
    var configurationURL: URL {
        support.appending(path: "configuration.json")
    }

    @MainActor
    func controller(
        beforeOperation: (() async -> Void)? = nil,
        operationStatusChanged: ((MarkdownCopyController.Status) -> Void)? = nil
    ) -> MarkdownCopyController {
        MarkdownCopyController(
            applicationSupportDirectory: support,
            documentsDirectory: documents,
            usesSecurityScopedBookmarks: false,
            beforeOperation: beforeOperation,
            operationStatusChanged: operationStatusChanged
        )
    }

    func destinationUUID() throws -> UUID {
        let object = try JSONSerialization.jsonObject(
            with: Data(contentsOf: configurationURL)
        )
        let dictionary = try XCTUnwrap(object as? [String: Any])
        let value = try XCTUnwrap(dictionary["destinationUUID"] as? String)
        return try XCTUnwrap(UUID(uuidString: value))
    }

    func changePersistedInode() throws {
        let data = try Data(contentsOf: configurationURL)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var identity = try XCTUnwrap(object["identity"] as? [String: Any])
        let inode = try XCTUnwrap(identity["inode"] as? NSNumber)
        identity["inode"] = inode.uint64Value + 1
        object["identity"] = identity
        try JSONSerialization.data(withJSONObject: object).write(
            to: configurationURL,
            options: .atomic
        )
    }

    func invalidateBookmark() throws {
        let data = try Data(contentsOf: configurationURL)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["bookmark"] = Data("invalid bookmark".utf8).base64EncodedString()
        try JSONSerialization.data(withJSONObject: object).write(
            to: configurationURL,
            options: .atomic
        )
    }

    func metadataDirectory(for id: UUID) -> URL {
        support.appending(path: "Destinations/\(id.uuidString)")
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor OperationGate {
    private var isOpen = false
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
