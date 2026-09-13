import Automerge
import Foundation

public enum NotebookItemKind: String, Codable, Sendable {
    case note, folder
}

public struct NotebookCatalogSnapshot: Equatable, Sendable {
    public let data: Data
    public let heads: Set<String>
    public let notebookID: UUID

    public init(data: Data, heads: Set<String>, notebookID: UUID) {
        self.data = data
        self.heads = heads
        self.notebookID = notebookID
    }
}

public enum NotebookCatalogError: Error, Equatable {
    case invalidDocument
    case unsupportedSchemaVersion
    case identityMismatch
    case disconnectedHistory
    case duplicateIdentity
    case itemNotFound
    case invalidParent
    case folderCycle
}

public enum NotebookPlacementIssue: String, Sendable {
    case missingParent, cycleRecovered, nameCollision
    case concurrentRename, concurrentMove
}

public struct NotebookItem: Equatable, Sendable {
    public let id: UUID
    public let kind: NotebookItemKind
    /// The winning stored name, preserved independently from collision display.
    public let name: String
    public let parentID: UUID?
    public let isTrashed: Bool
}

public struct NotebookPlacement: Equatable, Sendable {
    public let item: NotebookItem
    /// Parent within the same active/Trash tree. Stored ancestry remains on item.
    public let parentID: UUID?
    public let displayName: String
    public let isInTrash: Bool
    public let issues: Set<NotebookPlacementIssue>
}

enum NotebookLegacyMigration: Equatable {
    case pending
    case copying(noteID: UUID, heads: Set<String>)
    case empty
    case note(noteID: UUID, heads: Set<String>)
}

private struct NotebookLegacyMigrationReceipt: Codable {
    enum State: String, Codable {
        case copying, note
    }

    let state: State
    let noteID: UUID
    let heads: [String]
}

/// The catalog owns metadata only. Note bodies retain their existing documents.
/// Derived repairs never write back during merge, which would make outcomes
/// depend on the sequence in which remote records happened to arrive.
final class NotebookCatalogDocument {
    private let document: Document
    private let itemsObject: ObjId
    let notebookID: UUID

    var heads: Set<String> {
        Set(document.heads().map(\.debugDescription))
    }

    var historyHeads: Set<String> {
        Set(document.getHistory().map(\.debugDescription))
    }

    init(notebookID: UUID = UUID()) throws {
        let document = Document(textEncoding: .unicodeScalar)
        try document.put(obj: .ROOT, key: "kind", value: .String("notebookCatalog"))
        try document.put(obj: .ROOT, key: "schemaVersion", value: .Uint(1))
        try document.put(obj: .ROOT, key: "notebookID", value: .String(notebookID.uuidString))
        itemsObject = try document.putObject(obj: .ROOT, key: "items", ty: .Map)
        self.document = document
        self.notebookID = notebookID
    }

    convenience init(snapshot: NotebookCatalogSnapshot) throws {
        try self.init(serializedData: snapshot.data)
        guard notebookID == snapshot.notebookID, heads == snapshot.heads else {
            throw NotebookCatalogError.identityMismatch
        }
    }

    convenience init(serializedData: Data) throws {
        try self.init(validating: Document(serializedData))
    }

    private init(validating document: Document) throws {
        guard try document.getAll(obj: .ROOT, key: "schemaVersion") == [.Scalar(.Uint(1))] else {
            throw NotebookCatalogError.unsupportedSchemaVersion
        }
        guard try document.getAll(obj: .ROOT, key: "kind") == [.Scalar(.String("notebookCatalog"))],
            case .Scalar(.String(let identity)) = try document.get(obj: .ROOT, key: "notebookID"),
            let notebookID = UUID(uuidString: identity),
            try document.getAll(obj: .ROOT, key: "notebookID").count == 1,
            case .Object(let items, .Map) = try document.get(obj: .ROOT, key: "items"),
            try document.getAll(obj: .ROOT, key: "items").count == 1
        else {
            throw NotebookCatalogError.invalidDocument
        }
        self.document = document
        self.itemsObject = items
        self.notebookID = notebookID
        _ = try readItems()
        _ = try legacyMigration()
    }

    func legacyMigration() throws -> NotebookLegacyMigration {
        let values = try document.getAll(obj: .ROOT, key: "legacyMigration")
        if values.isEmpty { return .pending }
        guard values.count == 1, case .Scalar(.String(let value)) = values.first else {
            throw NotebookCatalogError.invalidDocument
        }
        if value == "empty" { return .empty }
        guard let data = value.data(using: .utf8),
            let receipt = try? JSONDecoder().decode(
                NotebookLegacyMigrationReceipt.self,
                from: data
            ),
            !receipt.heads.isEmpty,
            receipt.heads.allSatisfy({ !$0.isEmpty }),
            Set(receipt.heads).count == receipt.heads.count
        else {
            throw NotebookCatalogError.invalidDocument
        }
        let heads = Set(receipt.heads)
        switch receipt.state {
        case .copying:
            return .copying(noteID: receipt.noteID, heads: heads)
        case .note:
            guard
                try readItems().contains(where: {
                    $0.item.id == receipt.noteID && $0.item.kind == .note
                })
            else {
                throw NotebookCatalogError.invalidDocument
            }
            return .note(noteID: receipt.noteID, heads: heads)
        }
    }

    func beginLegacyMigration(noteID: UUID, heads: Set<String>) throws {
        guard try legacyMigration() == .pending, !heads.isEmpty else {
            throw NotebookCatalogError.invalidDocument
        }
        try writeLegacyMigrationReceipt(
            state: .copying,
            noteID: noteID,
            heads: heads
        )
    }

    func completeLegacyMigration(noteID: UUID?) throws {
        if let noteID {
            guard
                case .copying(let expectedID, let heads) =
                    try legacyMigration(),
                expectedID == noteID
            else {
                throw NotebookCatalogError.invalidDocument
            }
            guard try readItems().contains(where: { $0.item.id == noteID && $0.item.kind == .note })
            else {
                throw NotebookCatalogError.itemNotFound
            }
            try writeLegacyMigrationReceipt(
                state: .note,
                noteID: noteID,
                heads: heads
            )
        } else {
            guard try legacyMigration() == .pending else {
                throw NotebookCatalogError.invalidDocument
            }
            try document.put(
                obj: .ROOT,
                key: "legacyMigration",
                value: .String("empty")
            )
        }
    }

    private func writeLegacyMigrationReceipt(
        state: NotebookLegacyMigrationReceipt.State,
        noteID: UUID,
        heads: Set<String>
    ) throws {
        let receipt = NotebookLegacyMigrationReceipt(
            state: state,
            noteID: noteID,
            heads: heads.sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard
            let value = String(
                data: try encoder.encode(receipt),
                encoding: .utf8
            )
        else {
            throw NotebookCatalogError.invalidDocument
        }
        try document.put(
            obj: .ROOT,
            key: "legacyMigration",
            value: .String(value)
        )
    }

    func snapshot() -> NotebookCatalogSnapshot {
        NotebookCatalogSnapshot(data: document.save(), heads: heads, notebookID: notebookID)
    }

    func fork() throws -> NotebookCatalogDocument {
        try NotebookCatalogDocument(validating: document.fork())
    }

    func merge(_ other: NotebookCatalogDocument) throws {
        guard notebookID == other.notebookID else { throw NotebookCatalogError.identityMismatch }
        guard !historyHeads.isDisjoint(with: other.historyHeads) else {
            throw NotebookCatalogError.disconnectedHistory
        }
        // Validate on a branch first: a rejected merge cannot poison live state.
        let candidate = document.fork()
        try candidate.merge(other: other.document)
        _ = try NotebookCatalogDocument(validating: candidate)
        try document.merge(other: other.document)
    }

    @discardableResult
    func add(id: UUID = UUID(), kind: NotebookItemKind, name: String, parentID: UUID? = nil) throws
        -> UUID
    {
        try NotebookName.validate(name)
        guard try document.get(obj: itemsObject, key: id.uuidString) == nil else {
            throw NotebookCatalogError.duplicateIdentity
        }
        try validateParent(parentID, for: nil)
        let item = try document.putObject(obj: itemsObject, key: id.uuidString, ty: .Map)
        try document.put(obj: item, key: "kind", value: .String(kind.rawValue))
        try document.put(obj: item, key: "name", value: .String(name))
        try document.put(
            obj: item, key: "parent", value: parentID.map { .String($0.uuidString) } ?? .Null)
        try document.put(
            obj: item, key: "visibility", value: .String("active:\(UUID().uuidString)"))
        return id
    }

    func rename(_ id: UUID, to name: String) throws {
        try NotebookName.validate(name)
        try document.put(obj: object(for: id), key: "name", value: .String(name))
    }

    func move(_ id: UUID, to parentID: UUID?) throws {
        let object = try object(for: id)
        try validateParent(parentID, for: id)
        try document.put(
            obj: object, key: "parent", value: parentID.map { .String($0.uuidString) } ?? .Null)
    }

    func setTrashed(_ id: UUID, _ trashed: Bool) throws {
        // A distinct token records intent even if the visible state was already
        // true/false. getAll lets concurrent trash win over an unseen restore.
        let value = "\(trashed ? "trash" : "active"):\(UUID().uuidString)"
        try document.put(obj: object(for: id), key: "visibility", value: .String(value))
    }

    func items() throws -> [NotebookItem] { try readItems().map(\.item) }

    func placements() throws -> [NotebookPlacement] {
        let entries = try readItems()
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.item.id, $0.item) })
        var parents: [UUID: UUID] = [:]
        var issues = Dictionary(uniqueKeysWithValues: entries.map { ($0.item.id, $0.issues) })
        for entry in entries {
            let item = entry.item
            if let parent = item.parentID {
                if byID[parent]?.kind == .folder {
                    parents[item.id] = parent
                } else {
                    issues[item.id, default: []].insert(.missingParent)
                }
            }
        }
        var visited = Set<UUID>()
        for entry in entries {
            var path: [UUID] = []
            var offsets: [UUID: Int] = [:]
            var next: UUID? = entry.item.id
            while let id = next, !visited.contains(id) {
                if let start = offsets[id] {
                    let root = path[start...].min { $0.uuidString < $1.uuidString }!
                    parents[root] = nil
                    issues[root, default: []].insert(.cycleRecovered)
                    break
                }
                offsets[id] = path.count
                path.append(id)
                next = parents[id]
            }
            visited.formUnion(path)
        }
        var trash: [UUID: Bool] = [:]
        for entry in entries {
            var path: [UUID] = []
            var next: UUID? = entry.item.id
            var inherited = false
            while let id = next {
                if let cached = trash[id] {
                    inherited = cached
                    break
                }
                path.append(id)
                if byID[id]!.isTrashed {
                    inherited = true
                    break
                }
                next = parents[id]
            }
            for id in path.reversed() { trash[id] = inherited }
        }
        // An explicitly trashed item under an active parent becomes a Trash
        // root. Its stored parent is retained for restore. Descendants of a
        // trashed folder keep their hierarchy inside Trash.
        for entry in entries {
            let id = entry.item.id
            if trash[id] == true, let parent = parents[id], trash[parent] != true {
                parents[id] = nil
            }
        }
        // Reserve every original name before assigning suffixes. This prevents
        // a generated collision name from stealing another item's actual name.
        struct Group: Hashable {
            let parent: UUID?
            let inTrash: Bool
        }
        let groups = Dictionary(grouping: entries) {
            Group(parent: parents[$0.item.id], inTrash: trash[$0.item.id]!)
        }
        var names: [UUID: String] = [:]
        for siblings in groups.values {
            var reserved = Set(siblings.map { NotebookName.collisionKey($0.item.name) })
            var claimed = Set<String>()
            for entry in siblings {
                let item = entry.item
                let key = NotebookName.collisionKey(item.name)
                if claimed.insert(key).inserted {
                    names[item.id] = item.name
                    continue
                }
                issues[item.id, default: []].insert(.nameCollision)
                var suffix = 1
                var name = NotebookName.collisionName(item.name, id: item.id)
                while reserved.contains(NotebookName.collisionKey(name)) {
                    suffix += 1
                    name = NotebookName.collisionName(item.name, id: item.id, attempt: suffix)
                }
                reserved.insert(NotebookName.collisionKey(name))
                names[item.id] = name
            }
        }
        return entries.map {
            NotebookPlacement(
                item: $0.item, parentID: parents[$0.item.id],
                displayName: names[$0.item.id]!, isInTrash: trash[$0.item.id]!,
                issues: issues[$0.item.id]!)
        }
    }

    private func validateParent(_ parentID: UUID?, for id: UUID?) throws {
        guard let parentID else { return }
        let placements = try placements()
        let byID = Dictionary(uniqueKeysWithValues: placements.map { ($0.item.id, $0) })
        guard let parent = byID[parentID], parent.item.kind == .folder, !parent.isInTrash else {
            throw NotebookCatalogError.invalidParent
        }
        var next: UUID? = parentID
        while let current = next {
            if current == id { throw NotebookCatalogError.folderCycle }
            next = byID[current]?.parentID
        }
    }

    private func object(for id: UUID) throws -> ObjId {
        guard
            case .Object(let object, .Map) = try document.get(obj: itemsObject, key: id.uuidString)
        else {
            throw NotebookCatalogError.itemNotFound
        }
        return object
    }

    private func readItems() throws -> [(item: NotebookItem, issues: Set<NotebookPlacementIssue>)] {
        try document.keys(obj: itemsObject).sorted().map { key in
            guard let id = UUID(uuidString: key), key == id.uuidString,
                try document.getAll(obj: itemsObject, key: key).count == 1
            else {
                throw NotebookCatalogError.duplicateIdentity
            }
            let object = try object(for: id)
            guard case .Scalar(.String(let kindValue)) = try document.get(obj: object, key: "kind"),
                let kind = NotebookItemKind(rawValue: kindValue),
                try document.getAll(obj: object, key: "kind").count == 1
            else {
                throw NotebookCatalogError.invalidDocument
            }
            let names = try document.getAll(obj: object, key: "name")
            for value in names {
                guard case .Scalar(.String(let name)) = value else {
                    throw NotebookCatalogError.invalidDocument
                }
                do { try NotebookName.validate(name) } catch {
                    throw NotebookCatalogError.invalidDocument
                }
            }
            guard case .Scalar(.String(let name)) = try document.get(obj: object, key: "name")
            else {
                throw NotebookCatalogError.invalidDocument
            }
            let parentValues = try document.getAll(obj: object, key: "parent")
            for value in parentValues { _ = try decodeParent(value) }
            guard let parentValue = try document.get(obj: object, key: "parent") else {
                throw NotebookCatalogError.invalidDocument
            }
            let visibility = try document.getAll(obj: object, key: "visibility")
            guard !visibility.isEmpty else { throw NotebookCatalogError.invalidDocument }
            var trashed = false
            for value in visibility {
                guard case .Scalar(.String(let token)) = value else {
                    throw NotebookCatalogError.invalidDocument
                }
                let parts = token.split(separator: ":")
                guard parts.count == 2, ["active", "trash"].contains(parts[0]),
                    UUID(uuidString: String(parts[1])) != nil
                else {
                    throw NotebookCatalogError.invalidDocument
                }
                if parts[0] == "trash" { trashed = true }
            }
            var issues = Set<NotebookPlacementIssue>()
            if names.count > 1 { issues.insert(.concurrentRename) }
            if parentValues.count > 1 { issues.insert(.concurrentMove) }
            return (
                NotebookItem(
                    id: id, kind: kind, name: name,
                    parentID: try decodeParent(parentValue), isTrashed: trashed), issues
            )
        }
    }

    private func decodeParent(_ value: Value) throws -> UUID? {
        if case .Scalar(.Null) = value { return nil }
        if case .Scalar(.String(let text)) = value, let id = UUID(uuidString: text) { return id }
        throw NotebookCatalogError.invalidDocument
    }
}
