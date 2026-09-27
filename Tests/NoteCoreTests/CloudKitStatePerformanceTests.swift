import Foundation
@testable import NoteCore
import XCTest

/// An opt-in, synthetic benchmark for the durable CloudKit state store.
/// Run with MEH_SYNC_BENCHMARK=1; no CloudKit account or user data is used.
final class CloudKitStatePerformanceTests: XCTestCase {
    private let account = "synthetic-benchmark-account"
    private let zone = "meh-md-notebook-v2"
    private let notebookID = UUID(
        uuidString: "11111111-1111-4111-8111-111111111111"
    )!
    private let clock = ContinuousClock()

    func testRetainedHistoryStoreCosts() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MEH_SYNC_BENCHMARK"] == "1",
            "Set MEH_SYNC_BENCHMARK=1 to run the synthetic benchmark."
        )
        let configuration = try Configuration(environment: ProcessInfo.processInfo.environment)
        for (noteCount, revisionsPerNote) in configuration.cases {
            try await runCase(
                noteCount: noteCount,
                revisionsPerNote: revisionsPerNote,
                repetitions: configuration.repetitions
            )
        }
    }

    private func runCase(
        noteCount: Int,
        revisionsPerNote: Int,
        repetitions: Int
    ) async throws {
        // All Automerge editing, hashing, and fixture encoding precede timing.
        let fixture = try makeFixture(
            noteCount: noteCount, revisionsPerNote: revisionsPerNote
        )
        var engineSamples: [Double] = []
        var noOpSamples: [Double] = []
        var appendSamples: [Double] = []
        var reopenSamples: [Double] = []
        var validationSamples: [Double] = []
        var encodingSamples: [Double] = []
        var diskSamples: [Int] = []

        for repetition in 0..<repetitions {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "MehSyncBenchmark-\(UUID().uuidString)",
                    isDirectory: true
                )
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            defer { try? FileManager.default.removeItem(at: directory) }
            let stateURL = directory.appendingPathComponent(
                "cloudkit-sync-state.json"
            )
            try fixture.encodedState.write(to: stateURL, options: .atomic)
            let store = try CloudKitTransportStateStore(
                directory: directory,
                accountRecordName: account,
                zoneName: zone,
                protocolVersion: 2
            )
            let original = await store.snapshot()
            XCTAssertEqual(original.inbox.count, fixture.recordCount)

            let validationStart = clock.now
            try original.validate(expectedProtocolVersion: 2)
            validationSamples.append(milliseconds(since: validationStart))

            let encodingStart = clock.now
            let encoded = try JSONEncoder().encode(original)
            encodingSamples.append(milliseconds(since: encodingStart))
            XCTAssertFalse(encoded.isEmpty)

            let engineState = Data(
                repeating: UInt8((repetition + 1) % 256), count: 2_048
            )
            let engineStart = clock.now
            try await store.update { $0.engineState = engineState }
            engineSamples.append(milliseconds(since: engineStart))

            let noOpStart = clock.now
            try await store.update { $0.engineState = engineState }
            noOpSamples.append(milliseconds(since: noOpStart))

            let appendStart = clock.now
            try await store.update {
                try $0.appendToInbox(fixture.nextRecord)
            }
            appendSamples.append(milliseconds(since: appendStart))

            let reopenStart = clock.now
            let reopened = try CloudKitTransportStateStore(
                directory: directory,
                accountRecordName: account,
                zoneName: zone,
                protocolVersion: 2
            )
            reopenSamples.append(milliseconds(since: reopenStart))

            let durable = await reopened.snapshot()
            XCTAssertEqual(durable.engineState, engineState)
            XCTAssertEqual(durable.inbox.count, fixture.recordCount + 1)
            XCTAssertEqual(durable.inbox.last, fixture.nextRecord)
            diskSamples.append(try fileSize(at: stateURL))
        }

        for (phase, samples) in [
            ("state_validation", validationSamples),
            ("state_json_encoding", encodingSamples),
            ("engine_state_update", engineSamples),
            ("engine_state_no_op", noOpSamples),
            ("append_one_character_snapshot", appendSamples),
            ("durable_reopen", reopenSamples),
        ] {
            let sorted = samples.sorted()
            let result: [String: Any] = [
                "benchmark": "cloudkit_state_retained_history",
                "fixture_version": 1,
                "protocol_version": 2,
                "phase": phase,
                "note_count": noteCount,
                "revisions_per_note": revisionsPerNote,
                "repetitions": repetitions,
                "retained_record_count": fixture.recordCount,
                "note_snapshot_count": fixture.noteSnapshotCount,
                "note_snapshot_bytes": fixture.noteSnapshotBytes,
                "catalog_snapshot_bytes": fixture.catalogSnapshotBytes,
                "snapshot_bytes": fixture.totalSnapshotBytes,
                "on_disk_bytes": diskSamples[0],
                "on_disk_bytes_samples": diskSamples,
                "samples_ms": samples,
                "median_ms": percentile(sorted, 0.5),
                "p95_ms": percentile(sorted, 0.95),
            ]
            let json = try JSONSerialization.data(
                withJSONObject: result, options: [.sortedKeys]
            )
            print("SYNC_BENCHMARK \(String(decoding: json, as: UTF8.self))")
        }
    }

    private func makeFixture(
        noteCount: Int, revisionsPerNote: Int
    ) throws -> Fixture {
        var state = CloudKitTransportState(
            accountRecordName: account,
            zoneName: zone,
            protocolVersion: 2
        )
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let catalog = try NotebookCatalogDocument(notebookID: notebookID)
        for noteIndex in 0..<noteCount {
            try catalog.add(
                id: noteID(for: noteIndex),
                kind: .note,
                name: "Fictional Note \(noteIndex + 1).md"
            )
        }
        let catalogRecord = SyncRecord(catalog: catalog.snapshot())
        try state.appendToInbox(catalogRecord)
        var nextRecord: SyncRecord?
        var noteSnapshotBytes = 0
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
        for noteIndex in 0..<noteCount {
            let document = try NoteDocument(
                noteID: noteID(for: noteIndex),
                metadata: .now(fixedDate)
            )
            var text = "Fictional note \(noteIndex + 1)"
            for revision in 0..<revisionsPerNote {
                text.append(alphabet[revision % alphabet.count])
                try document.replaceAll(
                    with: text,
                    at: fixedDate.addingTimeInterval(Double(revision + 1))
                )
                let record = SyncRecord(
                    snapshot: document.snapshot(), notebookID: notebookID
                )
                noteSnapshotBytes += record.snapshot.data.count
                try state.appendToInbox(record)
            }
            if noteIndex == 0 {
                text += "x"
                try document.replaceAll(
                    with: text,
                    at: fixedDate.addingTimeInterval(Double(revisionsPerNote + 1))
                )
                nextRecord = SyncRecord(
                    snapshot: document.snapshot(), notebookID: notebookID
                )
            }
        }
        return Fixture(
            encodedState: try JSONEncoder().encode(state),
            nextRecord: try XCTUnwrap(nextRecord),
            recordCount: 1 + noteCount * revisionsPerNote,
            noteSnapshotCount: noteCount * revisionsPerNote,
            noteSnapshotBytes: noteSnapshotBytes,
            catalogSnapshotBytes: catalogRecord.snapshot.data.count
        )
    }

    private func noteID(for index: Int) -> UUID {
        UUID(
            uuidString: String(format:
                "00000000-0000-4000-8000-%012x", index + 1)
        )!
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let components = start.duration(to: clock.now).components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        let rank = Int(ceil(fraction * Double(sorted.count)))
        return sorted[max(0, rank - 1)]
    }

    private func fileSize(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.size] as? Int)
    }
}

private struct Fixture {
    let encodedState: Data
    let nextRecord: SyncRecord
    let recordCount: Int
    let noteSnapshotCount: Int
    let noteSnapshotBytes: Int
    let catalogSnapshotBytes: Int

    var totalSnapshotBytes: Int {
        noteSnapshotBytes + catalogSnapshotBytes
    }
}

private struct Configuration {
    let cases: [(Int, Int)]
    let repetitions: Int

    init(environment: [String: String]) throws {
        let noteCounts = try Self.list(
            environment["MEH_SYNC_BENCHMARK_NOTES"],
            defaultValue: [10, 100], maxValue: 1_000
        )
        let revisionsPerNote = try Self.list(
            environment["MEH_SYNC_BENCHMARK_REVISIONS"],
            defaultValue: [10, 30], maxValue: 1_000
        )
        if environment["MEH_SYNC_BENCHMARK_NOTES"] == nil,
           environment["MEH_SYNC_BENCHMARK_REVISIONS"] == nil {
            cases = [(10, 10), (100, 10), (100, 30)]
        } else {
            cases = noteCounts.flatMap { noteCount in
                revisionsPerNote.map { (noteCount, $0) }
            }
        }
        let rawRepetitions = environment["MEH_SYNC_BENCHMARK_REPETITIONS"] ?? "7"
        guard let parsed = Int(rawRepetitions), (1...8).contains(parsed),
              cases.count <= 12,
              cases.allSatisfy({ $0.0 * $0.1 <= 5_000 })
        else { throw ConfigurationError.invalidValue }
        repetitions = parsed
    }

    private static func list(
        _ raw: String?, defaultValue: [Int], maxValue: Int
    ) throws -> [Int] {
        guard let raw else { return defaultValue }
        let values = raw.split(separator: ",", omittingEmptySubsequences: false)
        guard !values.isEmpty, values.count <= 4 else {
            throw ConfigurationError.invalidValue
        }
        let parsed = values.compactMap { Int($0) }
        guard parsed.count == values.count,
              parsed.allSatisfy({ (1...maxValue).contains($0) }),
              Set(parsed).count == parsed.count else {
            throw ConfigurationError.invalidValue
        }
        return parsed
    }
}

private enum ConfigurationError: Error {
    case invalidValue
}
