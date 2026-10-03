import Foundation
@testable import NoteCore
import XCTest

/// Opt-in CPU benchmark for catalog startup and first-edit costs.
@MainActor
final class NotebookCatalogPerformanceTests: XCTestCase {
    private enum SimulatedCatalogFailure: Error { case interrupted }

    @MainActor
    private final class MainActorHeartbeat {
        private var timer: DispatchSourceTimer?
        private var previousBeat = ProcessInfo.processInfo.systemUptime
        private(set) var maximumGapMilliseconds = 0.0

        func start() {
            previousBeat = ProcessInfo.processInfo.systemUptime
            // Measure the UI queue itself. A sleeping Swift task first needs
            // a cooperative-executor wakeup, which can lag during unrelated
            // background decode work even when the main queue is available.
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + .milliseconds(10),
                           repeating: .milliseconds(10), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.recordBeat() }
            }
            self.timer = timer
            timer.resume()
        }

        func stop() {
            timer?.cancel()
            timer = nil
            recordBeat()
        }

        private func recordBeat() {
            let now = ProcessInfo.processInfo.systemUptime
            maximumGapMilliseconds = max(
                maximumGapMilliseconds, (now - previousBeat) * 1_000
            )
            previousBeat = now
        }
    }

    func testCatalogSaveFailureDoesNotPublishStagedDocument() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "catalog-install-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let replica = NotebookReplica(directory: directory)
        try await replica.createLocalNotebook()
        let first = try await replica.createNote(name: "First.md")
        _ = try await replica.createNote(name: "Second.md")
        let original = try XCTUnwrap(replica.catalogSnapshot)
        replica.catalogWriteSuspension = { throw SimulatedCatalogFailure.interrupted }

        do {
            try await replica.recordRecentActivity(for: first)
            XCTFail("The injected failure must interrupt the catalog write")
        } catch SimulatedCatalogFailure.interrupted {}

        XCTAssertEqual(replica.catalogSnapshot, original)
        XCTAssertFalse(replica.isLatestRecentActivity(first))
        XCTAssertTrue(replica.recentNotes.isEmpty)

        let reopened = NotebookReplica(directory: directory)
        try await reopened.load()
        XCTAssertEqual(reopened.catalogSnapshot, original)
        XCTAssertFalse(reopened.isLatestRecentActivity(first))
    }

    func testCatalogLoadDoesNotPublishAfterResetIsPending() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "catalog-load-reset-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try NotebookCatalogDocument()
        _ = try catalog.add(kind: .note, name: "Note.md")
        try await NotebookCatalogStorage(directory: directory).save(catalog.snapshot())
        let replica = NotebookReplica(directory: directory)
        replica.suspendLocalEditsForPendingReset()

        do {
            try await replica.load()
            XCTFail("A pending reset must prevent catalog installation")
        } catch let error as NotebookReplicaError {
            XCTAssertEqual(error, .resetPending)
        }

        XCTAssertNil(replica.catalogSnapshot)
        XCTAssertTrue(replica.placements.isEmpty)
    }

    func testCatalogStartupAndRecentActivityBenchmark() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MEH_CATALOG_BENCHMARK"] == "1",
            "Set MEH_CATALOG_BENCHMARK=1 to run the synthetic catalog benchmark."
        )

        let counts = ProcessInfo.processInfo.environment["MEH_CATALOG_COUNTS"]?
            .split(separator: ",").compactMap { Int($0) } ?? [100, 500]
        var reports: [[String: Any]] = []
        for count in counts where count > 0 {
            reports.append(try await runCase(itemCount: count))
        }
        let data = try JSONSerialization.data(
            withJSONObject: reports, options: [.sortedKeys]
        )
        if let path = ProcessInfo.processInfo.environment["MEH_CATALOG_BENCHMARK_REPORT"] {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        print("MEH_CATALOG_BENCHMARK \(String(decoding: data, as: UTF8.self))")
    }

    private func runCase(itemCount: Int) async throws -> [String: Any] {
        let notebookID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let catalog = try NotebookCatalogDocument(notebookID: notebookID)
        let noteIDs = (0..<itemCount).map { index in
            UUID(uuidString: String(format: "00000000-0000-4000-8000-%012X", index + 1))!
        }
        for (index, id) in noteIDs.enumerated() {
            _ = try catalog.add(
                id: id, kind: .note, name: String(format: "Note %04d.md", index)
            )
        }
        for id in noteIDs.dropFirst() {
            try catalog.recordRecentActivity(for: id)
        }
        let fixture = catalog.snapshot()

        var samples: [String: [Double]] = [:]
        for _ in 0..<3 {
            let start = ProcessInfo.processInfo.systemUptime
            let snapshot = catalog.snapshot()
            samples["snapshot_ms", default: []].append(elapsedMilliseconds(since: start))
            XCTAssertEqual(snapshot, fixture)

            let loadStart = ProcessInfo.processInfo.systemUptime
            let loaded = try NotebookCatalogDocument(snapshot: fixture)
            _ = try loaded.placements()
            _ = try loaded.historicalLinkLocations()
            _ = try loaded.templateMetadata()
            _ = try loaded.defaultNewNoteParentID()
            _ = try loaded.recentStates()
            samples["validated_startup_projection_ms", default: []]
                .append(elapsedMilliseconds(since: loadStart))

            let editStart = ProcessInfo.processInfo.systemUptime
            let edited = try catalog.fork()
            try edited.recordRecentActivity(for: noteIDs[0])
            _ = edited.snapshot()
            samples["activity_fork_and_snapshot_ms", default: []]
                .append(elapsedMilliseconds(since: editStart))
        }

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "catalog-benchmark-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await NotebookCatalogStorage(directory: directory).save(fixture)
        let replica = NotebookReplica(directory: directory)
        let replicaStart = ProcessInfo.processInfo.systemUptime
        let loadHeartbeat = MainActorHeartbeat()
        loadHeartbeat.start()
        await Task.yield()
        try await replica.load()
        loadHeartbeat.stop()
        samples["replica_load_ms", default: []].append(
            elapsedMilliseconds(since: replicaStart)
        )
        samples["replica_load_max_main_actor_gap_ms", default: []].append(
            loadHeartbeat.maximumGapMilliseconds
        )
        let activityStart = ProcessInfo.processInfo.systemUptime
        let activityHeartbeat = MainActorHeartbeat()
        activityHeartbeat.start()
        await Task.yield()
        try await replica.recordRecentActivity(for: noteIDs[0])
        activityHeartbeat.stop()
        samples["replica_first_activity_write_ms", default: []].append(
            elapsedMilliseconds(since: activityStart)
        )
        samples["replica_first_activity_max_main_actor_gap_ms", default: []].append(
            activityHeartbeat.maximumGapMilliseconds
        )

        return [
            "item_count": itemCount,
            "history_activity_count": max(0, itemCount - 1),
            "snapshot_bytes": fixture.data.count,
            "notebook_id": notebookID.uuidString,
            "measurements_ms": samples,
        ]
    }

    private func elapsedMilliseconds(since start: TimeInterval) -> Double {
        (ProcessInfo.processInfo.systemUptime - start) * 1_000
    }
}
