import Automerge
import CryptoKit
import Foundation
import XCTest

@testable import NoteCore

final class NoteHistoryPerformanceTests: XCTestCase {
    /// Opt in to larger local measurements; ordinary CI uses a small fixture.
    func testLargeFictionalDocumentHistoryBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        let editCount = Int(environment["MEH_HISTORY_BENCHMARK_EDITS"] ?? "80") ?? 80
        let lineCount = Int(environment["MEH_HISTORY_BENCHMARK_LINES"] ?? "200") ?? 200
        let fixturePath = environment["MEH_HISTORY_BENCHMARK_FIXTURE"]
        let bytes: Data
        if let fixturePath, FileManager.default.fileExists(atPath: fixturePath) {
            bytes = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
        } else {
            bytes = try makeFixture(lines: lineCount, edits: editCount)
            if let fixturePath {
                try bytes.write(to: URL(fileURLWithPath: fixturePath))
            }
        }
        if let directory = environment["MEH_HISTORY_BENCHMARK_NOTEBOOK"] {
            let root = URL(fileURLWithPath: directory)
            let note = try NoteDocument(serializedData: bytes)
            let catalog = try NotebookCatalogDocument(
                notebookID: UUID(uuidString: "22222222-3333-4444-8555-666666666666")!)
            try catalog.add(id: note.noteID, kind: .note, name: "Aurora Observatory")
            try await NotebookCatalogStorage(directory: root).save(catalog.snapshot())
            try await NoteFileStorage(directory: root.appending(path:
                "notes/\(note.noteID.uuidString)")).save(note.snapshot())
        }
        let clock = ContinuousClock()
        let decodeStart = clock.now
        let note = try NoteDocument(serializedData: bytes)
        let decode = Self.seconds(decodeStart.duration(to: clock.now))
        let indexStart = clock.now
        let versions = try note.historyVersions()
        let index = Self.seconds(indexStart.duration(to: clock.now))
        XCTAssertEqual(versions.count, editCount)
        let legacy = try NoteHistoryLegacyOracle(snapshot: note.snapshot())
        let legacyStart = clock.now
        let legacyVersions = try legacy.historyVersions()
        let legacyIndex = Self.seconds(legacyStart.duration(to: clock.now))
        XCTAssertEqual(versions, legacyVersions)
        if let value = environment["MEH_HISTORY_INDEX_REGRESSION_FACTOR"],
           let factor = Double(value) {
            XCTAssertLessThanOrEqual(index, legacyIndex * factor + 0.1)
        }
        let reopenStart = clock.now
        XCTAssertEqual(try note.historyVersions(), versions)
        let reopen = Self.seconds(reopenStart.duration(to: clock.now))
        let selected = [0, versions.count / 2, versions.count - 1]
        let previewStart = clock.now
        for offset in selected {
            let text = try note.historicalText(for: versions[offset])
            XCTAssertTrue(text.hasPrefix("# Fictional Observatory\n"))
        }
        let preview = Self.seconds(previewStart.duration(to: clock.now))
        if let value = environment["MEH_HISTORY_INDEX_BUDGET_SECONDS"],
           let budget = Double(value) {
            XCTAssertLessThan(index, budget)
        }
        let sessionMetrics = try await Self.measureSession(snapshot: note.snapshot())
        if let value = environment["MEH_HISTORY_INDEX_REGRESSION_FACTOR"],
           let factor = Double(value) {
            XCTAssertLessThanOrEqual(sessionMetrics.first, legacyIndex * factor + 0.1,
                "The progressive reader must preserve full-index throughput")
        }
        if let value = environment["MEH_HISTORY_INDEX_BUDGET_SECONDS"],
           let budget = Double(value) {
            XCTAssertLessThan(sessionMetrics.first, budget,
                "The progressive reader must finish within the indexing ceiling")
        }
        if let value = environment["MEH_HISTORY_FIRST_READY_BUDGET_SECONDS"],
           let budget = Double(value) {
            XCTAssertLessThan(sessionMetrics.ready, budget)
        }
        for (key, duration) in [
            ("MEH_HISTORY_REOPEN_BUDGET_SECONDS", sessionMetrics.reopen),
            ("MEH_HISTORY_PREVIEW_BUDGET_SECONDS", sessionMetrics.preview)
        ] {
            if let value = environment[key], let budget = Double(value) {
                XCTAssertLessThan(duration, budget, key)
            }
        }
        let signature = versions.map {
            "\($0.id)|\($0.ordinal)|\($0.date?.timeIntervalSince1970 ?? -1)|\($0.isOverviewStop)"
        }.joined(separator: "\n")
        let versionDigest = SHA256.hash(data: Data(signature.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let fixtureDigest = SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }.joined()
        if editCount == 600 && lineCount == 1_800 {
            XCTAssertEqual(bytes.count, 2_886)
            XCTAssertEqual(fixtureDigest,
                "79b6886fad7c7563a885dec09b7efe4fb02a26ea79a5d2ac91fb131731b1e302")
            XCTAssertEqual(versionDigest,
                "de09d52f3ea3e316186cb4dc95f9015de93b4bb6fc82c79e6a84fc9878b9fab5")
        } else if editCount == 600 && lineCount == 7_460 {
            XCTAssertEqual(try note.text.utf8.count, 500_444)
            XCTAssertEqual(bytes.count, 4_406)
            XCTAssertEqual(fixtureDigest,
                "748d553f2dc7f359b820aeff90c7d6868233f57194b8ca3c04590f48320bc8cf")
            XCTAssertEqual(versionDigest,
                "8c4aea2822c10e316b244bf342d3c7e039145486fb4121c11b4953e2c3c3be8e")
        }
        let metrics: [String: Any] = [
            "tag": "MEH_HISTORY_BENCHMARK",
            "label": environment["MEH_HISTORY_BENCHMARK_LABEL"] ?? "current",
            "edits": editCount, "lines": lineCount, "fixtureBytes": bytes.count,
            "versions": versions.count, "versionDigest": versionDigest,
            "fixtureDigest": fixtureDigest,
            "bodyUTF8Bytes": try note.text.utf8.count,
            "historyChanges": note.historyCount,
            "decodeSeconds": decode,
            "indexSeconds": index, "legacyIndexSeconds": legacyIndex,
            "cachedIndexSeconds": reopen,
            "sessionFirstLoadSeconds": sessionMetrics.first,
            "sessionReopenSeconds": sessionMetrics.reopen,
            "sessionThreePreviewsSeconds": sessionMetrics.preview,
            "sessionFirstReadySeconds": sessionMetrics.ready,
            "threePreviewsSeconds": preview
        ]
        let json = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
        print(String(decoding: json, as: UTF8.self))
    }

    func makeFixture(lines: Int, edits: Int) throws -> Data {
        let identity = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let raw = Document(textEncoding: .unicodeScalar)
        raw.actor = ActorId(uuid: identity)
        try raw.put(obj: .ROOT, key: "noteID", value: .String(identity.uuidString))
        try raw.put(obj: .ROOT, key: "schemaVersion", value: .Uint(1))
        let body = try raw.putObject(obj: .ROOT, key: "text", ty: .Text)
        let text = "# Fictional Observatory\n" + String(repeating:
            "Café e\u{301} 👋🏽 observations from a fictional mountain station.\n",
            count: lines)
        try raw.spliceText(obj: body, start: 0, delete: 0, value: text)
        let start = Date(timeIntervalSince1970: 1_000)
        try raw.put(obj: .ROOT, key: "createdAt", value: .Timestamp(start))
        try raw.put(obj: .ROOT, key: "modifiedAt", value: .Timestamp(start))
        raw.commitWith(timestamp: start)
        var position = UInt64(text.unicodeScalars.count)
        for edit in 0..<edits {
            let date = start.addingTimeInterval(Double(edit + 1))
            try raw.spliceText(obj: body, start: position, delete: 0,
                value: edit % 19 == 0 ? "\n" : "x")
            try raw.put(obj: .ROOT, key: "modifiedAt", value: .Timestamp(date))
            raw.commitWith(timestamp: date)
            position += 1
        }
        return raw.save()
    }

    @MainActor
    private static func measureSession(snapshot: NoteSnapshot) async throws -> (
        first: Double, reopen: Double, preview: Double, ready: Double
    ) {
        let session = NoteSession(storage: HistoryBenchmarkStorage(snapshot: snapshot))
        await session.load()
        let clock = ContinuousClock()
        let firstStart = clock.now
        let versions: [NoteHistoryVersion]
        var ready = 0.0
        let reader = try session.makeHistoryReader()
        var latest: [NoteHistoryVersion] = []
        for try await update in await reader.updates() {
            if ready == 0 && !update.versions.isEmpty {
                ready = Self.seconds(firstStart.duration(to: clock.now))
            }
            latest = update.versions
        }
        versions = latest
        let first = Self.seconds(firstStart.duration(to: clock.now))
        let reopenStart = clock.now
        let reopened = try await session.loadHistoryVersions()
        XCTAssertEqual(reopened, versions)
        let reopen = Self.seconds(reopenStart.duration(to: clock.now))
        let previewStart = clock.now
        for index in [0, versions.count / 2, versions.count - 1] {
            _ = try await session.makeHistoryReader().historicalText(for: versions[index])
        }
        return (first, reopen, Self.seconds(previewStart.duration(to: clock.now)), ready)
    }

    private static func seconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
}

private actor HistoryBenchmarkStorage: NoteStorage {
    let snapshot: NoteSnapshot
    init(snapshot: NoteSnapshot) { self.snapshot = snapshot }
    func load() -> NoteLoadResult { .current(snapshot) }
    func save(_ snapshot: NoteSnapshot) throws { }
    func recover(_ recovery: NoteRecovery) throws -> NoteSnapshot { snapshot }
}
