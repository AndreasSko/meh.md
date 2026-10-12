import Foundation
@testable import NoteCore
import XCTest

func decodeCloudKitDiskState(at file: URL) throws -> CloudKitTransportState {
    try CloudKitStateDiskStorage(directory: file.deletingLastPathComponent())
        .decode(Data(contentsOf: file)).state
}

final class CloudKitStateDiskStorageTests: XCTestCase {
    func testMetadataCommitExcludesPayloadAndReplaysEverySlot() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let records = try (0..<6).map {
            SyncRecord(snapshot: try NoteDocument(text: "fictional note \($0)").snapshot())
        }
        var legacy = CloudKitTransportState(accountRecordName: "account", zoneName: "zone")
        for record in records { try legacy.appendToInbox(record) }
        legacy.outbox[records[0].id] = records[0]
        let firstPage = try legacy.page(after: nil, limit: 2)
        try SyncFileIO.replace(JSONEncoder().encode(legacy), at: stateURL(root))
        let before = try Data(contentsOf: stateURL(root))
        let store = try open(root)
        XCTAssertEqual(try Data(contentsOf: stateURL(root)), before,
                       "Legacy open must not perform a migration write")

        try await store.update { $0.engineState = Data("checkpoint".utf8) }
        let firstManifest = try Data(contentsOf: stateURL(root))
        let files = try payloadFiles(root)
        XCTAssertEqual(files.count, records.count, "Inbox/outbox share immutable payloads")
        let payloads = try files.map { try Data(contentsOf: $0) }
        let metadata = try object(root)
        XCTAssertEqual(metadata["diskFormatVersion"] as? Int, 1)
        let refs = try XCTUnwrap(metadata["inbox"] as? [[String: String]])
        XCTAssertEqual(refs.count, records.count)
        XCTAssertTrue(refs.allSatisfy { $0["snapshot"] == nil && $0["digest"] != nil })

        try await store.update { $0.engineState = Data("next-checkpoint".utf8) }
        XCTAssertEqual(try payloadFiles(root), files)
        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, payloads)
        XCTAssertLessThan(try Data(contentsOf: stateURL(root)).count,
                          firstManifest.count + 100)
        let reopened = try open(root)
        let state = await reopened.snapshot()
        XCTAssertEqual(state.inboxGeneration, legacy.inboxGeneration)
        XCTAssertEqual(state.inbox, records)
        XCTAssertEqual(state.outbox, legacy.outbox)
        let replay = try state.page(after: firstPage.cursor, limit: 10)
        XCTAssertEqual(replay.records, Array(records.dropFirst(2)))
    }

    func testSparseSlotsSurviveMigrationWithoutChangingCursor() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = SyncRecord(snapshot: try NoteDocument(text: "fictional history").snapshot())
        var state = CloudKitTransportState(accountRecordName: "account", zoneName: "zone")
        try state.appendToInbox(record)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(state)) as? [String: Any])
        json["inbox"] = [NSNull(), try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(record)), NSNull()]
        try SyncFileIO.replace(JSONSerialization.data(withJSONObject: json), at: stateURL(root))
        let store = try open(root)
        let old = await store.snapshot()
        let cursor = try old.page(after: nil, limit: 1).cursor
        try await store.update { $0.engineState = Data([1]) }
        let reopened = try open(root)
        let loaded = await reopened.snapshot()
        XCTAssertEqual(try loaded.page(after: cursor, limit: 1),
                       try old.page(after: cursor, limit: 1))
        XCTAssertEqual(try loaded.page(after: nil, limit: 100).cursor,
                       try old.page(after: nil, limit: 100).cursor)
    }

    func testMissingCorruptAndTraversingPayloadReferencesFailClosed() async throws {
        for mode in ["missing", "corrupt", "traversal", "future", "symlink"] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try open(root)
            let record = SyncRecord(snapshot: try NoteDocument(text: "fictional history").snapshot())
            try await store.update { try $0.appendToInbox(record) }
            let file = try XCTUnwrap(payloadFiles(root).first)
            switch mode {
            case "missing": try FileManager.default.removeItem(at: file)
            case "corrupt": try Data("bad bytes".utf8).write(to: file)
            case "symlink":
                let outside = root.appendingPathComponent("outside.json")
                try FileManager.default.moveItem(at: file, to: outside)
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
            default:
                var json = try object(root)
                if mode == "future" { json["diskFormatVersion"] = 99 }
                else { json["inbox"] = [["digest": "../outside", "recordID": record.id]] }
                try SyncFileIO.replace(JSONSerialization.data(withJSONObject: json), at: stateURL(root))
            }
            XCTAssertThrowsError(try open(root)) {
                XCTAssertEqual($0 as? CloudKitSyncTransportError, .corruptState)
            }
        }
    }

    func testFailedManifestCommitLeavesPreviousStateAndReplay() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = try open(root)
        let old = SyncRecord(snapshot: try NoteDocument(text: "old fictional note").snapshot())
        try await initial.update { try $0.appendToInbox(old) }
        let persisted = try Data(contentsOf: stateURL(root))
        let failing = try CloudKitTransportStateStore(
            directory: root, accountRecordName: "account", zoneName: "zone",
            writeState: { _, _ in throw POSIXError(.ENOSPC) }
        )
        let next = SyncRecord(snapshot: try NoteDocument(text: "new fictional note").snapshot())
        do {
            try await failing.update { try $0.appendToInbox(next) }
            XCTFail("Manifest replacement should fail")
        } catch { XCTAssertTrue(error is CloudKitStateWriteFailure) }
        XCTAssertEqual(try Data(contentsOf: stateURL(root)), persisted)
        let reopened = try open(root)
        let state = await reopened.snapshot()
        XCTAssertEqual(state.inbox, [old])
        XCTAssertEqual(try payloadFiles(root).count, 2,
                       "An unused durable payload is safe after failed manifest replacement")
    }

    func testScopeChangeIsRejectedWithExternalPayloads() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try open(root)
        let record = SyncRecord(snapshot: try NoteDocument(text: "fictional history").snapshot())
        try await store.update { try $0.appendToInbox(record) }
        XCTAssertThrowsError(try CloudKitTransportStateStore(
            directory: root, accountRecordName: "another-account", zoneName: "zone"
        )) { XCTAssertEqual($0 as? SyncError, .scopeChanged) }
    }

    func testCancelledMigrationDoesNotReplaceManifestOrRetireStore() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var legacy = CloudKitTransportState(accountRecordName: "account", zoneName: "zone")
        let record = SyncRecord(snapshot: try NoteDocument(text: "fictional history").snapshot())
        try legacy.appendToInbox(record)
        try SyncFileIO.replace(JSONEncoder().encode(legacy), at: stateURL(root))
        let bytes = try Data(contentsOf: stateURL(root))
        let store = try open(root)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await store.update { $0.engineState = Data([1]) }
        }
        do {
            try await task.value
            XCTFail("Cancelled migration should stop")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: stateURL(root)), bytes)
        try await store.update { $0.engineState = Data([2]) }
        let reopened = try open(root)
        let state = await reopened.snapshot()
        XCTAssertEqual(state.inbox, [record])
        XCTAssertEqual(state.engineState, Data([2]))
    }

    private func open(_ root: URL) throws -> CloudKitTransportStateStore {
        try CloudKitTransportStateStore(directory: root, accountRecordName: "account", zoneName: "zone")
    }

    private func stateURL(_ root: URL) -> URL {
        root.appendingPathComponent("cloudkit-sync-state.json")
    }

    private func object(_ root: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL(root)))
                      as? [String: Any])
    }

    private func payloadFiles(_ root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("cloudkit-sync-payloads"),
            includingPropertiesForKeys: nil
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CloudKitDisk-\(UUID())")
    }
}
