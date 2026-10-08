import CryptoKit
import Foundation
import XCTest

@testable import NativeEditor

@MainActor
final class MarkdownFullParsePerformanceTests: XCTestCase {
    func testUnicodePairedMarkersPreserveLiteralRanges() {
        let text = "🪐 café e\u{0301} ==亮い== and ~~古い~~\n"
            + "\\==escaped== `==code==`\n===run=== ~~~run~~~\n"
            + "==open\nclose==\n"
        let spans = MarkdownSyntax.parse(text).spans.filter {
            $0.role == .highlight || $0.role == .strikethrough
        }
        XCTAssertEqual(spans.map { (text as NSString).substring(with: $0.range) },
                       ["==亮い==", "~~古い~~"])
        XCTAssertEqual(spans.map(\.role), [.highlight, .strikethrough])
    }

    func testLongMarkerRunsDoNotContainAnIsolatedPair() {
        for marker in ["=", "~"] {
            let text = "🪐 " + String(repeating: marker, count: 10_000) + "🪐"
            XCTAssertFalse(MarkdownSyntax.parse(text).spans.contains {
                $0.role == .highlight || $0.role == .strikethrough
            })
        }
    }

    func testUnicodeTablesAndExclusionsPreserveCellSyntax() {
        let text = "<!-- [[Hidden]] -->\n```\n==code==\n```\n"
            + "| Café | 星 |\n| --- | --- |\n| ==e\u{0301}🪐== | ~~古い~~ |\n"
        let result = MarkdownSyntax.parse(text)
        XCTAssertEqual(result.tables.count, 1)
        XCTAssertEqual(result.spans.filter {
            $0.role == .highlight || $0.role == .strikethrough
        }.map { (text as NSString).substring(with: $0.range) },
                       ["==e\u{0301}🪐==", "~~古い~~"])
        XCTAssertEqual(result.linkContextRanges.first,
                       NSRange(location: 0, length: "<!-- [[Hidden]] -->".utf16.count))
    }

    func testOptInFullParseTiming() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MEH_FULL_PARSE_BENCHMARK"] == "1" else {
            throw XCTSkip("Set MEH_FULL_PARSE_BENCHMARK=1 for parser timing")
        }
        var rows: [[String: Any]] = []
        for size in [50_000, 500_000] {
            let paragraph = "A fictional café e\u{0301} 🪐 note with 日本語, ==light== and ~~old~~.\n\n"
            let text = String(repeating: paragraph, count: size / paragraph.utf8.count + 1)
            let expected = MarkdownSyntax.parse(text)
            let fingerprint = SHA256.hash(data: Data(String(reflecting: expected).utf8))
                .map { String(format: "%02x", $0) }.joined()
            var samples: [Double] = []
            for _ in 0..<21 {
                let start = ContinuousClock.now
                let result = MarkdownSyntax.parse(text)
                let elapsed = start.duration(to: .now)
                let milliseconds = Double(elapsed.components.seconds) * 1_000
                    + Double(elapsed.components.attoseconds) / 1e15
                XCTAssertEqual(result, expected)
                samples.append(milliseconds)
            }
            let sorted = samples.sorted()
            rows.append(["utf8_bytes": text.utf8.count, "utf16_length": text.utf16.count,
                         "median_ms": sorted[10], "p95_ms": sorted[19], "samples_ms": samples,
                         "syntax_sha256": fingerprint])
        }
        let report: [String: Any] = ["label": environment["MEH_FULL_PARSE_LABEL"] ?? "unspecified",
                                    "fixture": "fictional Unicode paragraphs with paired markup",
                                    "measurements": rows]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if let path = environment["MEH_FULL_PARSE_REPORT"] {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        print(String(decoding: data, as: UTF8.self))
    }
}
