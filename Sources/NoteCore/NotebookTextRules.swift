import Foundation

/// A text rule, a Labs experiment: a script that finds patterns in a note,
/// such as Bible references, and shows them as links or other decorations
/// without changing the Markdown. docs/text-rules.md explains them.
///
/// Rules are notebook settings, so they sync to every device that opens
/// the notebook. The editor compiles and runs them; NoteCore only stores
/// them.
public struct NotebookTextRule: Sendable, Equatable, Identifiable {
    public enum Source: Sendable, Equatable, Codable {
        /// A script someone wrote or pasted in.
        case script(source: String)
        /// A rule from the simple form: text or a JavaScript regular
        /// expression to find, and a link with `$0` … `$9` in it.
        case link(rule: NotebookTextLinkRule)
    }

    /// Option values set in the rule's settings, by option key.
    public enum OptionValue: Sendable, Equatable, Codable {
        case text(String)
        case toggle(Bool)

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Bool.self) {
                self = .toggle(value)
            } else {
                self = .text(try container.decode(String.self))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let value): try container.encode(value)
            case .toggle(let value): try container.encode(value)
            }
        }
    }

    public let id: UUID
    public var source: Source
    public var isEnabled: Bool
    /// Off: the rule runs only in notes where it was turned on, in
    /// Note Actions › Editor Display.
    public var appliesToAllNotes: Bool
    /// The list order. A rule higher in the list wins where two overlap.
    public var order: Double
    public var options: [String: OptionValue]

    public init(
        id: UUID = UUID(), source: Source, isEnabled: Bool = true,
        appliesToAllNotes: Bool = true, order: Double = 0,
        options: [String: OptionValue] = [:]
    ) {
        self.id = id
        self.source = source
        self.isEnabled = isEnabled
        self.appliesToAllNotes = appliesToAllNotes
        self.order = order
        self.options = options
    }
}

public struct NotebookTextLinkRule: Sendable, Equatable, Codable {
    public var name: String
    public var find: String
    /// Off: `find` is plain text, matched as written.
    public var isRegularExpression: Bool
    public var url: String

    public init(name: String, find: String, isRegularExpression: Bool, url: String) {
        self.name = name
        self.find = find
        self.isRegularExpression = isRegularExpression
        self.url = url
    }
}

/// The text rules stored in a catalog, and the notes each rule is turned on
/// for.
struct NotebookTextRuleMetadata: Equatable {
    var rules: [NotebookTextRule] = []
    var noteIDs: [UUID: Set<UUID>] = [:]
}

extension NotebookTextRule.Source {
    /// The stored form. Unknown forms from newer versions read as nil, so
    /// the rule is left out rather than the catalog failing to open.
    static func decode(_ json: String) -> Self? {
        try? JSONDecoder().decode(Self.self, from: Data(json.utf8))
    }

    func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

extension Dictionary where Key == String, Value == NotebookTextRule.OptionValue {
    /// Values in a form this version doesn't know are left out, one by one.
    static func decodeTextRuleOptions(_ json: String) -> Self {
        let decoded = try? JSONDecoder().decode(
            [String: LenientTextRuleOption].self, from: Data(json.utf8))
        return (decoded ?? [:]).compactMapValues(\.value)
    }

    func encodedTextRuleOptions() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

private struct LenientTextRuleOption: Decodable {
    let value: NotebookTextRule.OptionValue?

    init(from decoder: any Decoder) throws {
        value = try? NotebookTextRule.OptionValue(from: decoder)
    }
}
