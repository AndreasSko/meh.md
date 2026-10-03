import Foundation
import XCTest

@testable import NoteCore

@MainActor
final class NoteTypingPerformanceTests: XCTestCase {
    func testWholeTextAndRangeTypingWithPriorHistory() async throws {
        guard ProcessInfo.processInfo.environment["MEH_TYPING_BENCHMARK"] == "1" else {
            throw XCTSkip("Set MEH_TYPING_BENCHMARK=1 to run core typing timings")
        }
        var cases: [[String: Any]] = []
        for sizeKB in [50, 500] {
            for priorEdits in [0, 400] {
                let seed = try NoteDocument(text: fixture(sizeKB: sizeKB))
                var expected = try seed.text
                for index in 0..<priorEdits {
                    let deleting = index % 5 == 4
                    let range = NSRange(location: expected.utf16.count - (deleting ? 1 : 0),
                                        length: deleting ? 1 : 0)
                    let replacement = deleting ? "" : String(index % 10)
                    try seed.replaceUTF16(range: range, with: replacement)
                    expected = (expected as NSString).replacingCharacters(in: range,
                                                                         with: replacement)
                }
                // Both paths load the same persisted baseline, including its
                // tombstones and causal history. Seeding/loading is untimed.
                let baseline = seed.snapshot()
                let reloaded = try NoteDocument(snapshot: baseline)
                XCTAssertTrue(try reloaded.text.utf8.elementsEqual(expected.utf8))
                let historyCount = reloaded.historyCount
                let paths = priorEdits == 0 ? ["whole_text", "utf16_range", "native_delta"]
                    : ["native_delta", "utf16_range", "whole_text"]
                for path in paths {
                    cases.append(try await measure(path: path, baseline: baseline,
                                             expected: expected, sizeKB: sizeKB,
                                             priorEdits: priorEdits, historyCount: historyCount))
                }
            }
        }
        let report: [String: Any] = [
            "scenario": "core-typing-history", "cases": cases,
            "system": ProcessInfo.processInfo.operatingSystemVersionString,
            "measurement_note": "Serial core commits; no editor, catalog, disk or CloudKit. "
                + "Text extraction is separate. Snapshots follow every five edits. "
                + "native_delta uses NoteSession and reads its cached text; other paths use "
                + "NoteDocument and extract CRDT text. Use a release build; no timing assertions."
        ]
        let data = try JSONSerialization.data(withJSONObject: report,
                                              options: [.prettyPrinted, .sortedKeys])
        if let path = ProcessInfo.processInfo.environment["MEH_TYPING_BENCHMARK_REPORT"],
           !path.isEmpty {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        print("MEH_TYPING_BENCHMARK_JSON_BEGIN")
        print(try XCTUnwrap(String(data: data, encoding: .utf8)))
        print("MEH_TYPING_BENCHMARK_JSON_END")
    }

    private func measure(
        path: String, baseline: NoteSnapshot, expected initial: String,
        sizeKB: Int, priorEdits: Int, historyCount: Int
    ) async throws -> [String: Any] {
        let document = try NoteDocument(snapshot: baseline)
        let session = path == "native_delta"
            ? NoteSession(storage: TypingBenchmarkStorage(baseline)) : nil
        if let session { await session.load() }
        var expected = initial
        var commits: [Double] = []
        var extraction: [Double] = []
        var snapshots: [Double] = []
        var latestSnapshot = baseline
        for index in 0..<25 {
            let location = expected.utf16.count
            expected += "x"
            let revision = document.editorHeads
            let start = ProcessInfo.processInfo.systemUptime
            if let session {
                try session.commitEditorText(expected,
                    basedOn: XCTUnwrap(session.editorRevision),
                    change: NoteEditorTextChange(range: NSRange(location: location, length: 0),
                                                 replacement: "x"))
            } else if path == "whole_text" {
                try document.applyEditorText(expected, basedOn: revision)
            } else {
                try document.replaceUTF16(range: NSRange(location: location, length: 0),
                                          with: "x")
            }
            commits.append(milliseconds(since: start))
            let extractionStart = ProcessInfo.processInfo.systemUptime
            let actual = try session?.text ?? document.text
            extraction.append(milliseconds(since: extractionStart))
            XCTAssertTrue(actual.utf8.elementsEqual(expected.utf8))
            if index % 5 == 4 {
                let snapshotStart = ProcessInfo.processInfo.systemUptime
                latestSnapshot = try session.map { try XCTUnwrap($0.currentSnapshot) }
                    ?? document.snapshot()
                snapshots.append(milliseconds(since: snapshotStart))
            }
        }
        if let session { try await session.flush() }
        let restored = try NoteDocument(snapshot: latestSnapshot)
        XCTAssertTrue(try restored.text.utf8.elementsEqual(expected.utf8))
        return ["path": path, "requested_kb": sizeKB,
                "baseline_utf8_bytes": initial.utf8.count,
                "seeded_edit_operations": priorEdits,
                "baseline_history_count": historyCount,
                "baseline_snapshot_bytes": baseline.data.count,
                "final_snapshot_bytes": latestSnapshot.data.count,
                "commit_ms": summary(commits),
                "post_commit_text_extraction_ms": summary(extraction),
                "snapshot_ms": summary(snapshots),
                "literal_text_and_snapshot_roundtrip_verified": true]
    }

    private func summary(_ samples: [Double]) -> [String: Any] {
        let ordered = samples.sorted()
        let middle = ordered.count / 2
        let median = ordered.count % 2 == 0
            ? (ordered[middle - 1] + ordered[middle]) / 2 : ordered[middle]
        return ["samples": samples, "median": median,
                "p95": ordered[Int(ceil(Double(ordered.count) * 0.95)) - 1]]
    }

    private func milliseconds(since start: TimeInterval) -> Double {
        (ProcessInfo.processInfo.systemUptime - start) * 1_000
    }

    private func fixture(sizeKB: Int) -> String {
        let paragraph = "Fictional observatory: café, Größe and moon 🪐. "
            + "An ordinary paragraph records a bright star.\n\n"
        return String(repeating: paragraph,
                      count: (sizeKB * 1_000 + paragraph.utf8.count - 1) / paragraph.utf8.count)
    }
}

private actor TypingBenchmarkStorage: NoteStorage {
    var latest: NoteSnapshot
    init(_ snapshot: NoteSnapshot) { latest = snapshot }
    func load() -> NoteLoadResult { .current(latest) }
    func save(_ snapshot: NoteSnapshot) { latest = snapshot }
    func recover(_ recovery: NoteRecovery) -> NoteSnapshot { recovery.previous }
}
