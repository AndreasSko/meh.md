import Foundation
import os
@testable import NoteCore
import XCTest

/// Opt-in benchmark of the receiving side of a small change: another device
/// edits one note and adds one, then this device opens and syncs. It uses the
/// real CloudKit transport over the in-process fake server, with fictional
/// notes only. Times are measured from the start of the receiving pass.
@MainActor
final class CloudKitReceivePerformanceTests: XCTestCase {
    private struct Case {
        let notes: Int
        let versions: Int
        let cleanup: Bool
        let latencyMs: Int
    }

    private let clock = ContinuousClock()

    func testOpenAfterSmallRemoteChange() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["MEH_RECEIVE_BENCHMARK"] == "1",
            "Set MEH_RECEIVE_BENCHMARK=1 to run this synthetic benchmark."
        )
        let repetitions = Int(environment["MEH_RECEIVE_BENCHMARK_REPETITIONS"] ?? "3") ?? 3
        for benchmarkCase in try cases(environment) {
            try await run(benchmarkCase, repetitions: repetitions)
        }
    }

    /// `notes x versions [c] [@latencyMs]`, e.g. `1000x5c@100`. `c` runs
    /// snapshot cleanup on the sender after each change, so the receiver
    /// also sees retired snapshots.
    private func cases(_ environment: [String: String]) throws -> [Case] {
        let raw = environment["MEH_RECEIVE_BENCHMARK_CASES"] ?? "100x3,1000x3"
        return try raw.split(separator: ",").map { part in
            var text = Substring(part)
            var latency = 0
            if let at = text.firstIndex(of: "@") {
                latency = Int(text[text.index(after: at)...]) ?? 0
                text = text[..<at]
            }
            let cleanup = text.hasSuffix("c")
            if cleanup { text = text.dropLast() }
            let pair = text.split(separator: "x")
            guard pair.count == 2, let notes = Int(pair[0]), let versions = Int(pair[1]),
                  (1...2_000).contains(notes), (1...50).contains(versions)
            else { throw BenchmarkError.invalidCase(String(part)) }
            return Case(notes: notes, versions: versions, cleanup: cleanup, latencyMs: latency)
        }
    }

    private func run(_ benchmarkCase: Case, repetitions: Int) async throws {
        let environment = ProcessInfo.processInfo.environment
        let root = FileManager.default.temporaryDirectory
            .appending(path: "meh-receive-benchmark-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try FakeCloudKitServer(directory: root.appending(path: "server"))
        let senderDirectory = root.appending(path: "sender")
        try await makeFixture(
            at: senderDirectory.appending(path: "notebook"), benchmarkCase)
        let sender = try await FakeCloudKitDevice.open(senderDirectory, server: server)
        var receiver = try await FakeCloudKitDevice.open(
            root.appending(path: "receiver"), server: server)
        let ids = (0..<benchmarkCase.notes).map(noteID)
        await sender.coordinator.synchronize()
        try assertExchanged(sender.coordinator)
        await receiver.coordinator.synchronize()
        try assertExchanged(receiver.coordinator)

        var samples: [String: [Double]] = [:]
        let session = try await sender.replica.openNote(ids[0])
        for repetition in 0..<repetitions {
            server.requestLatency = 0
            let expected = session.text + " edit \(repetition)"
            try session.replaceAll(with: expected)
            try await session.flush()
            let created = try await sender.replica.createNote(
                name: "Fictional New \(repetition)", text: "Fictional new note")
            await sender.coordinator.synchronize()
            try assertExchanged(sender.coordinator)
            if benchmarkCase.cleanup {
                _ = try await sender.coordinator.cleanupSnapshots()
            }

            server.requestLatency = Double(benchmarkCase.latencyMs) / 1_000
            let requestsBefore = server.requestCount
            let signposter = OSSignposter(
                subsystem: "md.meh.benchmark", category: .pointsOfInterest)
            let openInterval = signposter.beginInterval("receiver open")
            // Both devices share this process; start the receiver without
            // what the sender validated, as a fresh app would.
            SyncRecord.forgetValidatedRecords()
            NotebookCatalogDocument.forgetValidatedBytes()
            let openStart = clock.now
            receiver = try await receiver.restarted(server: server)
            signposter.endInterval("receiver open", openInterval)
            samples["open", default: []].append(milliseconds(since: openStart))
            let passDate = Date()
            let passStart = clock.now
            let passInterval = signposter.beginInterval("receiver pass")
            await receiver.coordinator.synchronize()
            signposter.endInterval("receiver pass", passInterval)
            samples["pass", default: []].append(milliseconds(since: passStart))
            try assertExchanged(receiver.coordinator)
            samples["requests", default: []].append(
                Double(server.requestCount - requestsBefore))
            server.requestLatency = 0

            let events = receiver.log.entries.filter { $0.timestamp >= passDate }
            let start = try XCTUnwrap(events.first { $0.event == "pass_start" }).timestamp
            if environment["MEH_RECEIVE_BENCHMARK_TRACE"] == "1", repetition == repetitions - 1 {
                for entry in events {
                    print(String(format: "TRACE %7.1f ", entry.timestamp.timeIntervalSince(start) * 1_000)
                        + entry.event + " " + entry.counts.sorted { $0.key < $1.key }
                            .map { "\($0.key)=\($0.value)" }.joined(separator: " "))
                }
            }
            for name in [
                "checkpoints_loaded", "bootstrap_end", "catalog_accepted", "history_check_start", "history_check_end", "page_fetch_returned",
                "page_applied", "page_received", "outgoing_scan_end", "final_scan_end", "pass_end",
            ] {
                if let entry = events.first(where: { $0.event == name }) {
                    samples["at_" + name, default: []].append(
                        entry.timestamp.timeIntervalSince(start) * 1_000)
                }
            }
            let received = try await receiver.replica.openNote(ids[0])
            XCTAssertEqual(received.text, expected)
            XCTAssertTrue(receiver.replica.placements.contains { $0.item.id == created })
        }
        await sender.transport.retire()
        await receiver.transport.retire()

        for phase in samples.keys.sorted() {
            let values = samples[phase]!
            let sorted = values.sorted()
            let row: [String: Any] = [
                "benchmark": "cloudkit_receive_small_change",
                "phase": phase,
                "notes": benchmarkCase.notes,
                "versions": benchmarkCase.versions,
                "cleanup": benchmarkCase.cleanup,
                "latency_ms": benchmarkCase.latencyMs,
                "samples": values.map { ($0 * 10).rounded() / 10 },
                "median": sorted[sorted.count / 2],
            ]
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            FileHandle.standardOutput.write(
                Data("RECEIVE_BENCHMARK ".utf8) + data + Data("\n".utf8))
        }
    }

    private func makeFixture(at directory: URL, _ benchmarkCase: Case) async throws {
        let catalog = try NotebookCatalogDocument(notebookID: UUID())
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<benchmarkCase.notes {
            let id = noteID(index)
            try catalog.add(id: id, kind: .note, name: "Fictional Note \(index + 1).md")
            var text = "Fictional note \(index + 1)\n"
                + String(repeating: "Synthetic body line.\n", count: 8)
            let document = try NoteDocument(
                noteID: id, text: text, metadata: .now(base))
            for version in 1..<benchmarkCase.versions {
                text.append("v")
                try document.replaceAll(
                    with: text, at: base.addingTimeInterval(Double(version)))
            }
            try await NoteFileStorage(
                directory: directory.appending(path: "notes/\(id.uuidString)")
            ).save(document.snapshot())
        }
        try await NotebookCatalogStorage(directory: directory).save(catalog.snapshot())
    }

    private func noteID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012x", index + 1))!
    }

    private func assertExchanged(_ coordinator: NotebookSyncCoordinator) throws {
        if let error = coordinator.lastError { throw error }
        guard case .exchanged = coordinator.status else {
            throw BenchmarkError.notExchanged("\(coordinator.status)")
        }
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let parts = start.duration(to: clock.now).components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    private enum BenchmarkError: Error {
        case invalidCase(String)
        case notExchanged(String)
    }
}
