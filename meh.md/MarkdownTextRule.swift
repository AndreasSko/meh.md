import Foundation
import JavaScriptCore
import NoteCore

/// Text rules, a Labs experiment: scripts that find patterns in a note and
/// decorate them in Live Preview without changing the Markdown. See
/// docs/text-rules.md for the script API and how the editor runs them.
nonisolated enum MarkdownTextRules {
    /// The device-local Labs setting.
    static let enabledKey = "labs.textRules"
    /// The rule API version this app runs.
    static let apiVersion = 1
}

/// What a script says about itself, read without running it.
nonisolated struct MarkdownTextRuleManifest: Sendable, Equatable {
    enum Input: String, Sendable {
        /// Markers, code and links are replaced with U+FFFC, so patterns
        /// don't need to know Markdown. Positions stay the same.
        case plain
        case markdown
    }

    enum BlockKind: String, Sendable, CaseIterable {
        case paragraph, heading, listItem, quote
    }

    enum Use: String, Sendable {
        case today, locale, title
    }

    struct Option: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            case choice([Choice])
            case toggle
            case text
        }

        struct Choice: Sendable, Equatable {
            let value: String
            let title: String
        }

        let key: String
        let title: String
        let kind: Kind
        let defaultValue: NotebookTextRule.OptionValue

        /// The stored value if it still fits the option, like a choice the
        /// script still offers, else the default. Settings show this value
        /// and the script gets it.
        func value(in stored: [String: NotebookTextRule.OptionValue]) -> NotebookTextRule.OptionValue {
            switch (kind, stored[key]) {
            case (.choice(let choices), .text(let value)?) where choices.contains(where: { $0.value == value }):
                return .text(value)
            case (.toggle, .toggle(let value)?):
                return .toggle(value)
            case (.text, .text(let value)?):
                return .text(value)
            default:
                return defaultValue
            }
        }
    }

    var name: String
    var description: String
    /// Sample text the rule shows something for, to fill Try It.
    var example: String = ""
    /// Where a newly added rule runs until someone changes it: some rules,
    /// like time sums, only make sense in notes chosen for them.
    var startsInChosenNotes = false
    var linksTo: [MarkdownTextRuleLinkPrefix]
    var input: Input
    var blocks: Set<BlockKind>
    /// An ICU regular expression a block must match before the script sees
    /// it. Only rules without state have one.
    var trigger: String?
    var uses: Set<Use>
    var options: [Option]
    /// The first block's state as JSON, for rules that carry state.
    var start: String?

    var isStateful: Bool { start != nil }
}

/// A place links may go, such as `https://www.jw.org/` or `jwlibrary:`.
nonisolated struct MarkdownTextRuleLinkPrefix: Sendable, Equatable {
    let value: String
    /// How many characters of `value` ignore case: the scheme, and for web
    /// links the host and port.
    private let caseless: Int

    /// Schemes that would run code or read local files when opened.
    private static let refusedSchemes: Set<String> = [
        "javascript", "vbscript", "data", "file", "blob", "about",
    ]

    init?(_ text: String) {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let scheme = text[..<colon].lowercased()
        guard let first = scheme.first, first.isLetter,
              scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+.-".contains($0) }),
              !Self.refusedSchemes.contains(scheme) else { return nil }
        var value = scheme + text[colon...]
        if scheme == "http" || scheme == "https" {
            // The prefix must end the host and port, so `https://example.com`
            // can't also allow `https://example.com.attacker.test` or
            // `https://example.com:8080@attacker.test`.
            let start = value.index(colon, offsetBy: 1)
            guard value[start...].hasPrefix("//") else { return nil }
            let authorityStart = value.index(start, offsetBy: 2)
            let authorityEnd = value[authorityStart...].firstIndex { "/?#".contains($0) }
                ?? value.endIndex
            let authority = value[authorityStart..<authorityEnd]
            let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
            guard !authority.contains("@"), parts.count <= 2,
                  let host = parts.first, !host.isEmpty,
                  parts.count == 1 || (!parts[1].isEmpty && parts[1].allSatisfy(\.isASCII)
                                       && parts[1].allSatisfy(\.isNumber))
            else { return nil }
            caseless = value.distance(from: value.startIndex, to: authorityEnd)
            if authorityEnd == value.endIndex { value += "/" }
        } else {
            caseless = scheme.count
        }
        self.value = value
    }

    /// Scheme and host ignore case; the rest, like a path, must match as
    /// written. A path with `.` or `..` in it is refused: once opened, it
    /// could lead outside the declared one.
    func allows(_ url: String) -> Bool {
        guard url.prefix(caseless).lowercased() == value.prefix(caseless).lowercased(),
              url.dropFirst(caseless).hasPrefix(value.dropFirst(caseless)) else { return false }
        let path = url.prefix { $0 != "?" && $0 != "#" }
        // Browsers read `\` as `/` in web addresses.
        return !path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains {
            let segment = String($0).removingPercentEncoding ?? String($0)
            return segment == "." || segment == ".."
        }
    }
}

/// A problem with a rule, as people see it in the rule's settings.
nonisolated struct MarkdownTextRuleError: Error, Sendable, Equatable {
    var message: String
    var line: Int?

    var localizedDescription: String {
        guard let line else { return message }
        return String(localized: "Line \(line): \(message)")
    }
}

/// A script ready to run: its manifest and the code with loop checks.
nonisolated struct MarkdownCompiledTextRule: Sendable, Equatable {
    let manifest: MarkdownTextRuleManifest
    let protectedSource: String
    /// Identifies the script, for caches and for remembering a rule that
    /// stopped responding.
    let identity: String
}

nonisolated enum MarkdownTextRuleCompiler {
    private final class Compiler: @unchecked Sendable {
        let queue = DispatchQueue(label: "md.meh.text-rules.compiler")
        private var context: JSContext?
        /// By UTF-8 bytes: `String` equality treats `é` and `e` + accent as
        /// equal, but a script matching one doesn't match the other.
        private var cache: [Data: Result<MarkdownCompiledTextRule, MarkdownTextRuleError>] = [:]

        func compile(_ source: String) -> Result<MarkdownCompiledTextRule, MarkdownTextRuleError> {
            queue.sync {
                let key = Data(source.utf8)
                if let cached = cache[key] { return cached }
                let result = Self.compile(source, in: loadedContext())
                if cache.count > 32 { cache.removeAll() }
                cache[key] = result
                return result
            }
        }

        private func loadedContext() -> JSContext? {
            if let context { return context }
            guard let context = JSContext(),
                  let acorn = MarkdownTextRuleLibrary.resource("acorn"),
                  let compiler = MarkdownTextRuleLibrary.resource("TextRuleCompiler") else {
                return nil
            }
            context.evaluateScript(acorn)
            context.evaluateScript(compiler)
            self.context = context
            return context
        }

        private static func compile(
            _ source: String, in context: JSContext?
        ) -> Result<MarkdownCompiledTextRule, MarkdownTextRuleError> {
            guard let context,
                  let output = context.objectForKeyedSubscript("compileTextRule")?
                    .call(withArguments: [source])?.toString(),
                  let data = output.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return .failure(MarkdownTextRuleError(
                    message: String(localized: "The rule couldn’t be read.")))
            }
            if let error = object["error"] as? [String: Any] {
                return .failure(MarkdownTextRuleError(
                    message: error["message"] as? String ?? "",
                    line: error["line"] as? Int))
            }
            guard let manifest = object["manifest"] as? [String: Any],
                  let protected = object["source"] as? String else {
                return .failure(MarkdownTextRuleError(
                    message: String(localized: "The rule couldn’t be read.")))
            }
            return MarkdownTextRuleManifest.read(manifest).map {
                MarkdownCompiledTextRule(
                    manifest: $0, protectedSource: protected,
                    identity: MarkdownTextRuleLibrary.identity(of: source))
            }
        }
    }

    private static let compiler = Compiler()

    /// Reads and protects a script. Results are cached by source.
    static func compile(_ source: String) -> Result<MarkdownCompiledTextRule, MarkdownTextRuleError> {
        compiler.compile(source)
    }
}

nonisolated extension MarkdownTextRuleManifest {
    static func read(_ object: [String: Any]) -> Result<Self, MarkdownTextRuleError> {
        func failure(_ message: String) -> Result<Self, MarkdownTextRuleError> {
            .failure(MarkdownTextRuleError(message: message))
        }
        if let api = object["api"] {
            guard let api = api as? Int else { return failure("api must be a number, like api: 1.") }
            guard api <= MarkdownTextRules.apiVersion else {
                return failure(String(localized: "This rule needs a newer version of meh.md."))
            }
        }
        let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else { return failure("The rule needs a name.") }
        var manifest = MarkdownTextRuleManifest(
            name: name, description: object["description"] as? String ?? "",
            linksTo: [], input: .plain, blocks: Set(BlockKind.allCases),
            trigger: nil, uses: [], options: [], start: object["start"] as? String)
        if let example = object["example"] {
            guard let example = example as? String else {
                return failure("example must be text, like example: \"See #42\".")
            }
            manifest.example = example
        }
        if let runsIn = object["runsIn"] {
            switch runsIn as? String {
            case "allNotes": break
            case "chosenNotes": manifest.startsInChosenNotes = true
            default: return failure("runsIn must be \"allNotes\" or \"chosenNotes\".")
            }
        }
        if let links = object["linksTo"] {
            guard let links = links as? [String] else {
                return failure("linksTo must be a list of addresses.")
            }
            for link in links {
                guard let prefix = MarkdownTextRuleLinkPrefix(link) else {
                    return failure("“\(link)” can’t be used in linksTo.")
                }
                manifest.linksTo.append(prefix)
            }
        }
        if let input = object["input"] {
            guard let input = (input as? String).flatMap(Input.init(rawValue:)) else {
                return failure("input must be \"plain\" or \"markdown\".")
            }
            manifest.input = input
        }
        if let blocks = object["blocks"] {
            guard let names = blocks as? [String],
                  let kinds = Optional(names.compactMap(BlockKind.init(rawValue:))),
                  kinds.count == names.count, !kinds.isEmpty else {
                return failure("blocks must list paragraph, heading, listItem or quote.")
            }
            manifest.blocks = Set(kinds)
        }
        if let trigger = object["trigger"] {
            guard let trigger = trigger as? String,
                  (try? NSRegularExpression(pattern: trigger)) != nil else {
                return failure("trigger must be a regular expression.")
            }
            guard !manifest.isStateful else {
                return failure("A rule with a start state can’t have a trigger: it has to see every block.")
            }
            manifest.trigger = trigger
        }
        if let uses = object["uses"] {
            guard let names = uses as? [String],
                  let values = Optional(names.compactMap(Use.init(rawValue:))),
                  values.count == names.count else {
                return failure("uses can list today, locale and title.")
            }
            manifest.uses = Set(values)
        }
        if let options = object["options"] as? [[String: Any]] {
            for option in options {
                switch Option.read(option) {
                case .success(let value): manifest.options.append(value)
                case .failure(let error): return .failure(error)
                }
            }
        }
        return .success(manifest)
    }
}

nonisolated extension MarkdownTextRuleManifest.Option {
    static func read(_ object: [String: Any]) -> Result<Self, MarkdownTextRuleError> {
        let key = object["key"] as? String ?? ""
        func failure(_ message: String) -> Result<Self, MarkdownTextRuleError> {
            .failure(MarkdownTextRuleError(message: "Option “\(key)”: \(message)"))
        }
        guard let title = object["title"] as? String, !title.isEmpty else {
            return failure("needs a title.")
        }
        switch object["type"] as? String {
        case "choice":
            // The compiler passes choices as [value, title] pairs, in order.
            guard let pairs = object["choices"] as? [[String]], !pairs.isEmpty,
                  pairs.allSatisfy({ $0.count == 2 }) else {
                return failure("needs choices, like { app: \"JW Library\" }.")
            }
            let list = pairs.map { Choice(value: $0[0], title: $0[1]) }
            guard let value = object["default"] as? String,
                  list.contains(where: { $0.value == value }) else {
                return failure("its default must be one of its choices.")
            }
            return .success(Self(key: key, title: title, kind: .choice(list), defaultValue: .text(value)))
        case "toggle":
            guard let value = object["default"] as? Bool else {
                return failure("its default must be true or false.")
            }
            return .success(Self(key: key, title: title, kind: .toggle, defaultValue: .toggle(value)))
        case "text":
            return .success(Self(key: key, title: title, kind: .text,
                                 defaultValue: .text(object["default"] as? String ?? "")))
        default:
            return failure("type must be \"choice\", \"toggle\" or \"text\".")
        }
    }
}

/// The code that runs rules, which ships with the app.
nonisolated enum MarkdownTextRuleLibrary {
    static func resource(_ name: String) -> String? {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        let url = bundle.url(forResource: name, withExtension: "js", subdirectory: "TextRules")
            ?? bundle.url(forResource: name, withExtension: "js")
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    static func source(for source: NotebookTextRule.Source) -> String {
        switch source {
        case .script(let script):
            return script
        case .link(let rule):
            return linkScript(for: rule)
        }
    }

    static func identity(of source: String) -> String {
        // FNV-1a over UTF-8: stable across launches, unlike Hasher.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in source.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// The script a simple link rule stands for. Its settings are data, and
    /// this turns them into the same kind of script everything else runs.
    static func linkScript(for rule: NotebookTextLinkRule) -> String {
        func json(_ value: String) -> String {
            let data = (try? JSONSerialization.data(
                withJSONObject: [value], options: [.fragmentsAllowed]
            )) ?? Data("[\"\"]".utf8)
            let array = String(decoding: data, as: UTF8.self)
            return String(array.dropFirst().dropLast())
        }
        var template = rule.url
        let prefix = String(template.prefix { $0 != "$" })
        // `https://example.com` declares `https://example.com/`, so a fixed
        // link must end the same way.
        if template == prefix, MarkdownTextRuleLinkPrefix(prefix)?.value.count == prefix.count + 1 {
            template += "/"
        }
        var literal = String.UnicodeScalarView()
        for scalar in rule.find.unicodeScalars {
            if "\\^$.*+?()[]{}|/".unicodeScalars.contains(scalar) { literal.append("\\") }
            literal.append(scalar)
        }
        let pattern = rule.isRegularExpression ? rule.find : String(literal)
        return """
        const pattern = new RegExp(\(json(pattern)), "gu");
        const template = \(json(template));
        rule({
          api: 1,
          name: \(json(rule.name.isEmpty ? String(localized: "Link Rule") : rule.name)),
          linksTo: [\(json(prefix))],
          block({ text }) {
            const decorations = [];
            for (const match of text.matchAll(pattern)) {
              if (match[0].length === 0) continue;
              const url = template.replace(/\\$(\\d)/g, (_, index) =>
                encodeURIComponent(match[Number(index)] ?? ""));
              decorations.push({ kind: "link", start: match.index,
                end: match.index + match[0].length, url });
            }
            return { decorations };
          },
        });
        """
    }
}
