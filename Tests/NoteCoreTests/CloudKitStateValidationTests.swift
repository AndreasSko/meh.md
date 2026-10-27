import Foundation
@testable import NoteCore
import XCTest
import TestSupport

final class CloudKitStateValidationTests: XCTestCase {
    @MainActor
    func testOpeningStoreLeavesMainActorBeforeDiskWork() async throws {
        let directory = temporaryDirectory()
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

    func testStartupTrustsOnlyRecordsSavedByTheSameBuild() async throws {
        let directory = temporaryDirectory()
        let fileURL = directory.appendingPathComponent("cloudkit-sync-state.json")
        let original = try makeRecord(text: "saved record")
        let store = try CloudKitTransportStateStore(
            directory: directory, accountRecordName: "account", zoneName: "zone",
            recordValidationStamp: "build-a"
        )
        try await store.update { try $0.appendToInbox(original) }

        // A record this build would reject, saved with a matching digest.
        // Opening succeeds only where record decoding is skipped.
        let changedHeads = try alteredRecord(original) { json in
            var snapshot = try XCTUnwrap(json["snapshot"] as? [String: Any])
            snapshot["heads"] = [String(repeating: "a", count: 64)]
            json["snapshot"] = snapshot
        }
        let invalid = try replacingFirstInboxRecord(
            in: await store.snapshot(), with: changedHeads
        )
        try CloudKitStateDiskStorage(
            directory: directory, recordValidationStamp: "build-a"
        ).encode(invalid).write(to: fileURL)
        XCTAssertNoThrow(try CloudKitTransportStateStore(
            directory: directory, accountRecordName: "account",
            zoneName: "zone", recordValidationStamp: "build-a"
        ))
    }

    func testStartupValidatesRecordsFromOtherBuildsAndLegacyFiles() async throws {
        let directory = temporaryDirectory()
        let fileURL = directory.appendingPathComponent("cloudkit-sync-state.json")
        let original = try makeRecord(text: "saved record")
        let store = try CloudKitTransportStateStore(
            directory: directory, accountRecordName: "account", zoneName: "zone",
            recordValidationStamp: "build-a"
        )
        try await store.update { try $0.appendToInbox(original) }
        let changedHeads = try alteredRecord(original) { json in
            var snapshot = try XCTUnwrap(json["snapshot"] as? [String: Any])
            snapshot["heads"] = [String(repeating: "a", count: 64)]
            json["snapshot"] = snapshot
        }
        let invalid = try replacingFirstInboxRecord(
            in: await store.snapshot(), with: changedHeads
        )

        let manifests: [(String, Data)] = [
            ("other build", try CloudKitStateDiskStorage(
                directory: directory, recordValidationStamp: "build-b"
            ).encode(invalid)),
            ("no stamp", try CloudKitStateDiskStorage(
                directory: directory
            ).encode(invalid)),
            ("inline records", try JSONEncoder().encode(invalid)),
        ]
        for (name, manifest) in manifests {
            try manifest.write(to: fileURL)
            for stamp in ["build-a", nil] {
                XCTAssertThrowsError(try CloudKitTransportStateStore(
                    directory: directory, accountRecordName: "account",
                    zoneName: "zone", recordValidationStamp: stamp
                ), name) { error in
                    XCTAssertEqual(
                        error as? CloudKitSyncTransportError, .corruptState, name
                    )
                }
            }
        }
    }

    func testTrustedStartupStillRejectsChangedPayloadBytes() async throws {
        let directory = temporaryDirectory()
        let store = try CloudKitTransportStateStore(
            directory: directory, accountRecordName: "account", zoneName: "zone",
            recordValidationStamp: "build-a"
        )
        let record = try makeRecord(text: "saved")
        try await store.update { try $0.appendToInbox(record) }
        let payloads = directory.appendingPathComponent("cloudkit-sync-payloads")
        for url in try FileManager.default.contentsOfDirectory(
            at: payloads, includingPropertiesForKeys: nil
        ) {
            var data = try Data(contentsOf: url)
            data.append(contentsOf: Array(" ".utf8))
            try data.write(to: url)
        }

        XCTAssertThrowsError(try CloudKitTransportStateStore(
            directory: directory, accountRecordName: "account", zoneName: "zone",
            recordValidationStamp: "build-a"
        )) { error in
            XCTAssertEqual(error as? CloudKitSyncTransportError, .corruptState)
        }
    }

    func testFullStartupValidationRecordsTheCurrentBuild() async throws {
        let directory = temporaryDirectory()
        let fileURL = directory.appendingPathComponent("cloudkit-sync-state.json")
        let store = try CloudKitTransportStateStore(
            directory: directory, accountRecordName: "account", zoneName: "zone",
            recordValidationStamp: "build-a"
        )
        let record = try makeRecord(text: "saved")
        try await store.update { try $0.appendToInbox(record) }
        let saved = await store.snapshot()

        let reopened = try CloudKitTransportStateStore(
            directory: directory, accountRecordName: "account", zoneName: "zone",
            recordValidationStamp: "build-b"
        )
        let reopenedState = await reopened.snapshot()
        XCTAssertEqual(reopenedState, saved)
        XCTAssertEqual(try stamp(at: fileURL), "build-b")
    }

    func testFailedStampWriteStillOpensAndKeepsTheOldStamp() async throws {
        let directory = temporaryDirectory()
        let fileURL = directory.appendingPathComponent("cloudkit-sync-state.json")
        let store = try CloudKitTransportStateStore(
            directory: directory, accountRecordName: "account", zoneName: "zone",
            recordValidationStamp: "build-a"
        )
        let record = try makeRecord(text: "saved")
        try await store.update { try $0.appendToInbox(record) }
        let saved = await store.snapshot()

        let reopened = try CloudKitTransportStateStore(
            directory: directory, accountRecordName: "account", zoneName: "zone",
            recordValidationStamp: "build-b",
            writeState: { _, _ in throw CocoaError(.fileWriteNoPermission) }
        )
        let reopenedState = await reopened.snapshot()
        XCTAssertEqual(reopenedState, saved)
        XCTAssertEqual(try stamp(at: fileURL), "build-a")
    }

    func testInlineStateIsStampedByItsFirstChangedCommit() async throws {
        let directory = temporaryDirectory()
        let fileURL = directory.appendingPathComponent("cloudkit-sync-state.json")
        var state = CloudKitTransportState(
            accountRecordName: "account", zoneName: "zone"
        )
        try state.appendToInbox(makeRecord(text: "saved"))
        let inline = try JSONEncoder().encode(state)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        try inline.write(to: fileURL)

        let store = try CloudKitTransportStateStore(
            directory: directory, accountRecordName: "account", zoneName: "zone",
            recordValidationStamp: "build-a"
        )
        XCTAssertEqual(try Data(contentsOf: fileURL), inline)

        try await store.update { $0.engineState = Data("changed".utf8) }
        XCTAssertEqual(try stamp(at: fileURL), "build-a")
    }

    func testOnlyFullStartupValidationReportsProgress() async throws {
        let directory = temporaryDirectory()
        let store = try CloudKitTransportStateStore(
            directory: directory, accountRecordName: "account", zoneName: "zone",
            recordValidationStamp: "build-a"
        )
        let records = try (0..<3).map { try makeRecord(text: "saved \($0)") }
        try await store.update { state in
            for record in records { try state.appendToInbox(record) }
        }

        let reports = ProgressReports()
        func reopen(_ stamp: String) throws {
            _ = try CloudKitTransportStateStore(
                directory: directory, accountRecordName: "account", zoneName: "zone",
                recordValidationStamp: stamp,
                validationProgress: { reports.append($0, $1) }
            )
        }
        try reopen("build-b")
        XCTAssertEqual(reports.values.map(\.0), [0, 1, 2, 3])
        XCTAssertTrue(reports.values.allSatisfy { $0.1 == 3 })

        reports.removeAll()
        try reopen("build-b")
        XCTAssertTrue(reports.values.isEmpty)
    }

    func testBuildStampIsTheImageUUID() throws {
        let stamp = try XCTUnwrap(CloudKitStateDiskStorage.buildStamp)
        XCTAssertNotNil(UUID(uuidString: stamp))
    }

    private func stamp(at fileURL: URL) throws -> String? {
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL))
                as? [String: Any]
        )
        return manifest["recordValidationStamp"] as? String
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
}

private final class ProgressReports: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [(Int, Int)] = []

    var values: [(Int, Int)] { lock.withLock { reports } }
    func append(_ completed: Int, _ total: Int) {
        lock.withLock { reports.append((completed, total)) }
    }
    func removeAll() { lock.withLock { reports.removeAll() } }
}
