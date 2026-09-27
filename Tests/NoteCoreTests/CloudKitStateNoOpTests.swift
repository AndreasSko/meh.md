import Foundation
@testable import NoteCore
import XCTest

final class CloudKitStateNoOpTests: XCTestCase {
    func testRepeatedEngineStateReturnsResultWithoutWriting() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writes = WriteCounter()
        let store = try CloudKitTransportStateStore(
            directory: directory,
            accountRecordName: "account",
            zoneName: "zone",
            writeState: { data, url in
                writes.increment()
                try SyncFileIO.replace(data, at: url)
            }
        )
        let engineState = Data("engine-state".utf8)

        try await store.update { $0.engineState = engineState }
        let writesAfterChange = writes.value
        let result = try await store.update { state -> String in
            state.engineState = engineState
            return "closure-result"
        }

        XCTAssertEqual(result, "closure-result")
        XCTAssertEqual(writes.value, writesAfterChange)
        let reopened = try CloudKitTransportStateStore(
            directory: directory,
            accountRecordName: "account",
            zoneName: "zone"
        )
        let state = await reopened.snapshot()
        XCTAssertEqual(state.engineState, engineState)
    }

    func testChangedEngineStateIsPersisted() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CloudKitTransportStateStore(
            directory: directory,
            accountRecordName: "account",
            zoneName: "zone"
        )

        try await store.update { $0.engineState = Data("first".utf8) }
        try await store.update { $0.engineState = Data("second".utf8) }

        let reopened = try CloudKitTransportStateStore(
            directory: directory,
            accountRecordName: "account",
            zoneName: "zone"
        )
        let state = await reopened.snapshot()
        XCTAssertEqual(state.engineState, Data("second".utf8))
    }

    func testDuplicateInboxAppendSkipsWriteAndValidatesInput() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writes = WriteCounter()
        let store = try CloudKitTransportStateStore(
            directory: directory,
            accountRecordName: "account",
            zoneName: "zone",
            writeState: { data, url in
                writes.increment()
                try SyncFileIO.replace(data, at: url)
            }
        )
        let record = try makeRecord()
        try await store.update { try $0.appendToInbox(record) }
        let writesAfterAppend = writes.value

        try await store.update { try $0.appendToInbox(record) }
        XCTAssertEqual(writes.value, writesAfterAppend)

        let invalidDuplicate = try makeInvalidDuplicate(of: record)
        do {
            try await store.update { try $0.appendToInbox(invalidDuplicate) }
            XCTFail("An invalid duplicate was accepted")
        } catch {
            XCTAssertEqual(
                error as? NoteDocumentError, .noteIdentityMismatch
            )
        }
        XCTAssertEqual(writes.value, writesAfterAppend)
    }

    func testRetiredStoreRejectsNoOpUpdate() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CloudKitTransportStateStore(
            directory: directory,
            accountRecordName: "account",
            zoneName: "zone"
        )
        await store.retire()

        do {
            try await store.update { _ in }
            XCTFail("A retired store accepted a no-op update")
        } catch is CloudKitRetiredTransportError {}
    }

    func testWriteFailureCannotBeBypassedByLaterNoOp() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try CloudKitTransportStateStore(
            directory: directory,
            accountRecordName: "account",
            zoneName: "zone"
        )
        let failing = try CloudKitTransportStateStore(
            directory: directory,
            accountRecordName: "account",
            zoneName: "zone",
            writeState: { _, _ in throw POSIXError(.ENOSPC) }
        )
        do {
            try await failing.update {
                $0.engineState = Data("failed".utf8)
            }
            XCTFail("The injected write failure was accepted")
        } catch is CloudKitStateWriteFailure {}

        do {
            try await failing.update { _ in }
            XCTFail("A no-op update bypassed the latched write failure")
        } catch is CloudKitStateWriteFailure {}

        let reopened = try CloudKitTransportStateStore(
            directory: directory,
            accountRecordName: "account",
            zoneName: "zone"
        )
        let failedSnapshot = await failing.snapshot()
        let persistedSnapshot = await reopened.snapshot()
        XCTAssertEqual(failedSnapshot, persistedSnapshot)
    }

    private func makeRecord() throws -> SyncRecord {
        SyncRecord(snapshot: try NoteDocument(text: "inbox record").snapshot())
    }

    private func makeInvalidDuplicate(
        of record: SyncRecord
    ) throws -> SyncRecord {
        let encoded = try JSONEncoder().encode(record)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var snapshot = try XCTUnwrap(object["snapshot"] as? [String: Any])
        snapshot["heads"] = [String(repeating: "a", count: 64)]
        object["snapshot"] = snapshot
        let corrupted = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(SyncRecord.self, from: corrupted)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "CloudKitStateNoOpTests-\(UUID().uuidString)"
        )
    }
}

private final class WriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}
