import Foundation
@testable import NoteCore
import XCTest

/// Opt-in Release benchmark using only fictional, local notebook files.
@MainActor
final class NotebookExchangePerformanceTests: XCTestCase {
    private let clock = ContinuousClock()
    private let notebookID = UUID(
        uuidString: "11111111-1111-4111-8111-111111111111"
    )!

    func testCompleteLocalExchanges() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MEH_EXCHANGE_BENCHMARK"] == "1",
            "Set MEH_EXCHANGE_BENCHMARK=1 to run this synthetic benchmark."
        )
        let configuration = try ExchangeConfiguration(
            environment: ProcessInfo.processInfo.environment
        )
        for (noteCount, revisions) in configuration.cases {
            try await runCase(
                noteCount: noteCount,
                revisions: revisions,
                repetitions: configuration.repetitions
            )
        }
    }

    private func runCase(
        noteCount: Int,
        revisions: Int,
        repetitions: Int
    ) async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appending(path: "fixture")
        let fixtureBytes = try await makeFixture(
            at: fixture, noteCount: noteCount, revisions: revisions
        )
        var samples: [String: [Double]] = [:]
        var historyDecodes: [Int] = []

        for repetition in 0..<repetitions {
            let sourceURL = root.appending(path: "source-\(repetition)")
            let destinationURL = root.appending(path: "destination-\(repetition)")
            try FileManager.default.copyItem(at: fixture, to: sourceURL)
            let source = NotebookReplica(directory: sourceURL)
            let destination = NotebookReplica(directory: destinationURL)
            let transport = InMemorySyncTransport(
                scope: "synthetic-exchange-\(UUID().uuidString)",
                pageSize: 100
            )
            let sender = NotebookSyncCoordinator(replica: source, transport: transport)
            let receiver = NotebookSyncCoordinator(
                replica: destination, transport: transport
            )

            await measure("initial_source", into: &samples) {
                await sender.synchronize()
            }
            try assertExchanged(sender)
            await measure("initial_destination", into: &samples) {
                await receiver.synchronize()
            }
            try assertExchanged(receiver)

            // Opening the editor may update recents. Settle both peers before
            // measuring a true no-op or the single body-character exchange.
            let first = try await source.openNote(noteID(for: 0))
            await sender.synchronize()
            try assertExchanged(sender)
            await receiver.synchronize()
            try assertExchanged(receiver)

            await measure("no_op_source", into: &samples) {
                await sender.synchronize()
            }
            try assertExchanged(sender)
            await measure("no_op_destination", into: &samples) {
                await receiver.synchronize()
            }
            try assertExchanged(receiver)

            let sourceRecords = try await measureThrowing(
                "records_listed", into: &samples
            ) { try await source.records() }
            XCTAssertEqual(sourceRecords.count, noteCount + 1)
            let allRecords = try await measureThrowing(
                "records_unlisted", into: &samples
            ) { try await source.records(includeUnlisted: true) }
            XCTAssertEqual(allRecords.count, sourceRecords.count)
            let checkpoints = Dictionary(
                uniqueKeysWithValues: allRecords.map {
                    ($0.documentKey, $0.snapshot.heads)
                }
            )
            let contains = try await measureThrowing(
                "contains_history", into: &samples
            ) {
                try await source.containsHistory(checkpoints, deleted: [])
            }
            XCTAssertTrue(contains)

            // Separate file gathering from history membership work, including
            // the cache behavior when a notebook exceeds its entry budget.
            let checker = NotebookHistoryChecker()
            _ = try await checker.containsHistory(
                checkpoints, records: allRecords, deleted: []
            )
            let beforeDecodes = await checker.decodedSnapshotCount
            let workerContains = try await measureThrowing(
                "checkpoint_history_worker", into: &samples
            ) {
                try await checker.containsHistory(
                    checkpoints, records: allRecords, deleted: []
                )
            }
            XCTAssertTrue(workerContains)
            let afterDecodes = await checker.decodedSnapshotCount
            historyDecodes.append(afterDecodes - beforeDecodes)

            let catalog = try XCTUnwrap(source.catalogSnapshot)
            let seed = SyncRecord(catalog: catalog)
            try await measureThrowing("validate_catalog_record", into: &samples) {
                try seed.validate()
            }
            try await measureThrowing("accept_seed_no_op", into: &samples) {
                try await source.acceptSeed(seed)
            }

            let markdown = root.appending(path: "markdown-\(repetition)")
            let publisher = NotebookMarkdownPublisher(directory: markdown)
            let snapshots = sourceRecords.filter { $0.kind == .note }
                .map(\.snapshot)
            let catalogDocument = try NotebookCatalogDocument(snapshot: catalog)
            let items = try await measureThrowing(
                "catalog_items", into: &samples
            ) { try catalogDocument.items() }
            XCTAssertEqual(items.count, noteCount)
            try await measureThrowing("markdown_publish", into: &samples) {
                try await publisher.publish(
                    catalog: catalog,
                    placements: source.placements,
                    notes: snapshots
                )
            }

            let expectedText = first.text + "x"
            try first.replaceAll(with: expectedText)
            try await first.flush()
            let roundTripStart = clock.now
            await measure("one_character_source", into: &samples) {
                await sender.synchronize()
            }
            try assertExchanged(sender)
            await measure("one_character_destination", into: &samples) {
                await receiver.synchronize()
            }
            try assertExchanged(receiver)
            samples["one_character_round_trip", default: []].append(
                milliseconds(since: roundTripStart)
            )
            let received = try await destination.openNote(noteID(for: 0))
            XCTAssertEqual(received.text, expectedText)
            try await assertConverged(source, destination, noteCount: noteCount)
            let changedRecords = try await source.records()
            let changedNotes = changedRecords.filter { $0.kind == .note }
                .map(\.snapshot)
            let publication = try await publisher.profiledPublish(
                catalog: try XCTUnwrap(source.catalogSnapshot),
                placements: source.placements,
                notes: changedNotes
            )
            for (phase, milliseconds) in publication {
                samples[phase, default: []].append(milliseconds)
            }
        }

        for phase in samples.keys.sorted() {
            let values = try XCTUnwrap(samples[phase])
            let sorted = values.sorted()
            var result: [String: Any] = [
                "benchmark": "notebook_local_exchange",
                "fixture_version": 1,
                "phase": phase,
                "note_count": noteCount,
                "revisions_per_note": revisions,
                "repetitions": repetitions,
                "page_size": 100,
                "snapshot_bytes": fixtureBytes.snapshot,
                "fixture_on_disk_bytes": fixtureBytes.disk,
                "samples_ms": values,
                "median_ms": percentile(sorted, 0.5),
                "p95_ms": percentile(sorted, 0.95),
            ]
            if phase == "checkpoint_history_worker" {
                result["decoded_snapshots"] = historyDecodes
            }
            let data = try JSONSerialization.data(
                withJSONObject: result, options: [.sortedKeys]
            )
            // One write keeps XCTest's stderr from splitting buffered JSON.
            FileHandle.standardOutput.write(
                Data("EXCHANGE_BENCHMARK ".utf8) + data + Data("\n".utf8)
            )
        }
    }

    private func makeFixture(
        at directory: URL, noteCount: Int, revisions: Int
    ) async throws -> (snapshot: Int, disk: Int) {
        let catalog = try NotebookCatalogDocument(notebookID: notebookID)
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        var snapshotBytes = 0
        for index in 0..<noteCount {
            let id = noteID(for: index)
            try catalog.add(
                id: id, kind: .note, name: "Fictional Note \(index + 1).md"
            )
            let document = try NoteDocument(
                noteID: id,
                text: "Fictional note \(index + 1)",
                metadata: .now(fixedDate)
            )
            var text = "Fictional note \(index + 1)"
            for revision in 1..<revisions {
                text.append(Character(UnicodeScalar(97 + revision % 26)!))
                try document.replaceAll(
                    with: text,
                    at: fixedDate.addingTimeInterval(Double(revision))
                )
            }
            let snapshot = document.snapshot()
            snapshotBytes += snapshot.data.count
            try await NoteFileStorage(
                directory: directory.appending(path: "notes/\(id.uuidString)")
            ).save(snapshot)
        }
        let snapshot = catalog.snapshot()
        snapshotBytes += snapshot.data.count
        try await NotebookCatalogStorage(directory: directory).save(snapshot)
        return (snapshotBytes, try diskBytes(at: directory))
    }

    private func assertConverged(
        _ source: NotebookReplica,
        _ destination: NotebookReplica,
        noteCount: Int
    ) async throws {
        let sent = try await source.records()
        let received = try await destination.records()
        XCTAssertEqual(sent.count, noteCount + 1)
        XCTAssertEqual(received.count, sent.count)
        let sourceHeads = Dictionary(
            uniqueKeysWithValues: sent.map { ($0.documentKey, $0.snapshot.heads) }
        )
        let destinationHeads = Dictionary(
            uniqueKeysWithValues: received.map { ($0.documentKey, $0.snapshot.heads) }
        )
        XCTAssertEqual(destinationHeads, sourceHeads)
    }

    private func assertExchanged(_ coordinator: NotebookSyncCoordinator) throws {
        if let error = coordinator.lastError { throw error }
        guard case .exchanged = coordinator.status else {
            XCTFail("Expected an exchanged coordinator, got \(coordinator.status)")
            throw ExchangeConfigurationError.unexpectedStatus
        }
    }

    private func measure(
        _ phase: String,
        into samples: inout [String: [Double]],
        _ operation: () async -> Void
    ) async {
        let start = clock.now
        await operation()
        samples[phase, default: []].append(milliseconds(since: start))
    }

    private func measureThrowing<Value>(
        _ phase: String,
        into samples: inout [String: [Double]],
        _ operation: () async throws -> Value
    ) async throws -> Value {
        let start = clock.now
        let value = try await operation()
        samples[phase, default: []].append(milliseconds(since: start))
        return value
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: clock.now).components
        return Double(duration.seconds) * 1_000
            + Double(duration.attoseconds) / 1_000_000_000_000_000
    }

    private func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        sorted[max(0, Int(ceil(fraction * Double(sorted.count))) - 1)]
    }

    private func diskBytes(at root: URL) throws -> Int {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ))
        var total = 0
        for case let file as URL in enumerator {
            let values = try file.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            )
            if values.isRegularFile == true { total += values.fileSize ?? 0 }
        }
        return total
    }

    private func noteID(for index: Int) -> UUID {
        UUID(uuidString: String(
            format: "00000000-0000-4000-8000-%012x", index + 1
        ))!
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "MehExchangeBenchmark-\(UUID().uuidString)"
        )
    }
}

// Benchmark-only instrumentation. The stage callback runs inside
// the publisher actor, so no production API or publish behavior changes.
private extension NotebookMarkdownPublisher {
    func profiledPublish(
        catalog: NotebookCatalogSnapshot,
        placements: [NotebookPlacement],
        notes: [NoteSnapshot]
    ) throws -> [String: Double] {
        let clock = ContinuousClock()
        let started = clock.now
        var marks: [(NotebookMarkdownPublishStage, ContinuousClock.Instant)] = []
        try publish(
            catalog: catalog,
            placements: placements,
            notes: notes,
            afterStage: { marks.append(($0, clock.now)) }
        )
        let finished = clock.now
        guard marks.count == 4,
              case .pendingRecorded = marks[0].0,
              case .stageBuilt = marks[1].0,
              case .contentSwapped = marks[2].0,
              case .manifestCommitted = marks[3].0 else {
            throw MarkdownProfileError.missingStage
        }
        func milliseconds(
            _ start: ContinuousClock.Instant,
            _ end: ContinuousClock.Instant
        ) -> Double {
            let components = start.duration(to: end).components
            return Double(components.seconds) * 1_000
                + Double(components.attoseconds) / 1_000_000_000_000_000
        }
        return [
            "markdown_publish_changed": milliseconds(started, finished),
            "markdown_changed_prepare": milliseconds(started, marks[0].1),
            "markdown_changed_stage_build": milliseconds(marks[0].1, marks[1].1),
            "markdown_changed_swap": milliseconds(marks[1].1, marks[2].1),
            "markdown_changed_commit": milliseconds(marks[2].1, marks[3].1),
            "markdown_changed_cleanup": milliseconds(marks[3].1, finished),
        ]
    }
}

private enum MarkdownProfileError: Error {
    case missingStage
}

private struct ExchangeConfiguration {
    let cases: [(Int, Int)]
    let repetitions: Int

    init(environment: [String: String]) throws {
        if let raw = environment["MEH_EXCHANGE_BENCHMARK_CASES"] {
            let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
            guard (1...6).contains(parts.count) else {
                throw ExchangeConfigurationError.invalidValue
            }
            cases = try parts.map { part in
                let pair = part.split(separator: "x", omittingEmptySubsequences: false)
                guard pair.count == 2,
                    let notes = Int(pair[0]), (1...1_000).contains(notes),
                    let revisions = Int(pair[1]), (1...500).contains(revisions),
                    notes * revisions <= 5_000
                else { throw ExchangeConfigurationError.invalidValue }
                return (notes, revisions)
            }
        } else {
            cases = [(100, 1), (500, 3), (1_000, 5)]
        }
        let raw = environment["MEH_EXCHANGE_BENCHMARK_REPETITIONS"] ?? "3"
        guard let value = Int(raw), (1...5).contains(value) else {
            throw ExchangeConfigurationError.invalidValue
        }
        repetitions = value
    }
}

private enum ExchangeConfigurationError: Error {
    case invalidValue
    case unexpectedStatus
}
