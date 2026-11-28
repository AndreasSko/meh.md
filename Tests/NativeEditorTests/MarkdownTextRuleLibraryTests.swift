import Foundation
import XCTest

@testable import NativeEditor

/// The example rules in docs/text-rules.
@MainActor
final class MarkdownTextRuleLibraryTests: XCTestCase {
    // MARK: - Bible references

    /// Each link as "linked text → bible code locale".
    private func references(
        _ text: String, options: [String: String] = [:], locale: String = "de-DE"
    ) throws -> [String] {
        let rule = try TextRuleHarness.example("bible-references")
        var resolved = ["open": "app", "language": "auto", "preferred": "auto"]
        resolved.merge(options) { _, new in new }
        let run = TextRuleHarness.run(rule, on: text, context: ["options": resolved, "locale": locale])
        XCTAssertNil(run.response.error)
        XCTAssertEqual(run.response.problems, [])
        return run.decorations.map { decoration in
            guard case .link(let url) = decoration.kind,
                  let components = URLComponents(string: url) else { return "not a link" }
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            })
            let linked = (text as NSString).substring(with: decoration.range)
            return "\(linked) → \(query["bible"] ?? "") \(query["wtlocale"] ?? "")"
        }
    }

    func testBibleReferencesInGermanAndEnglish() throws {
        let cases: [(String, [String])] = [
            ("Lies Johannes 3:16 heute.", ["Johannes 3:16 → 43003016 X"]),
            ("Read John 3:16 today.", ["John 3:16 → 43003016 E"]),
            ("Joh 3,16", ["Joh 3,16 → 43003016 X"]),
            ("Joh. 3:16", ["Joh. 3:16 → 43003016 X"]),
            ("Joh\u{A0}3:16", ["Joh\u{A0}3:16 → 43003016 X"]),
            ("Matthäus 24:14", ["Matthäus 24:14 → 40024014 X"]),
            ("Röm 5:12", ["Röm 5:12 → 45005012 X"]),
            ("Offb 21:4 und Rev 21:4", ["Offb 21:4 → 66021004 X", "Rev 21:4 → 66021004 E"]),
            ("Hohes Lied 2:1", ["Hohes Lied 2:1 → 22002001 X"]),
            ("Song of Solomon 2:1", ["Song of Solomon 2:1 → 22002001 E"]),
            ("Lies 1. Mose 1:1", ["1. Mose 1:1 → 01001001 X"]),
            ("1Mo 1:1 und 1 Mose 1,1", ["1Mo 1:1 → 01001001 X", "1 Mose 1,1 → 01001001 X"]),
            ("1 Johannes 4:8", ["1 Johannes 4:8 → 62004008 X"]),
            ("1 John 4:8", ["1 John 4:8 → 62004008 E"]),
            ("Siehe 2. Tim 3:16", ["2. Tim 3:16 → 55003016 X"]),
            ("Mose 3:4", []),
            ("Ps 83:18", ["Ps 83:18 → 19083018 X"]),
            ("Pr 3:5", ["Pr 3:5 → 21003005 X"]),
            ("Joh 3:16-18", ["Joh 3:16-18 → 43003016-43003018 X"]),
            ("Joh 3:16–4:2", ["Joh 3:16–4:2 → 43003016-43004002 X"]),
            ("Joh 3:16f", ["Joh 3:16f → 43003016-43003017 X"]),
            ("Joh 3:16, 18; 4:2", ["Joh 3:16 → 43003016 X", "18 → 43003018 X", "4:2 → 43004002 X"]),
            ("Joh 3,16.18; 4,2", ["Joh 3,16 → 43003016 X", "18 → 43003018 X", "4,2 → 43004002 X"]),
            ("Joh 3,16.18–20", ["Joh 3,16 → 43003016 X", "18–20 → 43003018-43003020 X"]),
            ("Röm 5:12; 1. Kor 15:22", ["Röm 5:12 → 45005012 X", "1. Kor 15:22 → 46015022 X"]),
            ("Joh 3:16, 5 Leute kamen", ["Joh 3:16 → 43003016 X"]),
            ("Joh 3:18-16", []),
            ("Psalm 23", ["Psalm 23 → 19023000 X"]),
            ("Jesaja 53 und Römer 8", ["Jesaja 53 → 23053000 X", "Römer 8 → 45008000 X"]),
            ("Lies 1. Korinther 13", ["1. Korinther 13 → 46013000 X"]),
            // At the start of a line, Markdown reads `1. ` as a numbered list.
            ("1. Mose 1:1", []),
            ("Judas 3", ["Judas 3 → 65001003 X"]),
            ("Jude 3", ["Jude 3 → 65001003 E"]),
            ("Daniel 2:44", ["Daniel 2:44 → 27002044 X"]),
            ("Da 2:44", ["Da 2:44 → 27002044 X"]),
            ("Erster Absatz.\n\nZweiter mit Joh 3:16.", ["Joh 3:16 → 43003016 X"]),
            ("- Lies Röm 8:28\n- und **Joh 3:16**", ["Röm 8:28 → 45008028 X", "Joh 3:16 → 43003016 X"]),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(try references(text), expected, text)
        }
    }

    func testBibleReferencesLeaveOtherNumbersAlone() throws {
        for text in [
            "Mark 2:30", "Mi 10:30", "Am 3:15 Uhr", "Treffen um Joh 3:15 Uhr",
            "Ruth 2 und Daniel 3", "ob 3,5 Liter reichen", "Da 3,5 Liter fehlen",
            "Johannesburg 3", "Psalm 151", "Joh 3:16:20", "Seite 12, Version 1:2",
            "Mo 10:30 Treffen", "john 3:16", "`Joh 3:16`", "[Joh 3:16](https://example.com)",
            "```\nJoh 3:16\n```",
            "Joh 3:0", "Joh 3:16-4:0",
        ] {
            XCTAssertEqual(try references(text), [], text)
        }
    }

    func testSharedBookNamesFollowTheDeviceLanguageOrTheChoice() throws {
        XCTAssertEqual(try references("Genesis 1:1", locale: "en-US"), ["Genesis 1:1 → 01001001 E"])
        XCTAssertEqual(try references("Genesis 1:1", locale: "de-AT"), ["Genesis 1:1 → 01001001 X"])
        XCTAssertEqual(try references("Genesis 1:1", options: ["preferred": "en"]),
                       ["Genesis 1:1 → 01001001 E"])
        XCTAssertEqual(try references("Pr 3:5", options: ["preferred": "en"]),
                       ["Pr 3:5 → 20003005 E"])
        XCTAssertEqual(try references("John 3:16", options: ["language": "de"]),
                       ["John 3:16 → 43003016 X"])
    }

    func testBibleLinksOpenJWLibraryOrJWOrg() throws {
        let rule = try TextRuleHarness.example("bible-references")
        func link(_ open: String) -> MarkdownTextRuleDecoration? {
            TextRuleHarness.run(rule, on: "Joh 3:16-18", context: [
                "options": ["open": open, "language": "auto", "preferred": "auto"],
                "locale": "de-DE",
            ]).decorations.first
        }
        XCTAssertEqual(link("app")?.kind, .link(url: "jwlibrary:///finder?bible=43003016-43003018&wtlocale=X"))
        XCTAssertEqual(link("web")?.kind, .link(url:
            "https://www.jw.org/finder?wtlocale=X&prefer=lang&bible=43003016-43003018&pub=nwtsty"))
        XCTAssertEqual(link("web")?.label, "Johannes 3:16–18")
    }

    func testBibleReferencesAreFastWithoutJIT() throws {
        let rule = try TextRuleHarness.example("bible-references")
        let paragraph = "Heute ging es um Hoffnung, siehe Joh 3:16, 18 und Röm 5:12; 6:23."
        let text = Array(repeating: paragraph, count: 1_000).joined(separator: "\n\n")
        let start = Date()
        let run = TextRuleHarness.run(rule, on: text, context: [
            "options": ["open": "app", "language": "auto", "preferred": "auto"], "locale": "de",
        ])
        XCTAssertNil(run.response.error)
        XCTAssertEqual(run.decorations.count, 4_000)
        // Only catches a large slowdown: simulators on CI are several times
        // slower than a Mac, which takes about 0.15 s.
        XCTAssertLessThan(Date().timeIntervalSince(start), 20)
    }

    func testEachExampleShowsSomethingForItsOwnSample() throws {
        for name in ["bible-references", "time-sums"] {
            let rule = try TextRuleHarness.example(name)
            XCTAssertFalse(rule.manifest.example.isEmpty, name)
            let run = TextRuleHarness.run(rule, on: rule.manifest.example)
            XCTAssertNil(run.response.error, name)
            XCTAssertFalse(run.decorations.isEmpty, name)
        }
    }

    // MARK: - Time sums

    /// Notes from the time calculator's tests that read the same in any
    /// note: no line is only `=`, which Markdown reads as a heading
    /// underline outside calculator notes.
    private let timeNotes = [
        "Drive to airport 50m\nSecurity and waiting 1h 30m\nFlight 2h 55m\nTime zone -1h\nTravel day =",
        "Time zone -1h\nTaxi 20m\nTotal =",
        "2h - \n30m =\n",
        "2h - later 30m =",
        "5h\n\nMo: +7m-1h-42m+26m\nDi:\n\nTotal =",
        "Mon-Fri 2h =\n1h-30m =",
        "3h\n-1h 30m\nSum =",
        "3h\n-1h30m\nSum =",
        "-30m 1h =",
        "2h + 30m =",
        "Half a day 0.5d, a break 1,5h =",
        "5 m and 2 h =",
        "1h\nFirst =\n20m\nSecond =\n\n10m\n# Next day\n5m\nThird =",
        "# Total =\n1h",
        "5min, 3 days, 2 hours, mp3m, v1.5h, 10s =",
        "Version 2 and 7 apples =\n",
        "- 30m\n- -10m\n+ 5m\nInline `2h` stays code\n[Watch 3h](https://example.com/5m)\n```\n9h\nNot a sum =\n```\nTotal =",
        "1h ==done==",
        "Week\n\n- Mon 1h\n- Tue 45m\n\n> Fri 2h\n\nAll =",
        "1h -\n- 30m\nTotal =",
        "😀30m 1h =",
    ]

    func testTimeSumsMatchTheTimeCalculator() throws {
        let rule = try TextRuleHarness.example("time-sums")
        for text in timeNotes {
            let expected = MarkdownTimeCalculator.sums(
                in: text, result: MarkdownSyntax.parse(text, timeSums: true))
            let run = TextRuleHarness.run(rule, on: text)
            XCTAssertNil(run.response.error, text)
            let actual = run.decorations.map { decoration -> String in
                guard case .insert(let value, .after, .muted) = decoration.kind else {
                    return "unexpected \(decoration.kind)"
                }
                return "\(decoration.range.location - 1):\(value)"
            }
            XCTAssertEqual(actual, expected.map {
                "\($0.location): \(MarkdownTimeCalculator.format($0.seconds))"
            }, text)
        }
    }

    func testTimeSumsSkipAmountsTooLargeForTheirState() throws {
        // The state is JSON, which has no Infinity.
        let rule = try TextRuleHarness.example("time-sums")
        let huge = String(repeating: "9", count: 309)
        let run = TextRuleHarness.run(rule, on: "\(huge)h\n\n1h\nTotal =")
        XCTAssertEqual(run.decorations.map(\.kind), [.insert(text: " 1h", side: .after, style: .muted)])
    }

    func testTimeSumsCarryTheirStateAcrossBlocks() throws {
        let rule = try TextRuleHarness.example("time-sums")
        XCTAssertTrue(rule.manifest.isStateful)
        XCTAssertTrue(rule.manifest.startsInChosenNotes)
        let run = TextRuleHarness.run(rule, on: "1m\n\n-5m +\n\n1m\nTotal =")
        XCTAssertEqual(run.decorations.map(\.kind), [.insert(text: " -3m", side: .after, style: .muted)])
    }
}
