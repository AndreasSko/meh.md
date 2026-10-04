import Foundation
@testable import NoteCore
import XCTest

final class CloudKitStateValidationTests: XCTestCase {
    @MainActor
    func testOpeningStoreLeavesMainActorBeforeDiskWork() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await CloudKitTransportStateStore.open(
            directory: directory, accountRecordName: "account", zoneName: "zone",
            writeState: { data, url in
                XCTAssertFalse(Thread.isMainThread)
                try data.write(to: url)
            }
        )
        let state = await store.snapshot()
        XCTAssertEqual(state.accountRecordName, "account")
        let reopened = try await CloudKitTransportStateStore.open(
            directory: directory, accountRecordName: "account", zoneName: "zone"
        )
        let persisted = await reopened.snapshot()
        XCTAssertEqual(persisted, state)
    }

    func testChangedInboxPayloadOrHeadsCannotReuseValidation() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try makeRecord(text: "trusted inbox record")
        let store = try CloudKitTransportStateStore(
            directory: directory, accountRecordName: "account", zoneName: "zone"
        )
        try await store.update { try $0.appendToInbox(original) }
        let trusted = await store.snapshot()
        let fileURL = directory.appendingPathComponent("cloudkit-sync-state.json")
        let persisted = try Data(contentsOf: fileURL)

        let changedPayload = try alteredRecord(original) { json in
            var snapshot = try XCTUnwrap(json["snapshot"] as? [String: Any])
            snapshot["data"] = Data("different bytes".utf8).base64EncodedString()
            json["snapshot"] = snapshot
        }
        let changedHeads = try alteredRecord(original) { json in
            var snapshot = try XCTUnwrap(json["snapshot"] as? [String: Any])
            snapshot["heads"] = [String(repeating: "a", count: 64)]
            json["snapshot"] = snapshot
        }

        for changed in [changedPayload, changedHeads] {
            let replacement = try replacingFirstInboxRecord(
                in: trusted, with: changed
            )
            let replacementData = try JSONEncoder().encode(replacement)
            do {
                try await store.update {
                    $0 = try JSONDecoder().decode(
                        CloudKitTransportState.self, from: replacementData
                    )
                }
                XCTFail("A changed record with the old ID was accepted")
            } catch {}
            let current = await store.snapshot()
            XCTAssertEqual(current, trusted)
            XCTAssertEqual(try Data(contentsOf: fileURL), persisted)
        }

        let reopened = try CloudKitTransportStateStore(
            directory: directory, accountRecordName: "account", zoneName: "zone"
        )
        let reopenedState = await reopened.snapshot()
        XCTAssertEqual(reopenedState, trusted)
    }

    func testChangedOutboxKindAndKeyCannotReuseValidation() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let notebookID = UUID()
        let original = try makeRecord(
            text: "trusted outbox record", notebookID: notebookID
        )
        let store = try CloudKitTransportStateStore(
            directory: directory, accountRecordName: "account",
            zoneName: "meh-md-notebook-v2", protocolVersion: 2
        )
        try await store.update { $0.outbox[original.id] = original }
        let trusted = await store.snapshot()

        let changedKind = try alteredRecord(original) { json in
            json["kind"] = "catalog"
        }
        do {
            try await store.update { $0.outbox[original.id] = changedKind }
            XCTFail("An outbox record with a changed kind was accepted")
        } catch {}
        var current = await store.snapshot()
        XCTAssertEqual(current, trusted)

        do {
            try await store.update { state in
                state.outbox.removeValue(forKey: original.id)
                state.outbox[String(repeating: "f", count: 64)] = original
            }
            XCTFail("An outbox key different from its record ID was accepted")
        } catch {}
        current = await store.snapshot()
        XCTAssertEqual(current, trusted)
    }

    func testStructuralRulesStillApplyToTrustedRecords() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let notebookID = UUID()
        let noteID = UUID()
        let record = try makeRecord(
            text: "active note", noteID: noteID, notebookID: notebookID
        )
        let store = try CloudKitTransportStateStore(
            directory: directory, accountRecordName: "account",
            zoneName: "meh-md-notebook-v2", protocolVersion: 2
        )
        try await store.update { try $0.appendToInbox(record) }
        let trusted = await store.snapshot()

        do {
            try await store.update { _ = $0.deletedNoteIDs.insert(noteID) }
            XCTFail("A deleted note remained in the inbox")
        } catch {}
        let current = await store.snapshot()
        XCTAssertEqual(current, trusted)
    }

    func testFailedWriteKeepsPreviouslyValidatedHistory() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try makeRecord(text: "history before write failure")
        let initial = try CloudKitTransportStateStore(
            directory: directory, accountRecordName: "account", zoneName: "zone"
        )
        try await initial.update { try $0.appendToInbox(original) }
        let trusted = await initial.snapshot()
        let fileURL = directory.appendingPathComponent("cloudkit-sync-state.json")
        let persisted = try Data(contentsOf: fileURL)
        let failing = try CloudKitTransportStateStore(
            directory: directory, accountRecordName: "account",
            zoneName: "zone", writeState: { _, _ in throw POSIXError(.ENOSPC) }
        )

        do {
            try await failing.update {
                $0.retryNotBefore = Date(timeIntervalSince1970: 1_000)
            }
            XCTFail("The failed write was accepted")
        } catch is CloudKitStateWriteFailure {}
        let current = await failing.snapshot()
        XCTAssertEqual(current, trusted)
        XCTAssertEqual(try Data(contentsOf: fileURL), persisted)

        let reopened = try CloudKitTransportStateStore(
            directory: directory, accountRecordName: "account", zoneName: "zone"
        )
        let reopenedState = await reopened.snapshot()
        XCTAssertEqual(reopenedState, trusted)
    }

    func testStartupFullyValidatesPersistedHistory() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try makeRecord(text: "saved record")
        let store = try CloudKitTransportStateStore(
            directory: directory, accountRecordName: "account", zoneName: "zone"
        )
        try await store.update { try $0.appendToInbox(original) }

        let changedHeads = try alteredRecord(original) { json in
            var snapshot = try XCTUnwrap(json["snapshot"] as? [String: Any])
            snapshot["heads"] = [String(repeating: "a", count: 64)]
            json["snapshot"] = snapshot
        }
        let state = await store.snapshot()
        let corrupted = try replacingFirstInboxRecord(
            in: state, with: changedHeads
        )
        let fileURL = directory.appendingPathComponent("cloudkit-sync-state.json")
        try JSONEncoder().encode(corrupted).write(to: fileURL)

        XCTAssertThrowsError(
            try CloudKitTransportStateStore(
                directory: directory, accountRecordName: "account",
                zoneName: "zone"
            )
        ) { error in
            XCTAssertEqual(
                error as? CloudKitSyncTransportError, .corruptState
            )
        }
    }

    private func makeRecord(
        text: String, noteID: UUID = UUID(), notebookID: UUID? = nil
    ) throws -> SyncRecord {
        let document = try NoteDocument(noteID: noteID)
        try document.replaceAll(with: text)
        if let notebookID {
            return SyncRecord(
                snapshot: document.snapshot(), notebookID: notebookID
            )
        }
        return SyncRecord(snapshot: document.snapshot())
    }

    private func alteredRecord(
        _ record: SyncRecord,
        mutate: (inout [String: Any]) throws -> Void
    ) throws -> SyncRecord {
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(record))
                as? [String: Any]
        )
        try mutate(&json)
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(SyncRecord.self, from: data)
    }

    private func replacingFirstInboxRecord(
        in state: CloudKitTransportState, with record: SyncRecord
    ) throws -> CloudKitTransportState {
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(state))
                as? [String: Any]
        )
        var slots = try XCTUnwrap(json["inbox"] as? [Any])
        slots[0] = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(record))
                as? [String: Any]
        )
        json["inbox"] = slots
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(CloudKitTransportState.self, from: data)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "CloudKitStateValidationTests-\(UUID().uuidString)"
        )
    }
}
