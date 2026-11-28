import Foundation
import NoteCore

/// One rule as an editor runs it: compiled, with its option values.
nonisolated struct MarkdownTextRuleConfiguration: Sendable, Equatable {
    let id: UUID
    let rule: MarkdownCompiledTextRule
    /// Stored values; options without one use their default.
    let options: [String: NotebookTextRule.OptionValue]

    init(id: UUID, rule: MarkdownCompiledTextRule,
         options: [String: NotebookTextRule.OptionValue] = [:]) {
        self.id = id
        self.rule = rule
        self.options = options
    }
}

/// Everything the active rules show in a note, in the note's UTF-16
/// offsets, already sorted and with overlaps between rules resolved.
nonisolated struct MarkdownTextRuleDecorations: Sendable, Equatable {
    struct Link: Sendable, Hashable {
        let range: NSRange
        let url: String
        let label: String?
    }

    struct Style: Sendable, Hashable {
        let range: NSRange
        let style: MarkdownTextRuleDecoration.Style
    }

    struct Insert: Sendable, Hashable {
        let location: Int
        let text: String
        let side: MarkdownTextRuleDecoration.Side
        let style: MarkdownTextRuleDecoration.Style
        let label: String?
    }

    var links: [Link] = []
    /// Later styles are drawn over earlier ones: the rule higher in the
    /// list comes last.
    var styles: [Style] = []
    var inserts: [Insert] = []
    var hides: [NSRange] = []

    static let empty = Self()
    var isEmpty: Bool { links.isEmpty && styles.isEmpty && inserts.isEmpty && hides.isEmpty }

    /// `rules` from the highest in the list to the lowest.
    init(rules: [[MarkdownTextRuleDecoration]] = []) {
        var links: [Link] = []
        for decorations in rules {
            for decoration in decorations {
                switch decoration.kind {
                case .link(let url):
                    // One link per text: the higher rule keeps it.
                    guard !links.contains(where: {
                        NSIntersectionRange($0.range, decoration.range).length > 0
                    }) else { continue }
                    links.append(Link(range: decoration.range, url: url, label: decoration.label))
                case .insert(let text, let side, let style):
                    inserts.append(Insert(location: decoration.range.location, text: text,
                                          side: side, style: style, label: decoration.label))
                case .hide:
                    hides.append(decoration.range)
                case .style:
                    break
                }
            }
        }
        for decorations in rules.reversed() {
            for decoration in decorations {
                if case .style(let style) = decoration.kind {
                    styles.append(Style(range: decoration.range, style: style))
                }
            }
        }
        self.links = links.sorted { $0.range.location < $1.range.location }
        self.inserts = inserts.enumerated().sorted {
            ($0.element.location, $0.offset) < ($1.element.location, $1.offset)
        }.map(\.element)
        // Kept apart: the edited paragraph shows its own hidden text again,
        // even where a hide reaches over into the next paragraph.
        self.hides = Array(Set(hides)).sorted { ($0.location, $0.length) < ($1.location, $1.length) }
    }

    func link(at offset: Int) -> Link? {
        links.first { NSLocationInRange(offset, $0.range) }
    }

    /// Where two sets of decorations differ, to redo the layout only there.
    func changedRanges(from other: Self) -> [NSRange] {
        var ranges: [NSRange] = []
        func compare<T: Hashable>(_ left: [T], _ right: [T], _ range: (T) -> NSRange) {
            for item in Set(left).symmetricDifference(Set(right)) { ranges.append(range(item)) }
        }
        compare(links, other.links, \.range)
        compare(styles, other.styles, \.range)
        // Styles both have, in another order, paint differently where they
        // overlap, even when other styles came or went at the same time.
        let common = Set(styles).intersection(other.styles)
        let kept = styles.filter(common.contains)
        if kept != other.styles.filter(common.contains) {
            ranges += kept.map(\.range)
        }
        compare(inserts, other.inserts) { NSRange(location: $0.location, length: 0) }
        compare(hides, other.hides) { $0 }
        return ranges
    }
}

/// Runs an editor's text rules and keeps their results. Each block's result
/// is kept by its text (and incoming state, for rules that carry one), so
/// an edit only runs the blocks it changed. Scripts run on their own
/// queues; results arrive later and replace what the editor shows.
@MainActor final class MarkdownTextRuleSession {
    /// Called when `decorations` changed.
    var onChange: (() -> Void)?
    private(set) var decorations = MarkdownTextRuleDecorations.empty
    /// The latest problem of each rule, shown in its settings.
    private(set) var problems: [UUID: MarkdownTextRuleError] = [:] {
        didSet {
            guard problems != oldValue else { return }
            // Problems change while SwiftUI updates the editor, so whoever
            // shows them hears about it right after.
            let problems = problems
            DispatchQueue.main.async { [weak self] in self?.onProblemsChange?(problems) }
        }
    }
    /// Called when `problems` changed.
    var onProblemsChange: (([UUID: MarkdownTextRuleError]) -> Void)?

    var configurations: [MarkdownTextRuleConfiguration] = [] {
        didSet {
            guard configurations != oldValue else { return }
            let previous = rules
            rules = configurations.map { configuration in
                if let kept = previous.first(where: { $0.configuration == configuration }) {
                    return kept
                }
                let rule = RuleState(configuration: configuration)
                if MarkdownTextRuleHealth.isStuck(configuration.rule.identity) {
                    rule.failed = true
                    problems[configuration.id] = MarkdownTextRuleError(message: String(
                        localized: "The rule stopped responding. Turn it on again to retry."))
                }
                return rule
            }
            problems = problems.filter { id, _ in configurations.contains { $0.id == id } }
            evaluateAll()
        }
    }

    var noteTitle = "" {
        didSet {
            guard noteTitle != oldValue else { return }
            for rule in rules where rule.manifest.uses.contains(.title) { rule.reset() }
            evaluateAll()
        }
    }

    /// Off outside Live Preview: Source mode shows the text as written.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            evaluateAll()
        }
    }

    private final class RuleState {
        let configuration: MarkdownTextRuleConfiguration
        var runtime: MarkdownTextRuleRuntime
        var manifest: MarkdownTextRuleManifest { configuration.rule.manifest }
        struct CacheKey: Hashable {
            let block: MarkdownTextRuleBlock.Key
            /// The incoming state, for rules that carry one.
            let incoming: State?
        }

        /// A state as the rule returned it. Swift compares strings by
        /// canonical equivalence, but a script sees `é` and `e` + U+0301
        /// as different text, so states compare by their exact bytes.
        struct State: Hashable {
            let json: String
            private let bytes: Data

            init(_ json: String) {
                self.json = json
                bytes = Data(json.utf8)
            }

            static func == (lhs: Self, rhs: Self) -> Bool { lhs.bytes == rhs.bytes }
            func hash(into hasher: inout Hasher) { hasher.combine(bytes) }
        }

        /// Results by block, plus the incoming state for rules with one.
        var cache: [CacheKey: MarkdownTextRuleBlockResult] = [:]
        /// Incoming states each block has results for.
        var known: [MarkdownTextRuleBlock.Key: Set<State>] = [:]
        /// The latest result of each block, shown below an edit until the
        /// real result arrives.
        var latest: [MarkdownTextRuleBlock.Key: MarkdownTextRuleBlockResult] = [:]
        /// Counts resets, so a result computed for an older title or day
        /// isn't kept.
        var generation = 0
        var shown: [MarkdownTextRuleDecoration] = []
        var running: UUID?
        var needsRun = false
        var failed = false
        var today = ""

        init(configuration: MarkdownTextRuleConfiguration) {
            self.configuration = configuration
            runtime = MarkdownTextRuleRuntime.shared(for: configuration.rule)
        }

        func reset() {
            generation += 1
            cache.removeAll()
            known.removeAll()
            latest.removeAll()
        }
    }

    private var rules: [RuleState] = []
    private var evictionObserver: NSObjectProtocol?

    init() {
        evictionObserver = NotificationCenter.default.addObserver(
            forName: MarkdownTextRuleRuntime.evicted, object: nil, queue: .main
        ) { [weak self] notification in
            guard let runtime = notification.object as? MarkdownTextRuleRuntime else { return }
            MainActor.assumeIsolated { self?.moveOff(runtime) }
        }
    }

    isolated deinit {
        if let evictionObserver { NotificationCenter.default.removeObserver(evictionObserver) }
    }

    /// Rules still waiting on a runtime that was given up on start again on
    /// a fresh one. Only the rule whose own call got stuck counts as stuck.
    private func moveOff(_ runtime: MarkdownTextRuleRuntime) {
        for rule in rules where rule.runtime === runtime && !rule.failed {
            rule.runtime = MarkdownTextRuleRuntime.shared(for: rule.configuration.rule)
            rule.running = nil
            evaluate(rule)
        }
        publish()
    }
    private var text = ""
    private var result: MarkdownSyntaxResult?
    private var revision: UInt64?
    private var blocks: [MarkdownTextRuleManifest.Input: [MarkdownTextRuleBlock]] = [:]
    /// How long a rule may take before it counts as stopped.
    var responseLimit: TimeInterval = 5
    /// Blocks scripts ran so far, for tests.
    private(set) var blocksRun = 0
    /// A rule is still working on the latest text.
    var isRunning: Bool { rules.contains { $0.running != nil } }

    /// Reads a new version of the note. Call it after each parse.
    func update(text: String, result: MarkdownSyntaxResult, revision: UInt64) {
        guard revision != self.revision else { return }
        self.revision = revision
        self.text = text
        self.result = result
        blocks.removeAll()
        evaluateAll()
    }

    private func evaluateAll() {
        for rule in rules { evaluate(rule) }
        publish()
    }

    private func blocks(for input: MarkdownTextRuleManifest.Input) -> [MarkdownTextRuleBlock] {
        if let cached = blocks[input] { return cached }
        guard let result else { return [] }
        let made = MarkdownTextRuleBlocks.blocks(in: text, result: result, input: input)
        blocks[input] = made
        return made
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func context(for rule: RuleState) -> String {
        let manifest = rule.manifest
        var options: [String: Any] = [:]
        for option in manifest.options {
            switch option.value(in: rule.configuration.options) {
            case .text(let value): options[option.key] = value
            case .toggle(let value): options[option.key] = value
            }
        }
        var context: [String: Any] = ["options": options]
        if manifest.uses.contains(.today) { context["today"] = rule.today }
        if manifest.uses.contains(.locale) {
            context["locale"] = Locale.current.identifier(.bcp47)
        }
        if manifest.uses.contains(.title) { context["note"] = ["title": noteTitle] }
        let data = (try? JSONSerialization.data(withJSONObject: context, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private func evaluate(_ rule: RuleState) {
        guard isActive, !rule.failed, result != nil else {
            rule.shown = []
            return
        }
        if rule.manifest.uses.contains(.today) {
            let today = Self.dayFormatter.string(from: Date())
            if today != rule.today {
                rule.today = today
                rule.reset()
            }
        }
        let blocks = blocks(for: rule.manifest.input).filter {
            rule.manifest.blocks.contains($0.kind)
        }
        var shown: [MarkdownTextRuleDecoration] = []
        var warning: String?
        func show(_ result: MarkdownTextRuleBlockResult, in block: MarkdownTextRuleBlock) {
            shown += result.decorations.map { $0.moved(by: block.range.location) }
            warning = warning ?? result.problems.first
        }
        var missing: [Int] = []
        var startState: String?
        if let start = rule.manifest.start {
            var incoming = RuleState.State(start)
            var index = 0
            var chain: Set<RuleState.CacheKey> = []
            while index < blocks.count {
                let block = blocks[index]
                let key = RuleState.CacheKey(block: block.key, incoming: incoming)
                guard let cached = rule.cache[key] else { break }
                chain.insert(key)
                show(cached, in: block)
                incoming = cached.state.map(RuleState.State.init) ?? incoming
                index += 1
            }
            if index < blocks.count {
                startState = incoming.json
                missing = Array(index..<blocks.count)
                // The edited block shows nothing until its result arrives;
                // the blocks after it keep their last result meanwhile.
                for block in blocks[(index + 1)...] {
                    if let latest = rule.latest[block.key] { show(latest, in: block) }
                }
            } else {
                prune(rule, keeping: blocks, chain: chain)
            }
        } else {
            // The runtime checks the trigger on the rule's queue, so a slow
            // pattern can't hold up typing.
            for (index, block) in blocks.enumerated() {
                if let cached = rule.cache[.init(block: block.key, incoming: nil)] {
                    show(cached, in: block)
                } else {
                    missing.append(index)
                }
            }
            if missing.isEmpty { prune(rule, keeping: blocks) }
        }
        rule.shown = shown
        guard !missing.isEmpty else {
            // Every block has its result: say what the note's blocks left out.
            problems[rule.configuration.id] = warning.map { MarkdownTextRuleError(message: $0) }
            return
        }
        guard rule.running == nil else {
            rule.needsRun = true
            return
        }
        let request = MarkdownTextRuleRuntime.Request(
            blocks: missing.map { blocks[$0] },
            known: missing.map { (rule.known[blocks[$0].key] ?? []).map(\.json) },
            state: startState,
            context: context(for: rule))
        run(request, for: rule)
    }

    private func prune(
        _ rule: RuleState, keeping blocks: [MarkdownTextRuleBlock],
        chain: Set<RuleState.CacheKey>? = nil
    ) {
        // Only what the note still needs, so the cache can't grow without end.
        // For a rule with state, that's the results on the current chain.
        guard rule.cache.count > blocks.count * 2 + 16 else { return }
        let keys = Set(blocks.map(\.key))
        rule.cache = rule.cache.filter {
            chain?.contains($0.key) ?? keys.contains($0.key.block)
        }
        if chain != nil {
            rule.known = Dictionary(grouping: rule.cache.keys, by: \.block).mapValues {
                Set($0.compactMap(\.incoming))
            }
        }
        rule.latest = rule.latest.filter { keys.contains($0.key) }
        rule.known = rule.known.filter { keys.contains($0.key) }
    }

    private func run(_ request: MarkdownTextRuleRuntime.Request, for rule: RuleState) {
        let token = UUID()
        let generation = rule.generation
        let revision = revision
        rule.running = token
        rule.needsRun = false
        let runtime = rule.runtime
        let limit = responseLimit
        let call = MarkdownTextRuleRuntime.Call()
        runtime.queue.async { [weak self] in
            // The time limit starts when the rule starts, not while it waits
            // behind another editor's work on the same queue. A stuck call
            // retires its runtime even if this editor closed meanwhile, so
            // other editors waiting on it can move on.
            DispatchQueue.main.asyncAfter(deadline: .now() + limit) {
                guard !call.isFinished else { return }
                // Mark the rule first, so the eviction doesn't restart it.
                self?.timeOut(rule, token: token)
                MarkdownTextRuleRuntime.evict(runtime)
            }
            let response = runtime.run(request)
            call.finish()
            DispatchQueue.main.async {
                self?.finish(response, of: request, for: rule, token: token,
                             generation: generation, revision: revision)
            }
        }
    }

    /// The script is stuck in code that can't be interrupted, like a
    /// regular expression that never ends. Its runtime is retired next;
    /// turning the rule on again starts a new one.
    private func timeOut(_ rule: RuleState, token: UUID) {
        guard rule.running == token else { return }
        rule.running = nil
        rule.failed = true
        // A rule replaced meanwhile, such as with other options, is no
        // longer shown; only the current one can be marked as stuck.
        guard rules.contains(where: { $0 === rule }) else { return }
        MarkdownTextRuleHealth.markStuck(rule.configuration.rule.identity)
        problems[rule.configuration.id] = MarkdownTextRuleError(
            message: String(localized: "The rule stopped responding."))
        rule.shown = []
        publish()
    }

    private func finish(
        _ response: MarkdownTextRuleRuntime.Response,
        of request: MarkdownTextRuleRuntime.Request,
        for rule: RuleState, token: UUID, generation: Int, revision: UInt64?
    ) {
        guard rule.running == token, rules.contains(where: { $0 === rule }) else { return }
        rule.running = nil
        // The title or the day changed while the rule ran: run it again.
        guard rule.generation == generation else {
            evaluate(rule)
            publish()
            return
        }
        blocksRun += response.scriptRuns
        var incoming = request.state
        for (block, result) in zip(request.blocks, response.results) {
            let stateful = rule.manifest.isStateful
            rule.cache[.init(block: block.key,
                             incoming: stateful ? RuleState.State(incoming ?? "null") : nil)] = result
            rule.latest[block.key] = result
            if let state = incoming, stateful {
                rule.known[block.key, default: []].insert(RuleState.State(state))
            }
            incoming = result.state
        }
        if let error = response.error {
            // The text changed meanwhile, perhaps fixing what failed: try
            // the current text before giving up on the rule.
            guard revision == self.revision else {
                evaluate(rule)
                publish()
                return
            }
            rule.failed = true
            problems[rule.configuration.id] = error
            rule.shown = []
            publish()
            return
        }
        evaluate(rule)
        publish()
    }

    private func publish() {
        let next = MarkdownTextRuleDecorations(rules: rules.map(\.shown))
        guard next != decorations else { return }
        decorations = next
        onChange?()
    }
}

/// Remembers rules that stopped responding, so they stay off after the app
/// restarts until someone edits or turns them on again.
nonisolated enum MarkdownTextRuleHealth {
    private static let key = "labs.textRules.stuck"

    nonisolated static func isStuck(_ identity: String) -> Bool {
        (NotebookEditorPreferences.store.stringArray(forKey: key) ?? []).contains(identity)
    }

    nonisolated static func markStuck(_ identity: String) {
        var stuck = NotebookEditorPreferences.store.stringArray(forKey: key) ?? []
        guard !stuck.contains(identity) else { return }
        stuck.append(identity)
        NotebookEditorPreferences.store.set(Array(stuck.suffix(20)), forKey: key)
    }

    nonisolated static func clear(_ identity: String) {
        let stuck = NotebookEditorPreferences.store.stringArray(forKey: key) ?? []
        NotebookEditorPreferences.store.set(stuck.filter { $0 != identity }, forKey: key)
    }
}
