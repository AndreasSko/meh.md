import Automerge
import CryptoKit
import Foundation

/// A part of a note that an integration writes: the header at the top, or
/// one highlight. Keys are stable across updates; see
/// docs/readwise-sync.md for who owns which text.
public struct NotebookIntegrationBlock: Equatable, Sendable {
    public static let headerKey = "header"

    public let key: String
    public let text: String

    public init(key: String, text: String) {
        self.key = key
        self.text = text
    }
}

/// Which integration item a note was created for.
public struct NotebookIntegrationLink: Equatable, Sendable {
    public let connection: UUID
    public let item: String

    public init(connection: UUID, item: String) {
        self.connection = connection
        self.item = item
    }
}

enum NoteIntegrationError: Error, Equatable {
    case invalidBlockKey(String)
    case duplicateBlockKey(String)
    case notLinked
    case linkedElsewhere
    case unsupportedText
}

/// Integration text is marked with its block key and an instance ID that is
/// new for every insertion, so copies written by two devices stay apart.
/// Each highlight is inserted with its own blank line in front: Automerge
/// anchors the start of a mark to the character before it, and only a
/// character that the same insertion created keeps another device's copy
/// out of the mark. The blank line carries a second mark, so removing a
/// copy can take its own blank line along and nothing else. That mark's
/// start can spread backwards over a neighbouring copy, and only one value
/// of a mark name shows at a position, so each blank line's mark has a
/// name of its own.
extension NoteDocument {
    static let integrationKey = "integration"
    static let integrationMark = "integration"
    static let integrationLeadMarkPrefix = "integration.lead|"
    private static let integrationLead = "\n\n"
    private static let integrationLeadLength: UInt64 = 2

    /// The note's link, or nil for an ordinary note. Unreadable data counts
    /// as no link, so a newer version's format never blocks reading a note.
    var integrationLink: NotebookIntegrationLink? {
        guard case .Object(let root, .Map)? = try? document.get(obj: .ROOT, key: Self.integrationKey),
              case .Scalar(.String(let connection))? = try? document.get(obj: root, key: "connection"),
              let connectionID = UUID(uuidString: connection),
              case .Scalar(.String(let item))? = try? document.get(obj: root, key: "item")
        else { return nil }
        return NotebookIntegrationLink(connection: connectionID, item: item)
    }

    /// The current text of each block this note shows, by block key. Copies
    /// that lost to another device's copy are not included.
    func integrationBlockTexts() throws -> [String: String] {
        let state = try IntegrationState(self)
        var result: [String: String] = [:]
        for (key, entry) in state.entries {
            guard let ranges = state.copies[key]?[entry.instance] else { continue }
            result[key] = ranges.map { state.slice($0) }.joined()
        }
        return result
    }

    /// Brings the note's integration blocks up to date with `blocks`, in
    /// that order, following the rules in docs/readwise-sync.md. Text that
    /// carries no integration mark is never deleted. Returns whether the
    /// note changed; a change is one Automerge change.
    @discardableResult
    func applyIntegration(
        _ blocks: [NotebookIntegrationBlock],
        link: NotebookIntegrationLink,
        at date: Date,
        message: String? = nil
    ) throws -> Bool {
        var seen = Set<String>()
        for block in blocks {
            guard Self.isValidBlockKey(block.key) else {
                throw NoteIntegrationError.invalidBlockKey(block.key)
            }
            guard seen.insert(block.key).inserted else {
                throw NoteIntegrationError.duplicateBlockKey(block.key)
            }
        }
        // An empty block is not written; a block that becomes empty is
        // removed like one the integration no longer has.
        let blocks = blocks.filter { !$0.text.isEmpty }
        let modifiedAt = try nextModifiedAt(date)
        var changed = try ensureIntegrationMap(link)
        let blocksObject = try integrationBlocksObject()

        // Copies that lost to the winning map value, and blocks the
        // integration no longer has, go first.
        if try removeStaleCopies() { changed = true }
        var state = try IntegrationState(self)
        let wanted = Set(blocks.map(\.key))
        for (key, entry) in state.entries.sorted(by: { $0.key < $1.key })
            where !wanted.contains(key)
        {
            _ = try removeCopy(key: key, instance: entry.instance)
            try document.delete(obj: blocksObject, key: key)
            changed = true
        }

        for (index, block) in blocks.enumerated() {
            state = try IntegrationState(self)
            let hash = Self.integrationHash(block.text)
            let entry = state.entries[block.key]
            if let entry, entry.hash == hash {
                if entry.conflicted {
                    // Writing the winner again settles the conflict.
                    try document.put(obj: blocksObject, key: block.key,
                                     value: .String(entry.value))
                    changed = true
                }
                guard block.key == NotebookIntegrationBlock.headerKey, entry.conflicted
                else { continue }
            }
            var instance = UUID().uuidString
            if block.key == NotebookIntegrationBlock.headerKey {
                instance = try writeHeader(
                    block.text, entry: entry, instance: instance, state: state)
            } else {
                var position: UInt64?
                if let entry, state.copies[block.key]?[entry.instance] != nil {
                    position = try removeCopy(key: block.key, instance: entry.instance)
                    state = try IntegrationState(self)
                }
                let at = try position ?? insertionPoint(
                    for: index, in: blocks, state: state)
                try insertHighlight(block, instance: instance, at: at)
            }
            let value = "\(instance)|\(hash)"
            try document.put(obj: blocksObject, key: block.key, value: .String(value))
            changed = true
        }

        guard changed else { return false }
        try setModifiedAt(modifiedAt)
        document.commitWith(message: message, timestamp: date)
        return true
    }

    /// Removes copies the note's map does not name: the losing copy when
    /// two devices wrote the same block, and typing that arrived late inside
    /// a copy that was already replaced. It only deletes integration text,
    /// so devices doing it at once agree. Returns whether anything changed.
    func removeStaleCopies() throws -> Bool {
        var changed = false
        let state = try IntegrationState(self)
        for (key, byInstance) in state.copies {
            let keep = state.entries[key]?.instance
            for instance in byInstance.keys.sorted() where instance != keep {
                _ = try removeCopy(key: key, instance: instance)
                changed = true
            }
        }
        return changed
    }

    /// Cleans up after an incoming change, as one Automerge change.
    func reconcileIntegrationCopies(at date: Date) throws -> Bool {
        guard integrationLink != nil else { return false }
        let modifiedAt = try nextModifiedAt(date)
        guard try removeStaleCopies() else { return false }
        try setModifiedAt(modifiedAt)
        document.commitWith(message: nil, timestamp: date)
        return true
    }

    static func integrationHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(16)
            .map { String(format: "%02x", $0) }.joined()
    }

    static func isValidBlockKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 128 && !key.contains("|")
            && !key.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
    }

    // MARK: - Writing

    private func ensureIntegrationMap(_ link: NotebookIntegrationLink) throws -> Bool {
        if let existing = integrationLink {
            guard existing == link else { throw NoteIntegrationError.linkedElsewhere }
            return false
        }
        if try document.get(obj: .ROOT, key: Self.integrationKey) != nil {
            throw NoteIntegrationError.linkedElsewhere
        }
        // Only the device that creates a note writes this, so two devices
        // never create competing maps.
        let root = try document.putObject(obj: .ROOT, key: Self.integrationKey, ty: .Map)
        try document.put(obj: root, key: "connection", value: .String(link.connection.uuidString))
        try document.put(obj: root, key: "item", value: .String(link.item))
        _ = try document.putObject(obj: root, key: "blocks", ty: .Map)
        return true
    }

    private func integrationBlocksObject() throws -> ObjId {
        guard case .Object(let root, .Map)? = try document.get(obj: .ROOT, key: Self.integrationKey),
              case .Object(let blocks, .Map)? = try document.get(obj: root, key: "blocks")
        else { throw NoteIntegrationError.notLinked }
        return blocks
    }

    /// Line breaks directly in front of the insertion point are swapped
    /// for the highlight's own blank line, so the visible text keeps its
    /// spacing. Line breaks that are part of integration text stay.
    private func insertHighlight(
        _ block: NotebookIntegrationBlock, instance: String, at insertion: UInt64
    ) throws {
        let state = try IntegrationState(self)
        let marked = state.copies.values.flatMap { $0.values.flatMap { $0 } }
        var position = insertion
        while insertion - position < Self.integrationLeadLength, position > 0,
              state.scalars[Int(position) - 1] == "\n",
              !marked.contains(where: { $0.contains(position - 1) })
        {
            position -= 1
        }
        if position < insertion {
            try document.spliceText(
                obj: textObject, start: position, delete: Int64(insertion - position))
        }
        let value = ScalarValue.String("\(block.key)|\(instance)")
        let length = UInt64(block.text.unicodeScalars.count)
        try document.spliceText(
            obj: textObject, start: position, delete: 0,
            value: Self.integrationLead + block.text)
        try document.mark(
            obj: textObject, start: position, end: position + Self.integrationLeadLength,
            expand: .none, name: Self.integrationLeadMarkPrefix + "\(block.key)|\(instance)",
            value: .Boolean(true))
        let start = position + Self.integrationLeadLength
        try document.mark(
            obj: textObject, start: start, end: start + length,
            expand: .none, name: Self.integrationMark, value: value)
    }

    /// The header stays at the very top, where frontmatter must start, so
    /// it is edited in place rather than inserted again. Returns the
    /// instance that marks it.
    private func writeHeader(
        _ text: String, entry: IntegrationState.Entry?, instance: String,
        state: IntegrationState
    ) throws -> String {
        let key = NotebookIntegrationBlock.headerKey
        let new = Array(text.unicodeScalars)
        let existing = entry.flatMap { state.copies[key]?[$0.instance] }
        if let existing, let first = existing.first, let last = existing.last {
            let span = first.lowerBound..<last.upperBound
            let old = state.scalars[Int(span.lowerBound)..<Int(span.upperBound)]
            let prefix = zip(old, new).prefix { $0 == $1 }.count
            let suffix = zip(old.dropFirst(prefix).reversed(), new.dropFirst(prefix).reversed())
                .prefix { $0 == $1 }.count
            let middle = String(String.UnicodeScalarView(new[prefix..<(new.count - suffix)]))
            try document.spliceText(
                obj: textObject, start: span.lowerBound + UInt64(prefix),
                delete: Int64(old.count - prefix - suffix), value: middle)
            let kept = entry!.instance
            if !new.isEmpty {
                try document.mark(
                    obj: textObject, start: span.lowerBound,
                    end: span.lowerBound + UInt64(new.count), expand: .none,
                    name: Self.integrationMark, value: .String("\(key)|\(kept)"))
            }
            return kept
        }
        let separated = state.scalars.first.map { $0 != "\n" } ?? false
        try document.spliceText(
            obj: textObject, start: 0, delete: 0,
            value: text + (separated ? Self.integrationLead : ""))
        if !new.isEmpty {
            try document.mark(
                obj: textObject, start: 0, end: UInt64(new.count), expand: .none,
                name: Self.integrationMark, value: .String("\(key)|\(instance)"))
        }
        return instance
    }

    /// Deletes one copy: its marked text, and its own blank line when that
    /// is still directly in front of it. Returns where the copy began.
    private func removeCopy(key: String, instance: String) throws -> UInt64? {
        let state = try IntegrationState(self)
        guard let ranges = state.copies[key]?[instance], let first = ranges.first else {
            return nil
        }
        let value = "\(key)|\(instance)"
        let leads = state.leads[value] ?? []
        var start = first.lowerBound
        while first.lowerBound - start < Self.integrationLeadLength, start > 0,
              state.scalars[Int(start) - 1] == "\n",
              leads.contains(where: { $0.lowerBound <= start - 1 && $0.upperBound >= start })
        {
            start -= 1
        }
        for range in ranges.dropFirst().reversed() {
            try document.spliceText(
                obj: textObject, start: range.lowerBound,
                delete: Int64(range.upperBound - range.lowerBound))
        }
        try document.spliceText(
            obj: textObject, start: start, delete: Int64(first.upperBound - start))
        return start
    }

    /// Directly after the nearest earlier block that is still in the note,
    /// else in front of the nearest later one, else at the end.
    private func insertionPoint(
        for index: Int, in blocks: [NotebookIntegrationBlock], state: IntegrationState
    ) throws -> UInt64 {
        for earlier in blocks[..<index].reversed() {
            if let ranges = state.shownRanges(earlier.key), let last = ranges.last {
                return last.upperBound
            }
        }
        for later in blocks[(index + 1)...] {
            if let ranges = state.shownRanges(later.key), let first = ranges.first {
                let value = "\(later.key)|\(state.entries[later.key]!.instance)"
                let leads = state.leads[value] ?? []
                var start = first.lowerBound
                while first.lowerBound - start < Self.integrationLeadLength, start > 0,
                      leads.contains(where: { $0.lowerBound <= start - 1 && $0.upperBound >= start })
                {
                    start -= 1
                }
                return start
            }
        }
        return UInt64(state.scalars.count)
    }
}

/// A snapshot of the marks and map entries in one note.
struct IntegrationState {
    struct Entry {
        let instance: String
        let hash: String
        let conflicted: Bool
        var value: String { "\(instance)|\(hash)" }
    }

    let scalars: [Unicode.Scalar]
    /// Block key → instance → marked ranges, in text order.
    let copies: [String: [String: [Range<UInt64>]]]
    /// Mark value → ranges of the blank lines in front of highlights.
    let leads: [String: [Range<UInt64>]]
    let entries: [String: Entry]

    init(_ note: NoteDocument) throws {
        let document = note.document
        // The note's text restores a leading byte order mark the binding
        // drops, so positions match Automerge's.
        let text = try note.text
        let scalars = Array(text.unicodeScalars)
        guard UInt64(scalars.count) == document.length(obj: note.textObject) else {
            throw NoteIntegrationError.unsupportedText
        }
        self.scalars = scalars
        var copies: [String: [String: [Range<UInt64>]]] = [:]
        var leads: [String: [Range<UInt64>]] = [:]
        for mark in try document.marks(obj: note.textObject) {
            guard mark.end > mark.start else { continue }
            let range = mark.start..<mark.end
            if mark.name.hasPrefix(NoteDocument.integrationLeadMarkPrefix),
               mark.value == .Boolean(true)
            {
                let value = String(mark.name.dropFirst(NoteDocument.integrationLeadMarkPrefix.count))
                leads[value, default: []].append(range)
            } else if mark.name == NoteDocument.integrationMark,
                      case .String(let value) = mark.value
            {
                let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                copies[parts[0], default: [:]][parts[1], default: []].append(range)
            }
        }
        self.copies = copies.mapValues { $0.mapValues { $0.sorted { $0.lowerBound < $1.lowerBound } } }
        self.leads = leads
        var entries: [String: Entry] = [:]
        if case .Object(let root, .Map)? = try document.get(obj: .ROOT, key: NoteDocument.integrationKey),
           case .Object(let blocks, .Map)? = try document.get(obj: root, key: "blocks")
        {
            for key in document.keys(obj: blocks) {
                guard case .Scalar(.String(let value))? = try document.get(obj: blocks, key: key)
                else { continue }
                let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let all = try document.getAll(obj: blocks, key: key)
                entries[key] = Entry(instance: parts[0], hash: parts[1], conflicted: all.count > 1)
            }
        }
        self.entries = entries
    }

    func slice(_ range: Range<UInt64>) -> String {
        String(String.UnicodeScalarView(scalars[Int(range.lowerBound)..<Int(range.upperBound)]))
    }

    /// The ranges of the copy the map names, when it is still in the note.
    func shownRanges(_ key: String) -> [Range<UInt64>]? {
        guard let entry = entries[key] else { return nil }
        return copies[key]?[entry.instance]
    }
}
