import Foundation

/// A value a template can show or test.
public indirect enum JinjaValue: Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case date(Date)
    case list([JinjaValue])
    case dict([String: JinjaValue])
    case none

    var isTruthy: Bool {
        switch self {
        case .string(let value): !value.isEmpty
        case .bool(let value): value
        case .number(let value): value != 0
        case .date: true
        case .list(let value): !value.isEmpty
        case .dict(let value): !value.isEmpty
        case .none: false
        }
    }

    func text(_ context: JinjaTemplate.Context) -> String {
        switch self {
        case .string(let value): value
        case .bool(let value): value ? "true" : "false"
        case .number(let value):
            value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
        case .date(let value): JinjaTemplate.format(value, "Y-m-d", context.timeZone)
        case .list(let values): values.map { $0.text(context) }.joined(separator: ", ")
        case .dict: ""
        case .none: ""
        }
    }
}

public struct JinjaTemplateError: Error, Equatable, LocalizedError {
    public let message: String
    public let line: Int

    public var errorDescription: String? { "Line \(line): \(message)" }
}

/// The part of Jinja that Readwise's export templates use: `{{ }}` with
/// filters, `if`/`elif`/`else`, `for`, `set`, comments and whitespace
/// control. Rendering is a pure function of the template and the values,
/// so every device renders the same text.
public struct JinjaTemplate: Sendable {
    public struct Context: Sendable {
        public var timeZone: TimeZone
        /// A loop over one of these lists also names each item's fields
        /// with the prefix, as Readwise's `highlight_text` for `highlights`.
        public var aliases: [String: String]
        public init(timeZone: TimeZone, aliases: [String: String] = [:]) {
            self.timeZone = timeZone
            self.aliases = aliases
        }
    }

    indirect enum Node: Sendable {
        case text(String)
        case output(Expression, line: Int)
        case branch([(Expression, [Node])], otherwise: [Node])
        case loop(variable: String, list: Expression, body: [Node], line: Int)
        case assign(String, Expression)
    }

    indirect enum Expression: Sendable {
        case literal(JinjaValue)
        case variable([String])
        case filter(Expression, name: String, arguments: [Expression])
        case not(Expression)
        case binary(String, Expression, Expression)
        case conditional(Expression, condition: Expression, otherwise: Expression?)
        case method(Expression, name: String, arguments: [Expression])
    }

    let nodes: [Node]

    public init(_ source: String) throws {
        var parser = Parser(tokens: try Lexer.tokens(source))
        nodes = try parser.parseNodes(until: [])
    }

    public func render(_ values: [String: JinjaValue], context: Context) throws -> String {
        var scope = Scope(values: values)
        return try Self.render(nodes, &scope, context)
    }

    /// Variables and fields the template reads that do not exist, such as
    /// a misspelled `highlight_tex` or `highlight.tex`. `lists` gives the
    /// fields of the items in a list, such as `highlights`; a loop over it,
    /// or a `set` copying such an item, has those fields. Everything else
    /// has none.
    public func unknownVariables(
        known: Set<String>, lists: [String: Set<String>] = [:]
    ) -> [String] {
        var unknown: [String] = []
        typealias Names = [String: Set<String>]
        func fields(of expression: Expression, _ names: Names) -> Set<String> {
            if case .variable(let path) = expression, path.count == 1 { return names[path[0]] ?? [] }
            return []
        }
        func check(_ expression: Expression, _ names: Names) {
            switch expression {
            case .literal: break
            case .variable(let path):
                let valid = names[path[0]].map { path.count == 1 || (path.count == 2 && $0.contains(path[1])) }
                    ?? false
                let name = path.joined(separator: ".")
                if !valid, !unknown.contains(name) { unknown.append(name) }
            case .filter(let target, _, let arguments), .method(let target, _, let arguments):
                check(target, names)
                arguments.forEach { check($0, names) }
            case .not(let inner): check(inner, names)
            case .binary(_, let left, let right):
                check(left, names)
                check(right, names)
            case .conditional(let value, let condition, let otherwise):
                check(value, names)
                check(condition, names)
                otherwise.map { check($0, names) }
            }
        }
        // Returns the names the nodes set. As in rendering, a `set` inside
        // `if` stays set after it; one inside a loop does not.
        func walk(_ nodes: [Node], _ names: Names) -> Names {
            var names = names
            for node in nodes {
                switch node {
                case .text: break
                case .output(let expression, _): check(expression, names)
                case .branch(let branches, let otherwise):
                    var set = Names()
                    for (condition, body) in branches {
                        check(condition, names)
                        set.merge(walk(body, names)) { $0.union($1) }
                    }
                    set.merge(walk(otherwise, names)) { $0.union($1) }
                    names.merge(set) { $1 }
                case .loop(let variable, let list, let body, _):
                    check(list, names)
                    var item: Set<String> = []
                    if case .variable(let path) = list, path.count == 1, names[path[0]] != nil {
                        item = lists[path[0]] ?? []
                    }
                    var inner = names
                    inner[variable] = item
                    _ = walk(body, inner)
                case .assign(let name, let expression):
                    check(expression, names)
                    names[name] = fields(of: expression, names)
                }
            }
            return names
        }
        _ = walk(nodes, Dictionary(uniqueKeysWithValues: known.map { ($0, []) }))
        return unknown
    }

    /// Limits that keep a template from freezing the app: a template can
    /// loop over every highlight inside a loop over every highlight.
    static let maxSteps = 200_000
    static let maxOutput = 2_000_000
    static let maxLoopDepth = 3

    final class Budget: @unchecked Sendable {
        var steps = 0
        var output = 0
    }

    // MARK: - Rendering

    struct Scope {
        var values: [String: JinjaValue]
        func lookup(_ path: [String]) -> JinjaValue {
            var value = values[path[0]] ?? .none
            for key in path.dropFirst() {
                guard case .dict(let dict) = value else { return .none }
                value = dict[key] ?? .none
            }
            return value
        }
    }

    static func render(
        _ nodes: [Node], _ scope: inout Scope, _ context: Context,
        budget: Budget = Budget(), depth: Int = 0
    ) throws -> String {
        var result = ""
        // The whole render stays within the limit, also its last output.
        func add(_ text: String, line: Int) throws {
            try checkSize(budget.output + text.utf8.count, line: line)
            result += text
            budget.output += text.utf8.count
        }
        for node in nodes {
            budget.steps += 1
            if budget.steps > maxSteps || budget.output > maxOutput {
                throw JinjaTemplateError(message: "The template does too much work", line: 0)
            }
            if budget.steps % 1_000 == 0 { try Task.checkCancellation() }
            switch node {
            case .text(let text):
                try add(text, line: 0)
            case .output(let expression, let line):
                try add(try evaluate(expression, scope, context, line: line, budget: budget).text(context),
                        line: line)
            case .branch(let branches, let otherwise):
                var taken = false
                for (condition, body) in branches
                    where try evaluate(condition, scope, context, line: 0, budget: budget).isTruthy
                {
                    result += try render(body, &scope, context, budget: budget, depth: depth)
                    taken = true
                    break
                }
                if !taken {
                    result += try render(otherwise, &scope, context, budget: budget, depth: depth)
                }
            case .loop(let variable, let list, let body, let line):
                guard depth < maxLoopDepth else {
                    throw JinjaTemplateError(message: "Too many loops inside each other", line: line)
                }
                guard case .list(let items) = try evaluate(list, scope, context, line: line, budget: budget) else {
                    continue
                }
                var prefix: String?
                if case .variable(let path) = list, path.count == 1 { prefix = context.aliases[path[0]] }
                for item in items {
                    // Every pass costs a step, also with an empty body.
                    budget.steps += 1
                    if budget.steps > maxSteps {
                        throw JinjaTemplateError(message: "The template does too much work", line: line)
                    }
                    if budget.steps % 1_000 == 0 { try Task.checkCancellation() }
                    var inner = scope
                    inner.values[variable] = item
                    if let prefix, case .dict(let fields) = item {
                        for (key, value) in fields { inner.values[prefix + key] = value }
                    }
                    result += try render(body, &inner, context, budget: budget, depth: depth + 1)
                }
            case .assign(let name, let expression):
                scope.values[name] = try evaluate(expression, scope, context, line: 0, budget: budget)
            }
        }
        return result
    }

    /// Fails before a string grows past what a render may produce.
    static func checkSize(_ count: Int, line: Int) throws {
        if count > maxOutput { throw JinjaTemplateError(message: "The template does too much work", line: line) }
    }

    /// Every string an expression makes is checked, so repeating an
    /// operation that grows its input cannot grow without bound.
    static func evaluate(
        _ expression: Expression, _ scope: Scope, _ context: Context, line: Int,
        budget: Budget = Budget()
    ) throws -> JinjaValue {
        let value = try evaluateValue(expression, scope, context, line: line, budget: budget)
        if case .string(let text) = value { try checkSize(text.utf8.count, line: line) }
        return value
    }

    private static func evaluateValue(
        _ expression: Expression, _ scope: Scope, _ context: Context, line: Int,
        budget: Budget
    ) throws -> JinjaValue {
        budget.steps += 1
        if budget.steps > maxSteps {
            throw JinjaTemplateError(message: "The template does too much work", line: line)
        }
        func evaluate(_ expression: Expression, _ scope: Scope, _ context: Context, line: Int) throws -> JinjaValue {
            try Self.evaluate(expression, scope, context, line: line, budget: budget)
        }
        switch expression {
        case .literal(let value):
            return value
        case .variable(let path):
            return scope.lookup(path)
        case .not(let inner):
            return .bool(!(try evaluate(inner, scope, context, line: line)).isTruthy)
        case .binary(let op, let left, let right):
            let lhs = try evaluate(left, scope, context, line: line)
            if op == "and" { return lhs.isTruthy ? try evaluate(right, scope, context, line: line) : lhs }
            if op == "or" { return lhs.isTruthy ? lhs : try evaluate(right, scope, context, line: line) }
            let rhs = try evaluate(right, scope, context, line: line)
            switch op {
            case "==": return .bool(lhs == rhs)
            case "!=": return .bool(lhs != rhs)
            case "in":
                switch rhs {
                case .list(let values): return .bool(values.contains(lhs))
                case .string(let text): return .bool(text.contains(lhs.text(context)))
                default: return .bool(false)
                }
            case "~":
                let (left, right) = (lhs.text(context), rhs.text(context))
                try checkSize(left.utf8.count + right.utf8.count, line: line)
                return .string(left + right)
            default: throw JinjaTemplateError(message: "Unknown operator \(op)", line: line)
            }
        case .conditional(let value, let condition, let otherwise):
            return try evaluate(condition, scope, context, line: line).isTruthy
                ? try evaluate(value, scope, context, line: line)
                : try otherwise.map { try evaluate($0, scope, context, line: line) } ?? .string("")
        case .method(let target, let name, let arguments):
            let value = try evaluate(target, scope, context, line: line)
            let args = try arguments.map { try evaluate($0, scope, context, line: line) }
            switch (name, value) {
            case ("split", .string(let text)):
                let separator = args.first?.text(context) ?? " "
                return .list(text.components(separatedBy: separator).map { .string($0) })
            case ("strip", .string(let text)):
                return .string(text.trimmingCharacters(in: .whitespacesAndNewlines))
            case ("lower", .string(let text)): return .string(text.lowercased())
            case ("upper", .string(let text)): return .string(text.uppercased())
            default:
                throw JinjaTemplateError(message: "Unknown method \(name)", line: line)
            }
        case .filter(let target, let name, let arguments):
            let value = try evaluate(target, scope, context, line: line)
            let args = try arguments.map { try evaluate($0, scope, context, line: line) }
            return try filter(name, value, args, context, line: line)
        }
    }

    static let filters: Set<String> = [
        "trim", "default", "join", "date", "lower", "upper", "first", "last",
        "length", "replace", "blockquote", "yaml", "emphasis", "hashtag",
    ]

    static func filter(
        _ name: String, _ value: JinjaValue, _ args: [JinjaValue], _ context: Context, line: Int
    ) throws -> JinjaValue {
        switch name {
        case "trim":
            return .string(value.text(context).trimmingCharacters(in: .whitespacesAndNewlines))
        case "default":
            return value.isTruthy ? value : (args.first ?? .string(""))
        case "join":
            guard case .list(let values) = value else { return value }
            let texts = values.map { $0.text(context) }
            let separator = args.first?.text(context) ?? ""
            try checkSize(texts.reduce(0) { $0 + $1.utf8.count } + separator.utf8.count * texts.count,
                          line: line)
            return .string(texts.joined(separator: separator))
        case "date":
            guard case .date(let date) = value else { return value }
            return .string(format(date, args.first?.text(context) ?? "Y-m-d", context.timeZone))
        case "lower": return .string(value.text(context).lowercased())
        case "upper": return .string(value.text(context).uppercased())
        case "first", "last":
            switch value {
            case .list(let values): return (name == "first" ? values.first : values.last) ?? .none
            case .string(let text):
                return (name == "first" ? text.first : text.last).map { .string(String($0)) } ?? .none
            default: return .none
            }
        case "length":
            switch value {
            case .list(let values): return .number(Double(values.count))
            default: return .number(Double(value.text(context).count))
            }
        case "replace":
            guard args.count == 2 else {
                throw JinjaTemplateError(message: "replace needs two values", line: line)
            }
            let (text, old, new) = (value.text(context), args[0].text(context), args[1].text(context))
            if !old.isEmpty {
                let count = text.components(separatedBy: old).count - 1
                try checkSize(text.utf8.count + count * new.utf8.count, line: line)
            }
            return .string(text.replacingOccurrences(of: old, with: new))
        case "emphasis":
            // Each line on its own, since emphasis cannot span lines. A line
            // that has its own emphasis markers stays as written, because
            // wrapping it would change what they mean.
            return .string(value.text(context).components(separatedBy: "\n").map {
                let line = $0.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { return "" }
                return line.contains("*") || line.contains("_") ? line : "*" + line + "*"
            }.joined(separator: "\n"))
        case "hashtag":
            // A tag ends at a space, so spaces become dashes.
            let text = value.text(context).trimmingCharacters(in: .whitespaces)
            return .string(String(text.drop { $0 == "#" }).replacingOccurrences(of: " ", with: "-"))
        case "blockquote":
            // Each line of a quote needs its own marker, also blank ones.
            return .string(value.text(context).components(separatedBy: "\n")
                .map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n"))
        case "yaml":
            // A list becomes a flow sequence, where a comma would split an
            // item, so its items are quoted more often.
            if case .list(let items) = value {
                return .string("[" + items.map { yaml($0.text(context), inFlow: true) }
                    .joined(separator: ", ") + "]")
            }
            return .string(yaml(value.text(context), inFlow: false))
        default:
            throw JinjaTemplateError(message: "Unknown filter \(name)", line: line)
        }
    }

    /// A YAML string. It stays plain only when it starts with a letter and
    /// is not a word YAML reads as a value, so `00123` or a date stays text.
    static func yaml(_ text: String, inFlow: Bool) -> String {
        let pattern = inFlow ? #"^[A-Za-z][A-Za-z0-9 .'()&/+_-]*$"# : #"^[A-Za-z][A-Za-z0-9 .,'()&/+_-]*$"#
        let plain = text.range(of: pattern, options: .regularExpression) != nil
            && !["true", "false", "null", "yes", "no", "on", "off", "y", "n"].contains(text.lowercased())
        if plain { return text }
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\t": escaped += "\\t"
            case "\r": escaped += "\\r"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                escaped += String(format: "\\x%02X", scalar.value)
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"" + escaped + "\""
    }

    /// Readwise's templates format dates with PHP's letters, as in
    /// `date('F j, Y')`. Letters this does not know are kept as they are.
    static func format(_ date: Date, _ pattern: String, _ timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        let months = ["January", "February", "March", "April", "May", "June", "July",
                      "August", "September", "October", "November", "December"]
        let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        func two(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
        var result = ""
        var escaped = false
        for character in pattern {
            if escaped { result.append(character); escaped = false; continue }
            switch character {
            case "\\": escaped = true
            case "d": result += two(parts.day)
            case "j": result += String(parts.day ?? 0)
            case "D": result += String(days[(parts.weekday ?? 1) - 1].prefix(3))
            case "l": result += days[(parts.weekday ?? 1) - 1]
            case "m": result += two(parts.month)
            case "n": result += String(parts.month ?? 0)
            case "M": result += String(months[(parts.month ?? 1) - 1].prefix(3))
            case "F": result += months[(parts.month ?? 1) - 1]
            case "Y": result += String(parts.year ?? 0)
            case "y": result += two((parts.year ?? 0) % 100)
            case "H": result += two(parts.hour)
            case "G": result += String(parts.hour ?? 0)
            case "h": result += two(((parts.hour ?? 0) + 11) % 12 + 1)
            case "g": result += String(((parts.hour ?? 0) + 11) % 12 + 1)
            case "i": result += two(parts.minute)
            case "s": result += two(parts.second)
            case "a": result += (parts.hour ?? 0) < 12 ? "am" : "pm"
            case "A": result += (parts.hour ?? 0) < 12 ? "AM" : "PM"
            default: result.append(character)
            }
        }
        return result
    }
}

// MARK: - Lexing

extension JinjaTemplate {
    enum Token {
        case text(String)
        case output(String, line: Int)
        case statement(String, line: Int)
    }

    enum Lexer {
        static func tokens(_ source: String) throws -> [Token] {
            var tokens: [Token] = []
            var rest = Substring(source)
            var line = 1
            var trimNext = false
            while !rest.isEmpty {
                guard let open = rest.range(of: "{", options: .literal),
                      let kind = rest[open.upperBound...].first, "{%#".contains(kind)
                else {
                    if let open = rest.range(of: "{") {
                        // A lone brace is text; keep looking after it.
                        let text = String(rest[..<open.upperBound])
                        append(text, &tokens, trimLeading: &trimNext)
                        line += text.filter { $0 == "\n" }.count
                        rest = rest[open.upperBound...]
                        continue
                    }
                    append(String(rest), &tokens, trimLeading: &trimNext)
                    break
                }
                var text = String(rest[..<open.lowerBound])
                var inner = rest.index(after: open.upperBound)
                let trimBefore = rest[inner...].hasPrefix("-")
                if trimBefore {
                    text = String(text.reversed().drop { $0.isWhitespace }.reversed())
                    inner = rest.index(after: inner)
                }
                append(text, &tokens, trimLeading: &trimNext)
                line += String(rest[..<open.lowerBound]).filter { $0 == "\n" }.count
                let close = kind == "{" ? "}}" : kind == "%" ? "%}" : "#}"
                guard let end = closing(close, in: rest[inner...], quoted: kind != "#") else {
                    throw JinjaTemplateError(message: "Missing \(close)", line: line)
                }
                var body = String(rest[inner..<end.lowerBound])
                trimNext = body.hasSuffix("-")
                if trimNext { body.removeLast() }
                let content = body.trimmingCharacters(in: .whitespacesAndNewlines)
                switch kind {
                case "{": tokens.append(.output(content, line: line))
                case "%": tokens.append(.statement(content, line: line))
                default: break
                }
                line += body.filter { $0 == "\n" }.count
                rest = rest[end.upperBound...]
            }
            return tokens
        }

        /// The closing delimiter, skipping quoted strings so `'}}'` in an
        /// expression does not end it.
        private static func closing(
            _ close: String, in text: Substring, quoted: Bool
        ) -> Range<Substring.Index>? {
            var index = text.startIndex
            var quote: Character?
            while index < text.endIndex {
                let character = text[index]
                if let open = quote {
                    if character == "\\" {
                        index = text.index(after: index)
                        if index == text.endIndex { break }
                    } else if character == open {
                        quote = nil
                    }
                } else if quoted, character == "\"" || character == "'" {
                    quote = character
                } else if text[index...].hasPrefix(close) {
                    return index..<text.index(index, offsetBy: close.count)
                }
                index = text.index(after: index)
            }
            return nil
        }

        private static func append(_ text: String, _ tokens: inout [Token], trimLeading: inout Bool) {
            var text = text
            if trimLeading {
                text = String(text.drop { $0.isWhitespace })
                trimLeading = false
            }
            if !text.isEmpty { tokens.append(.text(text)) }
        }
    }
}

// MARK: - Parsing

extension JinjaTemplate {
    /// Parsing recurses per nested block and per part of an expression,
    /// so both are limited before they could run out of stack.
    static let maxNesting = 32
    static let maxExpressionTokens = 500

    struct Parser {
        var tokens: [Token]
        var index = 0
        var nesting = 0

        mutating func parseNodes(until ends: Set<String>) throws -> [Node] {
            var nodes: [Node] = []
            while index < tokens.count {
                switch tokens[index] {
                case .text(let text):
                    nodes.append(.text(text))
                    index += 1
                case .output(let source, let line):
                    nodes.append(.output(try Self.expression(source, line: line), line: line))
                    index += 1
                case .statement(let source, let line):
                    let word = source.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
                    if ends.contains(word) { return nodes }
                    index += 1
                    switch word {
                    case "if": nodes.append(try parseIf(source, line: line))
                    case "for": nodes.append(try parseFor(source, line: line))
                    case "set":
                        let rest = source.dropFirst(3)
                        guard let equals = rest.firstIndex(of: "=") else {
                            throw JinjaTemplateError(message: "set needs a value", line: line)
                        }
                        let name = rest[..<equals].trimmingCharacters(in: .whitespaces)
                        nodes.append(.assign(name, try Self.expression(
                            String(rest[rest.index(after: equals)...]), line: line)))
                    default:
                        throw JinjaTemplateError(message: "Unexpected \(word)", line: line)
                    }
                }
            }
            if !ends.isEmpty {
                throw JinjaTemplateError(
                    message: "Missing {% \(ends.sorted().last!) %}", line: lastLine)
            }
            return nodes
        }

        private var lastLine: Int {
            for token in tokens.reversed() {
                switch token {
                case .output(_, let line), .statement(_, let line): return line
                case .text: continue
                }
            }
            return 1
        }

        private mutating func enter(line: Int) throws {
            nesting += 1
            if nesting > JinjaTemplate.maxNesting {
                throw JinjaTemplateError(message: "Too many blocks inside each other", line: line)
            }
        }

        private mutating func parseIf(_ source: String, line: Int) throws -> Node {
            try enter(line: line)
            defer { nesting -= 1 }
            var branches: [(Expression, [Node])] = []
            var condition = try Self.expression(String(source.dropFirst(2)), line: line)
            var otherwise: [Node] = []
            while true {
                let body = try parseNodes(until: ["elif", "else", "endif"])
                guard case .statement(let next, let nextLine) = tokens[index] else { break }
                index += 1
                branches.append((condition, body))
                if next.hasPrefix("elif") {
                    condition = try Self.expression(String(next.dropFirst(4)), line: nextLine)
                } else if next == "else" {
                    otherwise = try parseNodes(until: ["endif"])
                    index += 1
                    break
                } else {
                    break
                }
            }
            return .branch(branches, otherwise: otherwise)
        }

        private mutating func parseFor(_ source: String, line: Int) throws -> Node {
            try enter(line: line)
            defer { nesting -= 1 }
            let parts = source.dropFirst(3).components(separatedBy: " in ")
            guard parts.count == 2 else {
                throw JinjaTemplateError(message: "for needs a name and a list", line: line)
            }
            let variable = parts[0].trimmingCharacters(in: .whitespaces)
            let list = try Self.expression(parts[1], line: line)
            let body = try parseNodes(until: ["endfor"])
            index += 1
            return .loop(variable: variable, list: list, body: body, line: line)
        }

        static func expression(_ source: String, line: Int) throws -> Expression {
            var parser = ExpressionParser(tokens: try ExpressionParser.tokens(source, line: line), line: line)
            let expression = try parser.conditional()
            guard parser.index == parser.tokens.count else {
                throw JinjaTemplateError(message: "Unexpected \(parser.tokens[parser.index])", line: line)
            }
            return expression
        }
    }

    struct ExpressionParser {
        let tokens: [String]
        var index = 0
        let line: Int

        init(tokens: [String], line: Int) {
            self.tokens = tokens
            self.line = line
        }

        static func tokens(_ source: String, line: Int) throws -> [String] {
            var result: [String] = []
            var characters = Array(source)[...]
            while let first = characters.first {
                if first.isWhitespace { characters = characters.dropFirst(); continue }
                if first == "\"" || first == "'" {
                    var literal = String(first)
                    characters = characters.dropFirst()
                    while let next = characters.first, next != first {
                        if next == "\\", characters.count > 1 {
                            characters = characters.dropFirst()
                            let escaped = characters.first!
                            literal.append(["n": "\n", "t": "\t", "r": "\r"][escaped] ?? escaped)
                        } else {
                            literal.append(next)
                        }
                        characters = characters.dropFirst()
                    }
                    guard !characters.isEmpty else {
                        throw JinjaTemplateError(message: "Unclosed quote", line: line)
                    }
                    characters = characters.dropFirst()
                    result.append(literal + String(first))
                } else if first.isLetter || first == "_" || first.isNumber {
                    let word = characters.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                    result.append(String(word))
                    characters = characters.dropFirst(word.count)
                } else if characters.starts(with: ["=", "="]) || characters.starts(with: ["!", "="]) {
                    result.append(String(characters.prefix(2)))
                    characters = characters.dropFirst(2)
                } else if "|().,~[]".contains(first) {
                    result.append(String(first))
                    characters = characters.dropFirst()
                } else {
                    throw JinjaTemplateError(message: "Unexpected \(first)", line: line)
                }
                if result.count > JinjaTemplate.maxExpressionTokens {
                    throw JinjaTemplateError(message: "The expression is too long", line: line)
                }
            }
            return result
        }

        var peek: String? { index < tokens.count ? tokens[index] : nil }

        mutating func take(_ token: String) throws {
            guard peek == token else {
                throw JinjaTemplateError(message: "Expected \(token)", line: line)
            }
            index += 1
        }

        mutating func conditional() throws -> Expression {
            let value = try or()
            guard peek == "if" else { return value }
            index += 1
            let condition = try or()
            var otherwise: Expression?
            if peek == "else" {
                index += 1
                otherwise = try or()
            }
            return .conditional(value, condition: condition, otherwise: otherwise)
        }

        mutating func or() throws -> Expression {
            var left = try and()
            while peek == "or" { index += 1; left = .binary("or", left, try and()) }
            return left
        }

        mutating func and() throws -> Expression {
            var left = try not()
            while peek == "and" { index += 1; left = .binary("and", left, try not()) }
            return left
        }

        mutating func not() throws -> Expression {
            if peek == "not" { index += 1; return .not(try not()) }
            return try comparison()
        }

        mutating func comparison() throws -> Expression {
            let left = try concatenation()
            if let op = peek, ["==", "!=", "in"].contains(op) {
                index += 1
                return .binary(op, left, try concatenation())
            }
            return left
        }

        mutating func concatenation() throws -> Expression {
            var left = try filtered()
            while peek == "~" { index += 1; left = .binary("~", left, try filtered()) }
            return left
        }

        mutating func filtered() throws -> Expression {
            var value = try postfix()
            while peek == "|" {
                index += 1
                guard let name = peek, JinjaTemplate.filters.contains(name) else {
                    throw JinjaTemplateError(message: "Unknown filter \(peek ?? "")", line: line)
                }
                index += 1
                value = .filter(value, name: name, arguments: try arguments())
            }
            return value
        }

        mutating func arguments() throws -> [Expression] {
            guard peek == "(" else { return [] }
            index += 1
            var result: [Expression] = []
            while peek != ")" {
                result.append(try conditional())
                if peek == "," { index += 1 }
                guard peek != nil else { throw JinjaTemplateError(message: "Missing )", line: line) }
            }
            index += 1
            return result
        }

        mutating func postfix() throws -> Expression {
            var value = try primary()
            while peek == "." || peek == "[" {
                if peek == "[" {
                    index += 1
                    guard let key = peek, key.first == "\"" || key.first == "'" else {
                        throw JinjaTemplateError(message: "Expected a quoted key", line: line)
                    }
                    index += 1
                    try take("]")
                    value = Self.extend(value, String(key.dropFirst().dropLast()))
                    continue
                }
                index += 1
                guard let name = peek else { throw JinjaTemplateError(message: "Expected a name", line: line) }
                index += 1
                if peek == "(" {
                    value = .method(value, name: name, arguments: try arguments())
                } else {
                    value = Self.extend(value, name)
                }
            }
            return value
        }

        static func extend(_ value: Expression, _ key: String) -> Expression {
            if case .variable(let path) = value { return .variable(path + [key]) }
            return value
        }

        mutating func primary() throws -> Expression {
            guard let token = peek else { throw JinjaTemplateError(message: "Expected a value", line: line) }
            index += 1
            if token == "(" {
                let inner = try conditional()
                try take(")")
                return inner
            }
            if let quote = token.first, quote == "\"" || quote == "'" {
                return .literal(.string(String(token.dropFirst().dropLast())))
            }
            if let number = Double(token) { return .literal(.number(number)) }
            switch token {
            case "true", "True": return .literal(.bool(true))
            case "false", "False": return .literal(.bool(false))
            case "none", "None": return .literal(.none)
            default: break
            }
            guard token.first.map({ $0.isLetter || $0 == "_" }) == true else {
                throw JinjaTemplateError(message: "Unexpected \(token)", line: line)
            }
            return .variable([token])
        }
    }
}
