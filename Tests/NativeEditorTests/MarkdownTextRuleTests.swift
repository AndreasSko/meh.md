import Foundation
import NoteCore
import XCTest

@testable import NativeEditor

/// Runs rules the way the editor does, without an editor.
@MainActor
enum TextRuleHarness {
    static func compile(_ source: String) throws -> MarkdownCompiledTextRule {
        try MarkdownTextRuleCompiler.compile(source).get()
    }

    /// One of the example rules in docs/text-rules.
    static func example(_ name: String) throws -> MarkdownCompiledTextRule {
        // CI links Tests into a copy of the package, so resolve the link.
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("docs/text-rules/\(name).js")
        return try compile(String(contentsOf: url, encoding: .utf8))
    }

    /// Every block of `text` in one batch, with decorations in note offsets.
    static func run(
        _ rule: MarkdownCompiledTextRule, on text: String, context: [String: Any] = [:],
        timeSums: Bool = false
    ) -> (decorations: [MarkdownTextRuleDecoration], response: MarkdownTextRuleRuntime.Response) {
        let result = MarkdownSyntax.parse(text, timeSums: timeSums)
        let blocks = MarkdownTextRuleBlocks.blocks(in: text, result: result, input: rule.manifest.input)
            .filter { rule.manifest.blocks.contains($0.kind) }
        var context = context
        if context["options"] == nil {
            var options: [String: Any] = [:]
            for option in rule.manifest.options {
                switch option.defaultValue {
                case .text(let value): options[option.key] = value
                case .toggle(let value): options[option.key] = value
                }
            }
            context["options"] = options
        }
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: context), as: UTF8.self)
        let runtime = MarkdownTextRuleRuntime(rule: rule)
        let request = MarkdownTextRuleRuntime.Request(
            blocks: blocks, known: blocks.map { _ in [] }, state: rule.manifest.start,
            context: json, batchBudget: 60_000)
        let response = runtime.queue.sync { runtime.run(request) }
        let decorations = zip(blocks, response.results).flatMap { block, result in
            result.decorations.map { $0.moved(by: block.range.location) }
        }
        return (decorations, response)
    }

    static func script(_ body: String, settings: String = "") -> String {
        """
        rule({
          api: 1, name: "Test", linksTo: ["https://example.com/"],\(settings)
          block(block, state, context) { \(body) }
        });
        """
    }
}

@MainActor
final class MarkdownTextRuleTests: XCTestCase {
    // MARK: - Reading a rule

    func testTheManifestIsReadWithoutRunningTheScript() throws {
        let rule = try TextRuleHarness.compile("""
            throw new Error("not run while compiling");
            rule({
              api: 1, name: " Tickets ", description: "Links tickets.",
              linksTo: ["https://tracker.example.com"], trigger: "[A-Z]-\\\\d",
              blocks: ["paragraph", "listItem"], uses: ["today"],
              options: {
                project: { title: "Project", type: "text", default: "ABC" },
                open: { title: "Open In", type: "choice", choices: { b: "Browser", a: "App" }, default: "a" },
                exact: { title: "Exact", type: "toggle", default: false },
              },
              block() {},
            });
            """)
        let manifest = rule.manifest
        XCTAssertEqual(manifest.name, "Tickets")
        XCTAssertEqual(manifest.description, "Links tickets.")
        XCTAssertEqual(manifest.linksTo.map(\.value), ["https://tracker.example.com/"])
        XCTAssertEqual(manifest.trigger, "[A-Z]-\\d")
        XCTAssertEqual(manifest.blocks, [.paragraph, .listItem])
        XCTAssertEqual(manifest.uses, [.today])
        XCTAssertFalse(manifest.isStateful)
        XCTAssertEqual(manifest.options.map(\.key), ["project", "open", "exact"])
        XCTAssertEqual(manifest.options[1].kind, .choice([
            .init(value: "b", title: "Browser"), .init(value: "a", title: "App"),
        ]))
        XCTAssertEqual(manifest.options[2].defaultValue, .toggle(false))
    }

    func testMistakesPointToTheirLine() {
        let cases: [(String, String, Int?)] = [
            ("rule({ name: 'x', block() {} ", "Unexpected token", 1),
            ("let a = 1;\nrule({ name: 1 + 1, block() {} })", "name must be written out as a plain value.", 2),
            ("rule({ name: 'x' })", "The rule needs a block function.", 1),
            ("rule({ name: 'x', block() {} }); rule({ name: 'y', block() {} })",
             "The script may call rule() only once.", 1),
            ("const x = 1;", "The script must call rule({ … }) once.", 1),
            ("rule({ name: 'x', colour: 'red', block() {} })", "Unknown setting “colour”.", 1),
            ("rule({ name: 'x', async block() {} })", "block must return its result right away, not later.", 1),
            ("__meh_tick = null; rule({ name: 'x', block() {} })", "Names starting with __meh are reserved.", 1),
            ("rule({ name: 'x', block() { import('y') } })", "Rules can’t load other code.", 1),
            ("rule({ block() {} })", "The rule needs a name.", nil),
            ("rule({ api: 2, name: 'x', block() {} })", "This rule needs a newer version of meh.md.", nil),
            ("rule({ name: 'x', linksTo: ['javascript:'], block() {} })", "“javascript:” can’t be used in linksTo.", nil),
            ("rule({ name: 'x', start: 0, trigger: 'a', block() {} })",
             "A rule with a start state can’t have a trigger: it has to see every block.", nil),
            ("rule({ name: 'x', options: { a: { title: 'A', type: 'choice', choices: { b: 'B' }, default: 'c' } }, block() {} })",
             "Option “a”: its default must be one of its choices.", nil),
        ]
        for (source, message, line) in cases {
            switch MarkdownTextRuleCompiler.compile(source) {
            case .success: XCTFail("Accepted: \(source)")
            case .failure(let error):
                XCTAssertEqual(error.message, message, source)
                XCTAssertEqual(error.line, line, source)
            }
        }
    }

    func testLinkPrefixesCantBeWidenedByTheHost() throws {
        let prefix = try XCTUnwrap(MarkdownTextRuleLinkPrefix("https://www.jw.org"))
        XCTAssertTrue(prefix.allows("https://www.jw.org/finder?bible=43003016"))
        XCTAssertTrue(prefix.allows("HTTPS://WWW.JW.ORG/de/"))
        XCTAssertFalse(prefix.allows("https://www.jw.org.example.test/"))
        XCTAssertFalse(prefix.allows("http://www.jw.org/"))
        XCTAssertNil(MarkdownTextRuleLinkPrefix("https://"))
        XCTAssertNil(MarkdownTextRuleLinkPrefix("www.jw.org/"))
        for scheme in ["javascript:", "data:text/html,", "file:///", "JavaScript:"] {
            XCTAssertNil(MarkdownTextRuleLinkPrefix(scheme), scheme)
        }
        XCTAssertEqual(MarkdownTextRuleLinkPrefix("jwlibrary:///finder?")?.value, "jwlibrary:///finder?")
    }

    // MARK: - Running a rule

    func testAnEndlessLoopStopsWithinItsBudget() throws {
        for body in [
            "while (true) {}",
            "for (;;) { try { while (true) {} } catch (e) {} }",
            "const spin = () => { for (const x of [1]) spin(); }; spin(); return {};",
            "let i = 0; do i++; while (i >= 0);",
        ] {
            let rule = try TextRuleHarness.compile(TextRuleHarness.script(body))
            let start = Date()
            let response = TextRuleHarness.run(rule, on: "Text").response
            XCTAssertLessThan(Date().timeIntervalSince(start), 2, body)
            XCTAssertNotNil(response.error, body)
        }
        let rule = try TextRuleHarness.compile(TextRuleHarness.script("while (true) {}"))
        XCTAssertTrue(TextRuleHarness.run(rule, on: "Text").response.isSlow)
    }

    func testRulesCantReachTheClockRandomnessOrSharedObjects() throws {
        let rule = try TextRuleHarness.compile(TextRuleHarness.script("""
            const facts = [typeof Date, typeof Math.random, typeof fetch, typeof setTimeout,
                           typeof XMLHttpRequest, typeof require];
            let changed = false;
            try { Array.prototype.extra = 1; changed = [].extra === 1; } catch (e) {}
            try { globalThis.leak = 1; changed = changed || globalThis.leak === 1; } catch (e) {}
            return { decorations: [{ kind: "insert", at: 0, text: facts.join() + "," + changed }] };
            """))
        let decorations = TextRuleHarness.run(rule, on: "Text").decorations
        guard case .insert(let text, _, _)? = decorations.first?.kind else {
            return XCTFail("No result")
        }
        XCTAssertEqual(text, "undefined,undefined,undefined,undefined,undefined,undefined,false")
    }

    func testErrorsReportTheirLine() throws {
        let rule = try TextRuleHarness.compile(TextRuleHarness.script("\nnull.x;"))
        let error = try XCTUnwrap(TextRuleHarness.run(rule, on: "Text").response.error)
        XCTAssertEqual(error.line, 4)
        XCTAssertTrue(error.message.contains("null"), error.message)
    }

    func testInvalidDecorationsAreLeftOut() throws {
        let rule = try TextRuleHarness.compile(TextRuleHarness.script("""
            return { decorations: [
              { kind: "link", start: 0, end: 4, url: "https://example.com/a", label: "A" },
              { kind: "link", start: 5, end: 9, url: "https://elsewhere.test/" },
              { kind: "link", start: 5, end: 9, url: "javascript:alert(1)" },
              { kind: "style", start: 0, end: 2, style: "loud" },
              { kind: "style", start: 3, end: 2, style: "muted" },
              { kind: "style", start: 10, end: 11, style: "muted" },
              { kind: "insert", at: 4, text: "x\\ny" },
              { kind: "insert", at: 4, text: " ✓", side: "before" },
              { kind: "hide", start: 0, end: 1 },
              { kind: "glow", start: 0, end: 1 },
            ] };
            """))
        // The emoji is two UTF-16 units: 10–11 would split it.
        let (decorations, response) = TextRuleHarness.run(rule, on: "Text text 😀")
        XCTAssertEqual(decorations, [
            .init(range: NSRange(location: 0, length: 4), kind: .link(url: "https://example.com/a"), label: "A"),
            .init(range: NSRange(location: 4, length: 0), kind: .insert(text: " ✓", side: .before, style: .muted)),
            .init(range: NSRange(location: 0, length: 1), kind: .hide),
        ])
        XCTAssertEqual(response.problems.count, 7, response.problems.joined(separator: "\n"))
    }

    func testDecorationsStayOffCodeAndLinks() throws {
        let rule = try TextRuleHarness.compile(TextRuleHarness.script("""
            return { decorations: [...block.text.matchAll(/\\d+/g)].map((m) => ({
              kind: "style", start: m.index, end: m.index + m[0].length, style: "accent" })) };
            """))
        let text = "1 `2` [3](https://example.com/4) 5"
        let ranges = TextRuleHarness.run(rule, on: text).decorations.map(\.range)
        XCTAssertEqual(ranges.map { (text as NSString).substring(with: $0) }, ["1", "5"])
    }

    // MARK: - Blocks

    func testBlocksFollowTheNoteStructure() {
        let text = """
            ---
            title: Week
            ---
            # Plan
            First line
            second line

            - Item one
              continued
            - [ ] Task **two**
              - Nested
            > Quote
            > more

            ```
            code 5m
            ```
            | A | B |
            |---|---|
            | 1 | 2 |
            ***
            After
            """
        let blocks = MarkdownTextRuleBlocks.blocks(
            in: text, result: MarkdownSyntax.parse(text), input: .plain)
        let mask = "\u{FFFC}"
        XCTAssertEqual(blocks.map(\.kind), [
            .heading, .paragraph, .listItem, .listItem, .listItem, .quote, .paragraph,
        ])
        XCTAssertEqual(blocks.map(\.level), [1, 1, 1, 1, 2, 1, 1])
        XCTAssertEqual(blocks[0].text, mask + mask + "Plan")
        XCTAssertEqual(blocks[1].lines.map(\.text), ["First line", "second line"])
        XCTAssertEqual(blocks[1].lines.map(\.start), [0, 11])
        XCTAssertEqual(blocks[2].text, mask + " Item one\n  continued")
        XCTAssertEqual(blocks[3].text, mask + " " + String(repeating: mask, count: 3)
                       + " Task " + mask + mask + "two" + mask + mask)
        XCTAssertEqual(blocks[5].lines.map(\.text), [mask + " Quote", mask + " more"])
        XCTAssertEqual(blocks.last?.text, "After")
        for block in blocks {
            XCTAssertEqual((block.text as NSString).length, block.range.length)
            XCTAssertEqual((text as NSString).substring(with: block.range), block.original)
        }
    }

    func testMarkdownInputKeepsTheMarkers() {
        let text = "**Bold** `code`"
        let block = MarkdownTextRuleBlocks.blocks(
            in: text, result: MarkdownSyntax.parse(text), input: .markdown).first
        XCTAssertEqual(block?.text, text)
        XCTAssertEqual(block?.protected, [NSRange(location: 9, length: 6)])
    }
}

@MainActor
final class MarkdownTextRuleSessionTests: XCTestCase {
    private func session(_ rules: [MarkdownCompiledTextRule]) -> MarkdownTextRuleSession {
        let session = MarkdownTextRuleSession()
        session.isActive = true
        session.configurations = rules.map { MarkdownTextRuleConfiguration(id: UUID(), rule: $0) }
        return session
    }

    private var revision: UInt64 = 0

    /// Shows `text` and waits until the rules finished with it.
    private func show(_ text: String, in session: MarkdownTextRuleSession) async throws {
        revision += 1
        session.update(text: text, result: MarkdownSyntax.parse(text), revision: revision)
        let deadline = Date().addingTimeInterval(5)
        while session.isRunning {
            guard Date() < deadline else { return XCTFail("Rules still running") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func linkTexts(_ session: MarkdownTextRuleSession, in text: String) -> [String] {
        session.decorations.links.map { (text as NSString).substring(with: $0.range) }
    }

    func testAnEditRunsOnlyTheBlockItChanged() async throws {
        let rule = try TextRuleHarness.compile(TextRuleHarness.script("""
            return { decorations: [...block.text.matchAll(/#\\d+/g)].map((m) => ({ kind: "link",
              start: m.index, end: m.index + m[0].length, url: "https://example.com/" + m[0].slice(1) })) };
            """))
        let session = session([rule])
        let first = "See #1\n\nAnd #2\n\nNothing here\n\nLast #3"
        try await show(first, in: session)
        XCTAssertEqual(linkTexts(session, in: first), ["#1", "#2", "#3"])
        XCTAssertEqual(session.blocksRun, 4)

        let edited = "See #1\n\nAnd #22\n\nNothing here\n\nLast #3"
        try await show(edited, in: session)
        XCTAssertEqual(linkTexts(session, in: edited), ["#1", "#22", "#3"])
        XCTAssertEqual(session.blocksRun, 5)

        // Undoing finds the old result without running anything.
        revision += 1
        session.update(text: first, result: MarkdownSyntax.parse(first), revision: revision)
        XCTAssertEqual(linkTexts(session, in: first), ["#1", "#2", "#3"])
        XCTAssertEqual(session.blocksRun, 5)
    }

    func testATriggerKeepsBlocksAwayFromTheScript() async throws {
        let rule = try TextRuleHarness.compile(TextRuleHarness.script(
            "return {};", settings: " trigger: \"\\\\d\","))
        let session = session([rule])
        try await show("One\n\nTwo 2\n\nThree", in: session)
        XCTAssertEqual(session.blocksRun, 1)
    }

    func testAStatefulRuleStopsOnceItsStateMatchesAgain() async throws {
        let rule = try TextRuleHarness.example("time-sums")
        let session = session([rule])
        let first = "1h\nA =\n\n2h\n\n3h\nB =\n\n4h\nC ="
        try await show(first, in: session)
        XCTAssertEqual(session.decorations.inserts.map(\.text), [" 1h", " 5h", " 4h"])
        XCTAssertEqual(session.blocksRun, 4)

        // `2h` → `20m` changes the sum below it, so that block runs again;
        // after B the state is back to what it was, so C does not.
        let edited = "1h\nA =\n\n20m\n\n3h\nB =\n\n4h\nC ="
        try await show(edited, in: session)
        XCTAssertEqual(session.decorations.inserts.map(\.text), [" 1h", " 3h 20m", " 4h"])
        XCTAssertEqual(session.blocksRun, 6)
    }

    func testRulesHigherInTheListWinOverlappingLinks() async throws {
        func linking(_ host: String) throws -> MarkdownCompiledTextRule {
            try TextRuleHarness.compile("""
                rule({ api: 1, name: "\(host)", linksTo: ["https://\(host)/"],
                  block(block) { return { decorations: [{ kind: "link", start: 0, end: 4,
                    url: "https://\(host)/x" }] }; } });
                """)
        }
        let session = session([try linking("first.test"), try linking("second.test")])
        try await show("Text", in: session)
        XCTAssertEqual(session.decorations.links.map(\.url), ["https://first.test/x"])
    }

    func testAFailingRuleShowsNothingAndReportsWhy() async throws {
        let rule = try TextRuleHarness.compile(TextRuleHarness.script("throw new Error('Broken');"))
        let session = session([rule])
        try await show("Text", in: session)
        XCTAssertTrue(session.decorations.isEmpty)
        XCTAssertEqual(session.problems.values.first?.message, "Broken")
    }

    func testComposedAndDecomposedTextKeepTheirOwnOffsets() async throws {
        let rule = try TextRuleHarness.compile(TextRuleHarness.script("""
            const at = block.text.indexOf("#");
            return { decorations: [{ kind: "link", start: at, end: at + 2,
              url: "https://example.com/1" }] };
            """))
        let session = session([rule])
        let composed = "Caf\u{E9} #1"
        try await show(composed, in: session)
        XCTAssertEqual(session.decorations.links.first?.range, NSRange(location: 5, length: 2))
        let decomposed = "Cafe\u{301} #1"
        try await show(decomposed, in: session)
        XCTAssertEqual(session.decorations.links.first?.range, NSRange(location: 6, length: 2))
    }

    func testARenameWhileRunningShowsTheNewTitle() async throws {
        let rule = try TextRuleHarness.compile("""
            rule({ api: 1, name: "Title", uses: ["title"],
              block(block, state, context) {
                return { decorations: [{ kind: "insert", at: 0, text: context.note.title }] };
              } });
            """)
        let session = session([rule])
        session.noteTitle = "Old"
        revision += 1
        session.update(text: "Text", result: MarkdownSyntax.parse("Text"), revision: revision)
        session.noteTitle = "New"
        try await show("Text", in: session)
        XCTAssertEqual(session.decorations.inserts.map(\.text), ["New"])
    }

    /// A regular expression that backtracks long enough to stand in for one
    /// that never ends, but finishes soon so the test leaves no busy thread.
    func testAStuckRuleGetsAFreshRuntimeWhenTurnedOnAgain() async throws {
        let rule = try TextRuleHarness.compile(TextRuleHarness.script(
            "/(a+)+$/.test('a'.repeat(22) + '!'); return {};"))
        let stuck = MarkdownTextRuleRuntime.shared(for: rule)
        let session = MarkdownTextRuleSession()
        session.responseLimit = 0.05
        session.isActive = true
        session.configurations = [MarkdownTextRuleConfiguration(id: UUID(), rule: rule)]
        try await show("Text", in: session)
        XCTAssertEqual(session.problems.values.first?.message, "The rule stopped responding.")
        XCTAssertTrue(MarkdownTextRuleHealth.isStuck(rule.identity))
        XCTAssertFalse(MarkdownTextRuleRuntime.shared(for: rule) === stuck)
        MarkdownTextRuleHealth.clear(rule.identity)
    }

    func testOtherEditorsMoveOffAStuckRuntime() async throws {
        let rule = try TextRuleHarness.compile(TextRuleHarness.script("""
            if (block.text === "Stuck") /(a+)+$/.test('a'.repeat(22) + '!');
            return { decorations: [{ kind: "insert", at: 0, text: "ok" }] };
            """))
        let stuck = MarkdownTextRuleSession()
        stuck.responseLimit = 0.05
        stuck.isActive = true
        stuck.configurations = [MarkdownTextRuleConfiguration(id: UUID(), rule: rule)]
        let other = MarkdownTextRuleSession()
        other.isActive = true
        other.configurations = [MarkdownTextRuleConfiguration(id: UUID(), rule: rule)]
        revision += 1
        stuck.update(text: "Stuck", result: MarkdownSyntax.parse("Stuck"), revision: revision)
        // Queued behind the stuck call on the shared runtime.
        try await show("Fine", in: other)
        XCTAssertEqual(other.decorations.inserts.map(\.text), ["ok"])
        XCTAssertTrue(other.problems.isEmpty)
        XCTAssertEqual(stuck.problems.values.first?.message, "The rule stopped responding.")
        MarkdownTextRuleHealth.clear(rule.identity)
    }

    func testAStuckRuntimeIsRetiredEvenAfterItsEditorCloses() async throws {
        let rule = try TextRuleHarness.compile(TextRuleHarness.script("""
            if (block.text === "Stuck") /(a+)+$/.test('a'.repeat(25) + '!');
            return { decorations: [{ kind: "insert", at: 0, text: "ok" }] };
            """))
        let original = MarkdownTextRuleRuntime.shared(for: rule)
        var closed: MarkdownTextRuleSession? = MarkdownTextRuleSession()
        closed?.responseLimit = 0.05
        closed?.isActive = true
        closed?.configurations = [MarkdownTextRuleConfiguration(id: UUID(), rule: rule)]
        revision += 1
        closed?.update(text: "Stuck", result: MarkdownSyntax.parse("Stuck"), revision: revision)
        closed = nil
        let other = MarkdownTextRuleSession()
        other.isActive = true
        other.configurations = [MarkdownTextRuleConfiguration(id: UUID(), rule: rule)]
        try await show("Fine", in: other)
        XCTAssertEqual(other.decorations.inserts.map(\.text), ["ok"])
        XCTAssertFalse(MarkdownTextRuleRuntime.shared(for: rule) === original)
        MarkdownTextRuleHealth.clear(rule.identity)
    }

    func testStatesThatOnlyLookAlikeAreKeptApart() async throws {
        // `é` and `e` + U+0301 are the same to Swift, not to the script.
        let rule = try TextRuleHarness.compile("""
            rule({ name: "x", start: "\\u00e9", block(block, state) {
              return { decorations: [{ kind: "insert", at: 0, text: String(state.length) }],
                       state: "e\\u0301" };
            } });
            """)
        let session = session([rule])
        try await show("Text\n\nText", in: session)
        XCTAssertEqual(session.decorations.inserts.map(\.text), ["1", "2"])
    }

    func testHidesInTheEditedParagraphShowAgainAlone() {
        let decorations = MarkdownTextRuleDecorations(rules: [[
            MarkdownTextRuleDecoration(range: NSRange(location: 0, length: 4), kind: .hide),
            MarkdownTextRuleDecoration(range: NSRange(location: 4, length: 3), kind: .hide),
        ]])
        XCTAssertEqual(decorations.hides, [NSRange(location: 0, length: 4), NSRange(location: 4, length: 3)])
    }

    func testAWarningStaysWhileItsBlockIsThere() async throws {
        let rule = try TextRuleHarness.compile(TextRuleHarness.script("""
            if (block.text.startsWith("Bad")) return { decorations: [{ kind: "nope" }] };
            return {};
            """))
        let session = session([rule])
        try await show("Bad\n\nGood", in: session)
        XCTAssertNotNil(session.problems.values.first)
        try await show("Bad\n\nGood!", in: session)
        XCTAssertNotNil(session.problems.values.first)
        try await show("Fine\n\nGood!", in: session)
        XCTAssertTrue(session.problems.isEmpty)
    }

    func testNothingRunsOutsideLivePreview() async throws {
        let rule = try TextRuleHarness.compile(TextRuleHarness.script("return {};"))
        let session = session([rule])
        session.isActive = false
        try await show("Text", in: session)
        XCTAssertEqual(session.blocksRun, 0)
    }
}

@MainActor
final class MarkdownTextRuleEditorTests: XCTestCase {
    private func editor(_ text: String) -> MarkdownTextView {
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        #if os(macOS)
        textView.string = text
        #else
        textView.text = text
        #endif
        MarkdownPresentation.configure(textView, mode: .livePreview)
        return textView
    }

    private func settle(_ textView: MarkdownTextView) async throws {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            try await Task.sleep(for: .milliseconds(10))
        } while textView.markdownSyntaxCache.textRules.isRunning && Date() < deadline
        // The refresh that applies the results runs on the next main turn.
        try await Task.sleep(for: .milliseconds(20))
    }

    func testRuleLinksAreUnderlinedInLivePreviewOnly() async throws {
        let rule = try TextRuleHarness.example("bible-references")
        let text = "Read John 3:16 today.\n\nAnd Ps 23."
        let textView = editor(text)
        textView.markdownSyntaxCache.textRules.configurations = [
            MarkdownTextRuleConfiguration(id: UUID(), rule: rule),
        ]
        MarkdownPresentation.refresh(textView, mode: .livePreview)
        try await settle(textView)

        let links = textView.markdownSyntaxCache.textRuleDecorations.links
        XCTAssertEqual(links.map { (text as NSString).substring(with: $0.range) }, ["John 3:16"])
        let storage = try XCTUnwrap(textView.textStorage)
        XCTAssertNotNil(storage.attribute(.underlineStyle, at: 6, effectiveRange: nil))
        XCTAssertNil(storage.attribute(.underlineStyle, at: 2, effectiveRange: nil))
        XCTAssertEqual(MarkdownTextRulePresentation.link(at: 6, in: textView)?.label, "John 3:16")

        MarkdownPresentation.refresh(textView, mode: .source)
        try await settle(textView)
        XCTAssertTrue(textView.markdownSyntaxCache.textRuleDecorations.isEmpty)
        XCTAssertNil(storage.attribute(.underlineStyle, at: 6, effectiveRange: nil))
    }

    func testInsertedTextLeavesTheNoteUnchanged() async throws {
        let rule = try TextRuleHarness.example("time-sums")
        let text = "Flight 2h 55m\nTotal ="
        let textView = editor(text)
        textView.markdownSyntaxCache.textRules.configurations = [
            MarkdownTextRuleConfiguration(id: UUID(), rule: rule),
        ]
        MarkdownPresentation.refresh(textView, mode: .livePreview)
        try await settle(textView)
        XCTAssertEqual(textView.markdownSyntaxCache.textRuleDecorations.inserts.map(\.text),
                       [" 2h 55m"])
        XCTAssertEqual(textView.markdownSyntaxCache.drawnTextRuleInserts.count, 1)
        XCTAssertEqual((textView.textStorage as NSTextStorage?)?.string, text)
    }

    func testRoomIsMadeForTextInsertedInsideALine() async throws {
        let rule = try TextRuleHarness.compile(TextRuleHarness.script("""
            return { decorations: [{ kind: "insert", at: 4, text: "(x)", side: "after" },
                                   { kind: "insert", at: 0, text: "→", side: "before" }] };
            """))
        let textView = editor("Text here")
        textView.markdownSyntaxCache.textRules.configurations = [
            MarkdownTextRuleConfiguration(id: UUID(), rule: rule),
        ]
        MarkdownPresentation.refresh(textView, mode: .livePreview)
        try await settle(textView)
        let storage = try XCTUnwrap(textView.textStorage)
        let kern = try XCTUnwrap(storage.attribute(.kern, at: 3, effectiveRange: nil) as? CGFloat)
        XCTAssertGreaterThan(kern, 5)
        let style = try XCTUnwrap(storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
            as? NSParagraphStyle)
        XCTAssertGreaterThan(style.firstLineHeadIndent, 5)
    }

    func testHiddenTextJoinsLivePreviewsHiddenMarkers() async throws {
        let rule = try TextRuleHarness.compile(TextRuleHarness.script("""
            return { decorations: [{ kind: "hide", start: 0, end: 4 }] };
            """))
        let textView = editor("Hide this\n\nAnd this")
        textView.markdownSyntaxCache.textRules.configurations = [
            MarkdownTextRuleConfiguration(id: UUID(), rule: rule),
        ]
        MarkdownPresentation.refresh(textView, mode: .livePreview)
        try await settle(textView)
        let presentation = try XCTUnwrap(textView.markdownSyntaxCache.currentPresentation)
        XCTAssertTrue(presentation.previewRanges.collapsed.contains(NSRange(location: 11, length: 4)))
    }
}

@MainActor
final class MarkdownTextRuleReviewTests: XCTestCase {
    func testChoicesKeepTheirWrittenOrderEvenForNumbers() throws {
        let rule = try TextRuleHarness.compile("""
            rule({ name: "x", options: { "20": { title: "Size", type: "choice",
              choices: { "20": "Twenty", "10": "Ten" }, default: "10" },
              "5": { title: "Five", type: "toggle", default: true } }, block() {} });
            """)
        XCTAssertEqual(rule.manifest.options.map(\.key), ["20", "5"])
        XCTAssertEqual(rule.manifest.options[0].kind,
                       .choice([.init(value: "20", title: "Twenty"), .init(value: "10", title: "Ten")]))
    }

    func testStrictModeStillAppliesInFunctions() throws {
        let rule = try TextRuleHarness.compile(TextRuleHarness.script("""
            function strict() { "use strict"; return this === undefined; }
            return { decorations: [{ kind: "insert", at: 0, text: String(strict()) }] };
            """))
        XCTAssertEqual(TextRuleHarness.run(rule, on: "Text").decorations.first?.kind,
                       .insert(text: "true", side: .after, style: .muted))
    }

    func testEndlessTopLevelCodeStops() throws {
        let rule = try TextRuleHarness.compile("while (true) {} rule({ name: 'x', block() {} });")
        XCTAssertNotNil(TextRuleHarness.run(rule, on: "Text").response.error)
    }

    func testEachBlockKeepsTheDecorationsItReturned() throws {
        let rule = try TextRuleHarness.compile(TextRuleHarness.script("""
            shared.length = 0;
            shared.push({ kind: "insert", at: 0, text: block.text });
            return { decorations: shared };
            """).replacingOccurrences(of: "rule({", with: "const shared = []; rule({"))
        let texts = TextRuleHarness.run(rule, on: "One\n\nTwo").decorations.compactMap {
            if case .insert(let text, _, _) = $0.kind { return text } else { return nil }
        }
        XCTAssertEqual(texts, ["One", "Two"])
    }

    func testAPerBlockStateMayNotGrowTooLarge() throws {
        let rule = try TextRuleHarness.compile("""
            rule({ name: "x", start: "", block(block, state) {
              return { state: block.text === "Big" ? "x".repeat(20000) : "" }; } });
            """)
        XCTAssertEqual(TextRuleHarness.run(rule, on: "Big\n\nSmall").response.error?.message,
                       "The rule’s state is too large.")
    }

    func testLinkPrefixesWithPortsOrQueries() throws {
        let port = try XCTUnwrap(MarkdownTextRuleLinkPrefix("https://example.com:8080"))
        XCTAssertTrue(port.allows("https://example.com:8080/a"))
        XCTAssertFalse(port.allows("https://example.com:80801/a"))
        XCTAssertNil(MarkdownTextRuleLinkPrefix("https://example.com:8080@evil.test/"))
        XCTAssertNil(MarkdownTextRuleLinkPrefix("https://user@example.com/"))
        let query = try XCTUnwrap(MarkdownTextRuleLinkPrefix("https://example.com?ticket="))
        XCTAssertTrue(query.allows("https://example.com?ticket=1"))
        XCTAssertFalse(query.allows("https://example.com.evil.test?ticket=1"))
        XCTAssertNotNil(try? MarkdownTextRuleCompiler.compile(MarkdownTextRuleLibrary.linkScript(
            for: NotebookTextLinkRule(name: "T", find: "T-1", isRegularExpression: false,
                                      url: "https://example.com?ticket=$0"))).get())
    }

    func testLinesEndWhereTheNoteSaysEvenInsideCode() {
        let text = "One `a\rb` Two"
        let block = MarkdownTextRuleBlocks.blocks(
            in: text, result: MarkdownSyntax.parse(text), input: .plain).first
        XCTAssertEqual(block?.lines.count, 2)
    }

    func testAMultibyteStateCountsItsBytes() throws {
        let rule = try TextRuleHarness.compile("""
            rule({ name: "x", start: "", block(block, state) {
              return { state: block.text === "Big" ? "é".repeat(8192) : "" }; } });
            """)
        XCTAssertEqual(TextRuleHarness.run(rule, on: "Big\n\nSmall").response.error?.message,
                       "The rule’s state is too large.")
    }

    func testLinesEndAtCarriageReturnsToo() {
        let text = "One\r\nTwo\rThree"
        let block = MarkdownTextRuleBlocks.blocks(
            in: text, result: MarkdownSyntax.parse(text), input: .plain).first
        XCTAssertEqual(block?.lines.map(\.text), ["One", "Two", "Three"])
        XCTAssertEqual(block?.lines.map(\.start), [0, 5, 9])
    }

    func testHeadingsOverSeveralLinesStayOneBlock() {
        let text = "Release\nNotes\n=====\n\nBody"
        let blocks = MarkdownTextRuleBlocks.blocks(
            in: text, result: MarkdownSyntax.parse(text), input: .plain)
        XCTAssertEqual(blocks.map(\.kind), [.heading, .paragraph])
        XCTAssertEqual(blocks.first?.lines.map(\.text), ["Release", "Notes"])
    }

    func testUnicodeLineSeparatorsEndParagraphs() {
        let text = "One\u{2028}\u{2028}Two"
        let blocks = MarkdownTextRuleBlocks.blocks(
            in: text, result: MarkdownSyntax.parse(text), input: .plain)
        XCTAssertEqual(blocks.count, 2)
    }

    func testLinkPathsMatchCase() throws {
        let prefix = try XCTUnwrap(MarkdownTextRuleLinkPrefix("https://Tracker.example.com/Tickets/"))
        XCTAssertTrue(prefix.allows("https://tracker.EXAMPLE.com/Tickets/1"))
        XCTAssertFalse(prefix.allows("https://tracker.example.com/tickets/1"))
    }

    func testSimpleLinkRulesLinkToAFixedSite() throws {
        let rule = try TextRuleHarness.compile(MarkdownTextRuleLibrary.linkScript(for: NotebookTextLinkRule(
            name: "Home", find: "Home*\u{301}", isRegularExpression: false, url: "https://example.com")))
        let run = TextRuleHarness.run(rule, on: "Go Home*\u{301} now")
        XCTAssertNil(run.response.error)
        XCTAssertEqual(run.decorations.map(\.kind), [.link(url: "https://example.com/")])
    }

    func testAnOptionCantRenameItself() {
        guard case .failure = MarkdownTextRuleCompiler.compile("""
            rule({ name: "x", options: { mode: { title: "Mode", type: "toggle", key: "other" } },
              block() {} });
            """) else { return XCTFail("An option body's key must be refused") }
    }

    func testStoredOptionsThatNoLongerFitUseTheDefault() throws {
        let rule = try TextRuleHarness.compile("""
            rule({ name: "x", options: { open: { title: "Open", type: "toggle", default: true } },
              block() {} });
            """)
        let option = try XCTUnwrap(rule.manifest.options.first)
        XCTAssertEqual(option.value(in: ["open": .text("web")]), .toggle(true))
        XCTAssertEqual(option.value(in: ["open": .toggle(false)]), .toggle(false))
    }

    func testAThrowingResultKeepsEarlierBlocks() throws {
        let rule = try TextRuleHarness.compile(TextRuleHarness.script("""
            if (block.text === "Two") return { get decorations() { throw new Error("no"); } };
            return { decorations: [{ kind: "style", start: 0, end: 3, style: "muted" }] };
            """))
        let run = TextRuleHarness.run(rule, on: "One\n\nTwo")
        XCTAssertEqual(run.response.results.count, 1)
        XCTAssertEqual(run.response.error?.message, "no")
    }

    func testAnExampleMustBeText() {
        guard case .failure = MarkdownTextRuleCompiler.compile(
            #"rule({ name: "x", example: 42, block() {} });"#
        ) else { return XCTFail("A non-text example must be refused") }
    }

    func testARuleCanStartInChosenNotes() throws {
        let chosen = try TextRuleHarness.compile(#"rule({ name: "x", runsIn: "chosenNotes", block() {} });"#)
        XCTAssertTrue(chosen.manifest.startsInChosenNotes)
        let all = try TextRuleHarness.compile(#"rule({ name: "x", block() {} });"#)
        XCTAssertFalse(all.manifest.startsInChosenNotes)
        guard case .failure = MarkdownTextRuleCompiler.compile(
            #"rule({ name: "x", runsIn: "folder", block() {} });"#
        ) else { return XCTFail("An unknown runsIn must be refused") }
    }

    func testStateKeepsItsKeyOrder() throws {
        let rule = try TextRuleHarness.compile("""
            rule({ name: "x", start: { b: 1, a: 2 }, block(block, state) {
              return { decorations: [{ kind: "insert", at: 0, text: Object.keys(state).join() }],
                       state };
            } });
            """)
        let run = TextRuleHarness.run(rule, on: "One")
        XCTAssertEqual(run.decorations.map(\.kind), [.insert(text: "b,a", side: .after, style: .muted)])
    }

    func testLinksCantStepOutOfTheirPath() throws {
        let prefix = try XCTUnwrap(MarkdownTextRuleLinkPrefix("https://example.com/Tickets/"))
        XCTAssertTrue(prefix.allows("https://example.com/Tickets/1?q=..#.."))
        for url in ["https://example.com/Tickets/../admin", "https://example.com/Tickets/%2e%2E/admin",
                    "https://example.com/Tickets/..\\admin", "https://example.com/Tickets/./1"] {
            XCTAssertFalse(prefix.allows(url), url)
        }
    }

    func testLinesEndAtUnicodeLineSeparators() {
        let text = "1h\u{2028}=\u{2028}2h"
        let block = MarkdownTextRuleBlocks.blocks(
            in: text, result: MarkdownSyntax.parse(text), input: .plain).first
        XCTAssertEqual(block?.lines.map(\.text), ["1h", "=", "2h"])
    }
}
