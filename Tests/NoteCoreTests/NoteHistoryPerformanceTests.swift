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
        XCTAssertEqual(versions.count, Self.sessionCount(edits: editCount) - 1)
        XCTAssertTrue(versions.allSatisfy(\.isOverviewStop))
        let legacy = try NoteHistoryLegacyOracle(snapshot: note.snapshot())
        let legacyStart = clock.now
        let legacyVersions = try legacy.historyVersions()
        let legacyIndex = Self.seconds(legacyStart.duration(to: clock.now))
        let detailedStart = clock.now
        let detailed = try NoteDocument(snapshot: note.snapshot())
            .historyVersions(detailed: true)
        let detailedIndex = Self.seconds(detailedStart.duration(to: clock.now))
        XCTAssertEqual(detailed.count, editCount)
        XCTAssertEqual(detailed.map(NoteHistoryTests.state),
                       legacyVersions.map(NoteHistoryTests.state))
        if let value = environment["MEH_HISTORY_INDEX_REGRESSION_FACTOR"],
           let factor = Double(value) {
            XCTAssertLessThanOrEqual(index, legacyIndex * factor + 0.1)
            XCTAssertLessThanOrEqual(detailedIndex, legacyIndex * factor + 0.1)
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
        let signature = detailed.map {
            "\(NoteHistoryTests.state($0))|\($0.isOverviewStop)"
        }.joined(separator: "\n")
        let versionDigest = SHA256.hash(data: Data(signature.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let fixtureDigest = SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }.joined()
        if editCount == 600 && lineCount == 1_800 {
            XCTAssertEqual(bytes.count, 3_164)
            XCTAssertEqual(fixtureDigest,
                "364d96d368fa160de0a99f1696af9076c22bd9935fdabbdae0cc88cdf252429a")
            XCTAssertEqual(versionDigest,
                "32e5ccb4e37ed841dcbf3d47e232cdaf327d4badc9d499f5743192ba23e488ba")
        } else if editCount == 600 && lineCount == 7_460 {
            XCTAssertEqual(try note.text.utf8.count, 500_444)
            XCTAssertEqual(bytes.count, 4_711)
            XCTAssertEqual(fixtureDigest,
                "d6921bd5d90716adc75170aab177cbb9bd87e9fbccb9b5c6d9c815482582ea05")
            XCTAssertEqual(versionDigest,
                "0bb2f09750d32d18bc388ee140fece646b4d539c16616382ab3415aadc4412d6")
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
            "detailedIndexSeconds": detailedIndex,
            "sessionFocusDetailSeconds": sessionMetrics.focus,
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

    /// A note typed word by word, like real notes: every change is a
    /// separate operation, unlike the pasted body above. Comparing two
    /// states then costs more as the note grows. Opt in to larger counts.
    func testTypedNoteHistoryBenchmark() throws {
        let environment = ProcessInfo.processInfo.environment
        let changes = Int(environment["MEH_HISTORY_TYPED_CHANGES"] ?? "300") ?? 300
        let bytes = try makeTypedFixture(changes: changes)
        let clock = ContinuousClock()
        let note = try NoteDocument(serializedData: bytes)
        let indexStart = clock.now
        let versions = try note.historyVersions()
        let index = Self.seconds(indexStart.duration(to: clock.now))
        XCTAssertEqual(versions.count, changes / 50 - 1)
        let legacyStart = clock.now
        let legacy = try NoteHistoryLegacyOracle(snapshot: note.snapshot()).historyVersions()
        let legacyIndex = Self.seconds(legacyStart.duration(to: clock.now))
        XCTAssertEqual(legacy.count, changes - 1)
        let detailNote = try NoteDocument(serializedData: bytes)
        let builder = try detailNote.makeHistoryBuilder()
        while !builder.isComplete { try builder.advance(batchSize: 128) }
        let detailStart = clock.now
        XCTAssertTrue(try builder.advanceDetails(ofSession: builder.sessionCount / 2, batchSize: 128))
        let detail = Self.seconds(detailStart.duration(to: clock.now))
        if let value = environment["MEH_HISTORY_TYPED_MINIMUM_SPEEDUP"],
           let speedup = Double(value) {
            XCTAssertGreaterThanOrEqual(legacyIndex / max(index, 0.001), speedup)
        }
        let metrics: [String: Any] = [
            "tag": "MEH_HISTORY_TYPED_BENCHMARK",
            "changes": note.historyCount, "fixtureBytes": bytes.count,
            "bodyScalars": try note.text.unicodeScalars.count,
            "sessions": builder.sessionCount,
            "indexSeconds": index, "legacyIndexSeconds": legacyIndex,
            "sessionDetailSeconds": detail,
        ]
        let json = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
        print(String(decoding: json, as: UTF8.self))
    }

    /// Words typed at varying places, 50 changes per session in steps of
    /// ten words.
    func makeTypedFixture(changes: Int) throws -> Data {
        let raw = Document(textEncoding: .unicodeScalar)
        raw.actor = ActorId(uuid: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!)
        try raw.put(obj: .ROOT, key: "noteID", value: .String(UUID().uuidString))
        try raw.put(obj: .ROOT, key: "schemaVersion", value: .Uint(1))
        let body = try raw.putObject(obj: .ROOT, key: "text", ty: .Text)
        let words = ["Fictional ", "café ", "notes ", "e\u{301} ", "👋🏽 ", "\n", "- item "]
        var length: UInt64 = 0
        var seed: UInt64 = 42
        for change in 0 ..< changes {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let date = Date(timeIntervalSince1970: 1_000 + Double(change) * 2
                + Double(change / 10) * 10 + Double(change / 50) * 600)
            let word = words[Int(seed >> 33) % words.count]
            let position = length == 0 ? 0 : (seed >> 20) % (length + 1)
            for (offset, scalar) in word.unicodeScalars.enumerated() {
                try raw.spliceText(obj: body, start: position + UInt64(offset), delete: 0,
                    value: String(scalar))
            }
            length += UInt64(word.unicodeScalars.count)
            try raw.put(obj: .ROOT, key: "modifiedAt", value: .Timestamp(date))
            raw.commitWith(timestamp: date)
        }
        return raw.save()
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
            let date = start.addingTimeInterval(Self.offset(ofEdit: edit))
            try raw.spliceText(obj: body, start: position, delete: 0,
                value: edit % 19 == 0 ? "\n" : "x")
            try raw.put(obj: .ROOT, key: "modifiedAt", value: .Timestamp(date))
            raw.commitWith(timestamp: date)
            position += 1
        }
        return raw.save()
    }

    /// Edits ten seconds apart are each a step of their session. Typing
    /// pauses for ten minutes after every 40 edits, so the fixture has
    /// several edit sessions.
    static func offset(ofEdit edit: Int) -> TimeInterval {
        Double(edit + 1) * 10 + Double(edit / 40) * 600
    }

    static func sessionCount(edits: Int) -> Int {
        max(1, (edits + 39) / 40)
    }

    @MainActor
    private static func measureSession(snapshot: NoteSnapshot) async throws -> (
        first: Double, reopen: Double, preview: Double, ready: Double, focus: Double
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
        let preview = Self.seconds(previewStart.duration(to: clock.now))
        let focusStart = clock.now
        for try await _ in await reader.details(near: versions[versions.count / 2]) {}
        let focus = Self.seconds(focusStart.duration(to: clock.now))
        return (first, reopen, preview, ready, focus)
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
