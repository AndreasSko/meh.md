import Foundation
import JavaScriptCore
import NoteCore

/// What a rule asks the editor to show. Ranges are UTF-16, relative to the
/// block until the session moves them into the note.
nonisolated struct MarkdownTextRuleDecoration: Sendable, Hashable {
    enum Style: String, Sendable, CaseIterable {
        case muted, accent, highlight, warning, error, success
        case strong, emphasis, strike, code
    }

    enum Side: String, Sendable {
        case before, after
    }

    enum Kind: Sendable, Hashable {
        case link(url: String)
        case style(Style)
        /// Text drawn at `range.location`, which is not part of the note.
        case insert(text: String, side: Side, style: Style)
        /// Hidden until the caret is in its paragraph, like `**` markers.
        case hide
    }

    var range: NSRange
    var kind: Kind
    var label: String?

    func moved(by offset: Int) -> Self {
        var copy = self
        copy.range.location += offset
        return copy
    }
}

nonisolated struct MarkdownTextRuleBlockResult: Sendable, Equatable {
    var decorations: [MarkdownTextRuleDecoration]
    /// The state after the block, as JSON, for rules that carry state.
    var state: String?
    /// Why decorations of this block were left out.
    var problems: [String] = []
}

/// One rule's JavaScriptCore context. Calls run one at a time on its own
/// queue, so a rule that never returns blocks only itself.
nonisolated final class MarkdownTextRuleRuntime: @unchecked Sendable {
    struct Request: Sendable {
        var blocks: [MarkdownTextRuleBlock]
        /// For each block, the incoming states it already has results for.
        var known: [[String]]
        var state: String?
        var context: String
        /// Generous, so a slow device or a pause for memory cleanup doesn't
        /// stop a rule that is fine.
        var blockBudget: Double = 250
        var batchBudget: Double = 400
    }

    struct Response: Sendable {
        var results: [MarkdownTextRuleBlockResult] = []
        /// The batch ran out of time; the rest of the blocks still wait.
        var more = false
        var error: MarkdownTextRuleError?
        /// The rule ran past its time on one block.
        var isSlow = false
        /// Decorations left out because they were invalid.
        var problems: [String] = []
        /// Blocks the script ran for; others had no trigger match.
        var scriptRuns = 0
    }

    let rule: MarkdownCompiledTextRule
    let queue: DispatchQueue
    private let trigger: NSRegularExpression?
    private var context: JSContext?
    private var loadError: MarkdownTextRuleError?
    private var isLoaded = false

    private static let lock = NSLock()
    nonisolated(unsafe) private static var runtimes: [String: MarkdownTextRuleRuntime] = [:]

    /// Rules are pure, so editors showing the same rule share one context.
    static func shared(for rule: MarkdownCompiledTextRule) -> MarkdownTextRuleRuntime {
        lock.lock()
        defer { lock.unlock() }
        if let runtime = runtimes[rule.identity] { return runtime }
        let runtime = MarkdownTextRuleRuntime(rule: rule)
        runtimes[rule.identity] = runtime
        return runtime
    }

    /// Forgets a runtime stuck in a call that never returns, so the rule
    /// gets a fresh context and queue when it is turned on again.
    static func evict(_ runtime: MarkdownTextRuleRuntime) {
        lock.lock()
        if runtimes[runtime.rule.identity] === runtime {
            runtimes[runtime.rule.identity] = nil
        }
        lock.unlock()
        // Work other editors queued behind the stuck call would never start.
        NotificationCenter.default.post(name: evicted, object: runtime)
    }

    static let evicted = Notification.Name("MarkdownTextRuleRuntimeEvicted")

    /// Whether one call returned, read by the watchdog on the main queue.
    final class Call: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false

        var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return finished
        }

        func finish() {
            lock.lock()
            finished = true
            lock.unlock()
        }
    }

    init(rule: MarkdownCompiledTextRule) {
        self.rule = rule
        trigger = rule.manifest.trigger.flatMap { try? NSRegularExpression(pattern: $0) }
        queue = DispatchQueue(label: "md.meh.text-rules.\(rule.identity)", qos: .utility)
    }

    private func load() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let context = JSContext(),
              let runtime = MarkdownTextRuleLibrary.resource("TextRuleRuntime") else {
            loadError = MarkdownTextRuleError(message: String(localized: "The rule couldn’t start."))
            return
        }
        var thrown: MarkdownTextRuleError?
        context.exceptionHandler = { _, exception in
            thrown = MarkdownTextRuleError(
                message: exception?.toString() ?? "",
                line: exception?.objectForKeyedSubscript("line")?.toNumber()?.intValue)
        }
        // Processor time of the calling thread, so a busy device doesn't
        // count against the rule. Each call reads it on one thread.
        let now: @convention(block) () -> Double = {
            Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000
        }
        let host = JSValue(newObjectIn: context)
        host?.setObject(now, forKeyedSubscript: "now" as NSString)
        context.setObject(host, forKeyedSubscript: "__meh_host" as NSString)
        context.evaluateScript(runtime)
        if thrown == nil { context.evaluateScript(rule.protectedSource) }
        if thrown == nil {
            context.objectForKeyedSubscript("__meh_seal")?.call(withArguments: [])
        }
        if let thrown {
            loadError = thrown
            return
        }
        context.exceptionHandler = { _, _ in }
        self.context = context
    }

    /// Runs the blocks. Call it on `queue`.
    func run(_ request: Request) -> Response {
        dispatchPrecondition(condition: .onQueue(queue))
        // Blocks without the trigger get an empty result without running
        // the script. Only rules without state have a trigger.
        if let trigger {
            let matches = request.blocks.map {
                trigger.firstMatch(in: $0.text, range: NSRange(
                    location: 0, length: ($0.text as NSString).length)) != nil
            }
            if matches.contains(false) {
                var filtered = request
                filtered.blocks = zip(request.blocks, matches).filter(\.1).map(\.0)
                filtered.known = zip(request.known, matches).filter(\.1).map(\.0)
                var ran = filtered.blocks.isEmpty ? Response() : runMatching(filtered)
                var merged: [MarkdownTextRuleBlockResult] = []
                var next = ran.results.makeIterator()
                for matched in matches {
                    if matched {
                        guard let result = next.next() else { break }
                        merged.append(result)
                    } else {
                        merged.append(MarkdownTextRuleBlockResult(decorations: []))
                    }
                }
                ran.results = merged
                return ran
            }
        }
        return runMatching(request)
    }

    private func runMatching(_ request: Request) -> Response {
        load()
        var response = Response()
        if let loadError {
            response.error = loadError
            return response
        }
        let payload: [String: Any] = [
            "blocks": zip(request.blocks, request.known).map { block, known in
                [
                    "block": [
                        "text": block.text,
                        "kind": block.kind.rawValue,
                        "level": block.level,
                        "lines": block.lines.map { ["start": $0.start, "text": $0.text] },
                    ] as [String: Any],
                    "known": known,
                ] as [String: Any]
            },
            // As written: decoding and encoding again could reorder its keys,
            // and the script would see another state than the cache recorded.
            "state": request.state ?? NSNull(),
            "context": Self.jsonObject(request.context) ?? [:],
            "stateful": rule.manifest.isStateful,
            "blockBudget": request.blockBudget,
            "batchBudget": request.batchBudget,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8),
              let output = context?.objectForKeyedSubscript("__meh_run")?
                .call(withArguments: [json])?.toString(),
              let object = Self.jsonObject(output) as? [String: Any] else {
            response.error = MarkdownTextRuleError(message: String(localized: "The rule couldn’t run."))
            return response
        }
        let results = object["results"] as? [[String: Any]] ?? []
        for (index, result) in results.enumerated() where index < request.blocks.count {
            let raw = (result["decorations"] as? String).flatMap(Self.jsonObject)
            let (decorations, problems) = Self.validate(
                raw, in: request.blocks[index], manifest: rule.manifest)
            response.problems += problems
            response.results.append(MarkdownTextRuleBlockResult(
                decorations: decorations, state: result["state"] as? String, problems: problems))
        }
        if let state = response.results.last?.state, state.utf8.count > 16_384 {
            response.results.removeAll()
            response.error = MarkdownTextRuleError(
                message: String(localized: "The rule’s state is too large."))
        }
        response.scriptRuns = response.results.count
        response.more = object["more"] as? Bool ?? false
        if let error = object["error"] as? [String: Any] {
            response.isSlow = error["slow"] as? Bool ?? false
            response.error = MarkdownTextRuleError(
                message: error["message"] as? String ?? "",
                line: error["line"] as? Int)
        }
        return response
    }

    private static func jsonObject(_ json: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
    }

    // MARK: - Checking decorations

    static let maximumDecorations = 1_000

    /// The decorations that are safe to show, and why the others aren't.
    static func validate(
        _ value: Any?, in block: MarkdownTextRuleBlock, manifest: MarkdownTextRuleManifest
    ) -> ([MarkdownTextRuleDecoration], [String]) {
        guard let list = value as? [Any] else {
            return ([], value == nil ? [] : ["decorations must be a list."])
        }
        let source = block.original as NSString
        let length = source.length
        func isBoundary(_ offset: Int) -> Bool {
            offset == 0 || offset == length
                || source.rangeOfComposedCharacterSequence(at: offset).location == offset
        }
        var result: [MarkdownTextRuleDecoration] = []
        var problems: [String] = []
        for item in list.prefix(maximumDecorations) {
            guard let object = item as? [String: Any], let kind = object["kind"] as? String else {
                problems.append("Each decoration needs a kind.")
                continue
            }
            let label = (object["label"] as? String).map { String($0.prefix(200)) }
            func range() -> NSRange? {
                guard let start = object["start"] as? Int, let end = object["end"] as? Int,
                      start >= 0, end > start, end <= length else {
                    problems.append("A \(kind) needs a start before its end, inside the block.")
                    return nil
                }
                guard isBoundary(start), isBoundary(end) else {
                    problems.append("A \(kind) can’t split a character.")
                    return nil
                }
                let range = NSRange(location: start, length: end - start)
                // Code and existing links stay as they are; that's expected,
                // not a mistake in the rule.
                guard !block.protected.contains(where: {
                    NSIntersectionRange($0, range).length > 0
                }) else { return nil }
                return range
            }
            func style(_ key: String, default fallback: MarkdownTextRuleDecoration.Style?)
                -> MarkdownTextRuleDecoration.Style? {
                guard let name = object[key] as? String else {
                    if fallback == nil { problems.append("A \(kind) needs a style.") }
                    return fallback
                }
                guard let style = MarkdownTextRuleDecoration.Style(rawValue: name) else {
                    problems.append("“\(name)” is not a style.")
                    return nil
                }
                return style
            }
            switch kind {
            case "link":
                guard let range = range() else { continue }
                guard let url = object["url"] as? String, url.utf16.count <= 2_048,
                      URL(string: url) != nil else {
                    problems.append("A link needs a url.")
                    continue
                }
                guard manifest.linksTo.contains(where: { $0.allows(url) }) else {
                    problems.append("\(url) isn’t in linksTo.")
                    continue
                }
                result.append(.init(range: range, kind: .link(url: url), label: label))
            case "style":
                guard let range = range(), let style = style("style", default: nil) else { continue }
                result.append(.init(range: range, kind: .style(style), label: label))
            case "insert":
                guard let at = object["at"] as? Int, at >= 0, at <= length, isBoundary(at) else {
                    problems.append("An insert needs an at inside the block.")
                    continue
                }
                guard let text = object["text"] as? String, !text.isEmpty, text.count <= 100,
                      !text.contains(where: \.isNewline) else {
                    problems.append("An insert needs a short text on one line.")
                    continue
                }
                let side: MarkdownTextRuleDecoration.Side
                switch object["side"] as? String {
                case nil, "after": side = .after
                case "before": side = .before
                default:
                    problems.append("side must be \"before\" or \"after\".")
                    continue
                }
                guard let style = style("style", default: .muted) else { continue }
                result.append(.init(range: NSRange(location: at, length: 0),
                                    kind: .insert(text: text, side: side, style: style),
                                    label: label))
            case "hide":
                guard let range = range() else { continue }
                result.append(.init(range: range, kind: .hide, label: label))
            default:
                problems.append("“\(kind)” is not a decoration kind.")
            }
        }
        if list.count > maximumDecorations {
            problems.append("Only the first \(maximumDecorations) decorations of a block are shown.")
        }
        return (result, problems)
    }
}
