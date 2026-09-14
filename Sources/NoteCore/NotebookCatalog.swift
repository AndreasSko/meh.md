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
    case invalidOrder
    case orderSpaceExhausted
}

public enum NotebookPlacementIssue: String, Sendable {
    case missingParent, cycleRecovered, nameCollision
    case concurrentRename, concurrentMove, concurrentReorder
}

public struct NotebookItem: Equatable, Sendable {
    public let id: UUID
    public let kind: NotebookItemKind
    /// The winning stored name, preserved independently from collision display.
    public let name: String
    public let parentID: UUID?
    public let orderKey: NotebookOrderKey?
    public let isTrashed: Bool
    public let isPermanentlyDeleted: Bool
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
        try ensureOrder(parentID: parentID)
        let lower = try orderedChildren(parentID: parentID, inTrash: false)
            .filter { $0.item.parentID == parentID }
            .last?.item.orderKey
        let order = try NotebookOrderKeyFactory.between(
            lower, nil, itemID: id
        )
        let item = try document.putObject(obj: itemsObject, key: id.uuidString, ty: .Map)
        try document.put(obj: item, key: "kind", value: .String(kind.rawValue))
        try document.put(obj: item, key: "name", value: .String(name))
        try document.put(
            obj: item, key: "parent", value: parentID.map { .String($0.uuidString) } ?? .Null)
        try document.put(
            obj: item, key: "visibility", value: .String("active:\(UUID().uuidString)"))
        try writeOrder(order, parentID: parentID, object: item)
        return id
    }

    /// Builds an import on an isolated fork after validating the complete
    /// tree. This avoids recomputing placements after every inserted item.
    func forkAddingImportEntries(
        _ entries: [NotebookImportEntry]
    ) throws -> NotebookCatalogDocument {
        guard Set(entries.map(\.id)).count == entries.count else {
            throw NotebookImportError.invalidPlan
        }
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let existing = Set(try items().map(\.id))
        for entry in entries {
            guard !existing.contains(entry.id) else {
                throw NotebookImportError.identityConflict(entry.id)
            }
            do { try NotebookName.validate(entry.name) } catch {
                throw NotebookImportError.invalidPlan
            }
            switch entry.kind {
            case .folder where entry.text != nil:
                throw NotebookImportError.invalidPlan
            case .note where entry.text == nil:
                throw NotebookImportError.invalidPlan
            default:
                break
            }
            if let parentID = entry.parentID {
                guard let parent = byID[parentID], parent.kind == .folder else {
                    throw NotebookImportError.invalidPlan
                }
            }
            var seen: Set<UUID> = [entry.id]
            var parentID = entry.parentID
            while let id = parentID {
                guard seen.insert(id).inserted, let parent = byID[id] else {
                    throw NotebookImportError.invalidPlan
                }
                parentID = parent.parentID
            }
        }

        let candidate = try fork()
        try candidate.ensureOrder(parentID: nil)
        let rootLower = try candidate.orderedChildren(
            parentID: nil, inTrash: false
        ).filter { $0.item.parentID == nil }.last?.item.orderKey
        for entry in entries {
            let item = try candidate.document.putObject(
                obj: candidate.itemsObject,
                key: entry.id.uuidString,
                ty: .Map
            )
            try candidate.document.put(
                obj: item,
                key: "kind",
                value: .String(entry.kind.rawValue)
            )
            try candidate.document.put(
                obj: item,
                key: "name",
                value: .String(entry.name)
            )
            try candidate.document.put(
                obj: item,
                key: "parent",
                value: entry.parentID.map {
                    .String($0.uuidString)
                } ?? .Null
            )
            try candidate.document.put(
                obj: item,
                key: "visibility",
                value: .String("active:\(UUID().uuidString)")
            )
        }
        let importedByParent = Dictionary(grouping: entries, by: \.parentID)
        for (parentID, siblings) in importedByParent {
            let importedIDs = siblings.map(\.id)
            let ranks = try NotebookOrderKeyFactory.distribute(
                itemIDs: importedIDs,
                lower: parentID == nil ? rootLower : nil,
                upper: nil
            )
            for id in importedIDs {
                try candidate.writeOrder(
                    ranks[id]!,
                    parentID: parentID,
                    object: candidate.object(for: id)
                )
            }
        }
        _ = try NotebookCatalogDocument(snapshot: candidate.snapshot())
        return candidate
    }

    func rename(_ id: UUID, to name: String) throws {
        try NotebookName.validate(name)
        try document.put(obj: object(for: id), key: "name", value: .String(name))
    }

    func move(_ id: UUID, to parentID: UUID?) throws {
        let object = try object(for: id)
        try validateParent(parentID, for: id)
        try ensureOrder(parentID: parentID, excluding: id)
        let lower = try orderedChildren(parentID: parentID, inTrash: false)
            .filter { $0.item.parentID == parentID }
            .last { $0.item.id != id }?.item.orderKey
        let order = try NotebookOrderKeyFactory.between(
            lower, nil, itemID: id
        )
        try document.put(
            obj: object, key: "parent", value: parentID.map { .String($0.uuidString) } ?? .Null)
        try writeOrder(order, parentID: parentID, object: object)
        try writePlacementRevision(object: object)
    }

    /// Moves the normalized selection as one appended sibling block.
    /// Validation and rank generation happen on a fork, so a thrown error
    /// cannot leave any part of the receiving catalog changed.
    func moveItems(
        _ ids: [UUID],
        to parentID: UUID?
    ) throws -> NotebookBrowserUndo? {
        let roots = try normalizedActiveSelection(ids)
        try validateBatchMove(roots, to: parentID)

        let moving = Set(roots)
        let placements = try placements()
        let selected = Dictionary(
            uniqueKeysWithValues: placements
                .filter { moving.contains($0.item.id) }
                .map { ($0.item.id, $0) }
        )
        let current = try orderedChildren(
            parentID: parentID, inTrash: false
        ).filter { $0.item.parentID == parentID }
        let remaining = current.filter { !moving.contains($0.item.id) }
        let isUnconflictedNoOp = roots.allSatisfy { id in
            guard let placement = selected[id] else { return false }
            return placement.parentID == parentID
                && placement.item.parentID == parentID
                && !placement.issues.contains(.concurrentMove)
                && !placement.issues.contains(.concurrentReorder)
        } && current.map(\.item.id) == remaining.map(\.item.id) + roots
        if isUnconflictedNoOp { return nil }

        let parentKey = "parent"
        let destinationOrderKey = Self.orderStorageKey(parentID)
        let liveByID = Dictionary(
            uniqueKeysWithValues: try items()
                .filter { !$0.isPermanentlyDeleted }
                .map { ($0.id, $0) }
        )
        var before: [UUID: (NotebookBrowserRegisterState,
                            NotebookBrowserRegisterState)] = [:]
        var undoable = true
        for id in roots {
            let object = try object(for: id)
            let parentState = try registerState(object: object, key: parentKey)
            let orderState = try registerState(
                object: object, key: destinationOrderKey)
            undoable = undoable
                && parentState.isRestorable && orderState.isRestorable
                && hasRestorableAncestry(id, itemsByID: liveByID)
            before[id] = (parentState, orderState)
        }

        let candidate = try fork()
        try candidate.applyBatchMove(roots, to: parentID)
        _ = try NotebookCatalogDocument(snapshot: candidate.snapshot())

        var changes: [NotebookBrowserRegisterChange] = []
        var revisions: [UUID: String] = [:]
        if undoable {
            for id in roots {
                let object = try candidate.object(for: id)
                let prior = before[id]!
                changes.append(
                    NotebookBrowserRegisterChange(
                        itemID: id,
                        key: parentKey,
                        before: prior.0,
                        after: try candidate.registerState(
                            object: object, key: parentKey)
                    )
                )
                changes.append(
                    NotebookBrowserRegisterChange(
                        itemID: id,
                        key: destinationOrderKey,
                        before: prior.1,
                        after: try candidate.registerState(
                            object: object, key: destinationOrderKey)
                    )
                )
                revisions[id] = try candidate.singletonString(
                    object: object, key: "placementRevision")
            }
        }
        try document.merge(other: candidate.document)
        guard undoable else { return nil }
        return NotebookBrowserUndo(
            action: .move,
            itemIDs: roots,
            notebookID: notebookID,
            exactChanges: changes,
            visibilityChanges: [],
            expectedPlacementRevisions: revisions
        )
    }

    /// Repositions active siblings in the supplied order. Passing every child
    /// with `before == nil` establishes a complete one-time sorted order.
    func reorder(
        _ ids: [UUID],
        parentID: UUID?,
        before beforeID: UUID?
    ) throws {
        guard !ids.isEmpty else { return }
        guard Set(ids).count == ids.count else {
            throw NotebookCatalogError.invalidOrder
        }
        let initial = try orderedChildren(parentID: parentID, inTrash: false)
            .filter { $0.item.parentID == parentID }
        let initialIDs = initial.map(\.item.id)
        let initialSet = Set(initialIDs)
        let moving = Set(ids)
        guard moving.isSubset(of: initialSet),
              beforeID.map({ initialSet.contains($0) && !moving.contains($0) }) ?? true else {
            throw NotebookCatalogError.invalidOrder
        }

        try ensureOrder(parentID: parentID)
        let ordered = try orderedChildren(parentID: parentID, inTrash: false)
            .filter { $0.item.parentID == parentID }
        let remaining = ordered.filter { !moving.contains($0.item.id) }
        let insertionIndex: Int
        if let beforeID {
            guard let index = remaining.firstIndex(where: { $0.item.id == beforeID }) else {
                throw NotebookCatalogError.invalidOrder
            }
            insertionIndex = index
        } else {
            insertionIndex = remaining.endIndex
        }
        let lower = insertionIndex > remaining.startIndex
            ? remaining[remaining.index(before: insertionIndex)].item.orderKey
            : nil
        let upper = insertionIndex < remaining.endIndex
            ? remaining[insertionIndex].item.orderKey
            : nil
        let ranks = try NotebookOrderKeyFactory.distribute(
            itemIDs: ids, lower: lower, upper: upper
        )
        for id in ids {
            try writeOrder(
                ranks[id]!, parentID: parentID, object: object(for: id)
            )
            try writePlacementRevision(object: object(for: id))
        }
    }

    func orderedChildren(
        parentID: UUID?,
        inTrash: Bool
    ) throws -> [NotebookPlacement] {
        NotebookOrdering.orderedChildren(
            try placements(), parentID: parentID, inTrash: inTrash
        )
    }

    func setTrashed(_ id: UUID, _ trashed: Bool) throws {
        // A distinct token records intent even if the visible state was already
        // true/false. getAll lets concurrent trash win over an unseen restore.
        let value = "\(trashed ? "trash" : "active"):\(UUID().uuidString)"
        try document.put(obj: object(for: id), key: "visibility", value: .String(value))
    }

    /// Trashes only the roots of the normalized selection. Descendants follow
    /// through derived visibility and keep their own independent intent.
    func trashItems(_ ids: [UUID]) throws -> NotebookBrowserUndo {
        let roots = try normalizedActiveSelection(ids)
        let candidate = try fork()
        var changes: [NotebookBrowserVisibilityChange] = []
        for id in roots {
            let token = "trash:\(UUID().uuidString)"
            try candidate.document.put(
                obj: candidate.object(for: id),
                key: "visibility",
                value: .String(token)
            )
            changes.append(
                NotebookBrowserVisibilityChange(
                    itemID: id, beforeTrashed: false, afterToken: token)
            )
        }
        _ = try NotebookCatalogDocument(snapshot: candidate.snapshot())
        try document.merge(other: candidate.document)
        return NotebookBrowserUndo(
            action: .trash,
            itemIDs: roots,
            notebookID: notebookID,
            exactChanges: [],
            visibilityChanges: changes,
            expectedPlacementRevisions: [:]
        )
    }

    /// Applies a guarded compensating change and returns its inverse for redo.
    func undoBrowserChange(
        _ receipt: NotebookBrowserUndo
    ) throws -> NotebookBrowserUndo {
        guard receipt.notebookID == notebookID else {
            throw NotebookBrowserChangeError.notebookIdentityMismatch
        }
        let candidate = try fork()
        try candidate.validateUndo(receipt)

        var inverseExact: [NotebookBrowserRegisterChange] = []
        for change in receipt.exactChanges {
            let object = try candidate.object(for: change.itemID)
            try candidate.writeRegisterState(
                change.before, object: object, key: change.key)
            inverseExact.append(
                NotebookBrowserRegisterChange(
                    itemID: change.itemID,
                    key: change.key,
                    before: change.after,
                    after: try candidate.registerState(
                        object: object, key: change.key)
                )
            )
        }

        var inverseVisibility: [NotebookBrowserVisibilityChange] = []
        for change in receipt.visibilityChanges {
            let token = "\(change.beforeTrashed ? "trash" : "active"):\(UUID().uuidString)"
            try candidate.document.put(
                obj: candidate.object(for: change.itemID),
                key: "visibility",
                value: .String(token)
            )
            inverseVisibility.append(
                NotebookBrowserVisibilityChange(
                    itemID: change.itemID,
                    beforeTrashed: !change.beforeTrashed,
                    afterToken: token
                )
            )
        }

        var inverseRevisions: [UUID: String] = [:]
        for id in receipt.expectedPlacementRevisions.keys {
            let object = try candidate.object(for: id)
            let token = try candidate.writePlacementRevision(object: object)
            inverseRevisions[id] = token
        }
        _ = try NotebookCatalogDocument(snapshot: candidate.snapshot())
        try document.merge(other: candidate.document)
        return NotebookBrowserUndo(
            action: receipt.action,
            itemIDs: receipt.itemIDs,
            notebookID: notebookID,
            exactChanges: inverseExact,
            visibilityChanges: inverseVisibility,
            expectedPlacementRevisions: inverseRevisions
        )
    }

    /// Only the explicitly confirmed identities are marked; unknown children
    /// received later survive in a recovery placement. Cleanup is separate.
    func markPermanentlyDeleted(_ ids: Set<UUID>) throws {
        let objects = try ids.map { try object(for: $0) }
        for object in objects {
            try document.put(obj: object, key: "permanentlyDeleted", value: .Boolean(true))
        }
    }

    func items() throws -> [NotebookItem] { try readItems().map(\.item) }

    func placements() throws -> [NotebookPlacement] {
        let entries = try readItems().filter { !$0.item.isPermanentlyDeleted }
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
            let parentID = try decodeParent(parentValue)
            let order = try readOrder(object: object, parentID: parentID)
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
            let deleted = try document.getAll(obj: object, key: "permanentlyDeleted")
            guard deleted.allSatisfy({ $0 == .Scalar(.Boolean(true)) }) else {
                throw NotebookCatalogError.invalidDocument
            }
            for value in try document.getAll(
                obj: object, key: "placementRevision"
            ) {
                guard case .Scalar(.String(let token)) = value,
                      let revision = UUID(uuidString: token),
                      revision.uuidString == token else {
                    throw NotebookCatalogError.invalidDocument
                }
            }
            var issues = Set<NotebookPlacementIssue>()
            if names.count > 1 { issues.insert(.concurrentRename) }
            if parentValues.count > 1 { issues.insert(.concurrentMove) }
            if order.hasExplicitConflict {
                issues.insert(.concurrentReorder)
            }
            return (
                NotebookItem(
                    id: id, kind: kind, name: name,
                    parentID: parentID, orderKey: order.key, isTrashed: trashed,
                    isPermanentlyDeleted: !deleted.isEmpty), issues
            )
        }
    }

    private func decodeParent(_ value: Value) throws -> UUID? {
        if case .Scalar(.Null) = value { return nil }
        if case .Scalar(.String(let text)) = value, let id = UUID(uuidString: text) { return id }
        throw NotebookCatalogError.invalidDocument
    }

    private func ensureOrder(
        parentID: UUID?,
        excluding excludedID: UUID? = nil
    ) throws {
        try ensureOrder(
            parentID: parentID,
            excluding: excludedID.map { [$0] } ?? []
        )
    }

    private func ensureOrder(
        parentID: UUID?,
        excluding excludedIDs: Set<UUID>
    ) throws {
        let children = try orderedChildren(parentID: parentID, inTrash: false)
            .filter {
                $0.item.parentID == parentID
                    && !excludedIDs.contains($0.item.id)
            }
        let ids = children.filter { $0.item.orderKey == nil }.map(\.item.id)
        guard !ids.isEmpty else { return }
        let lower = children.last { $0.item.orderKey != nil }?.item.orderKey
        let ranks = try NotebookOrderKeyFactory.distribute(
            itemIDs: ids, lower: lower, upper: nil
        )
        for id in ids {
            try writeOrderSeed(
                ranks[id]!, parentID: parentID, object: object(for: id)
            )
        }
    }

    private func readOrder(
        object: ObjId,
        parentID: UUID?
    ) throws -> (key: NotebookOrderKey?, hasExplicitConflict: Bool) {
        for key in document.keys(obj: object)
        where key.hasPrefix("order:") || key.hasPrefix("orderSeed:") {
            guard Self.decodeOrderParent(key) != nil else {
                throw NotebookCatalogError.invalidDocument
            }
            for value in try document.getAll(obj: object, key: key) {
                guard case .Scalar(.String(let rawValue)) = value,
                      NotebookOrderKey(rawValue: rawValue) != nil else {
                    throw NotebookCatalogError.invalidDocument
                }
            }
        }
        let explicitKey = Self.orderStorageKey(parentID)
        let explicit = try document.getAll(obj: object, key: explicitKey)
        if !explicit.isEmpty {
            guard case .Scalar(.String(let rawValue)) = try document.get(
                obj: object, key: explicitKey
            ), let order = NotebookOrderKey(rawValue: rawValue) else {
                throw NotebookCatalogError.invalidDocument
            }
            return (order, explicit.count > 1)
        }
        let seedKey = Self.orderSeedStorageKey(parentID)
        let seeds = try document.getAll(obj: object, key: seedKey)
        guard !seeds.isEmpty else { return (nil, false) }
        guard case .Scalar(.String(let rawValue)) = try document.get(
            obj: object, key: seedKey
        ), let order = NotebookOrderKey(rawValue: rawValue) else {
            throw NotebookCatalogError.invalidDocument
        }
        return (order, false)
    }

    private func writeOrder(
        _ order: NotebookOrderKey,
        parentID: UUID?,
        object: ObjId
    ) throws {
        try document.put(
            obj: object,
            key: Self.orderStorageKey(parentID),
            value: .String(order.rawValue)
        )
    }

    private func writeOrderSeed(
        _ order: NotebookOrderKey,
        parentID: UUID?,
        object: ObjId
    ) throws {
        try document.put(
            obj: object,
            key: Self.orderSeedStorageKey(parentID),
            value: .String(order.rawValue)
        )
    }

    @discardableResult
    private func writePlacementRevision(object: ObjId) throws -> String {
        let token = UUID().uuidString
        try document.put(
            obj: object,
            key: "placementRevision",
            value: .String(token)
        )
        return token
    }

    private func normalizedActiveSelection(_ ids: [UUID]) throws -> [UUID] {
        guard !ids.isEmpty else {
            throw NotebookBrowserChangeError.invalidSelection
        }
        var unique: [UUID] = []
        var supplied = Set<UUID>()
        for id in ids where supplied.insert(id).inserted { unique.append(id) }
        let placements = try placements()
        let byID = Dictionary(
            uniqueKeysWithValues: placements.map { ($0.item.id, $0) }
        )
        guard unique.allSatisfy({ byID[$0]?.isInTrash == false }) else {
            throw NotebookBrowserChangeError.invalidSelection
        }
        return unique.filter { id in
            var parent = byID[id]?.parentID
            while let candidate = parent {
                if supplied.contains(candidate) { return false }
                parent = byID[candidate]?.parentID
            }
            return true
        }
    }

    private func validateBatchMove(
        _ ids: [UUID],
        to parentID: UUID?
    ) throws {
        let placements = try placements()
        let byID = Dictionary(
            uniqueKeysWithValues: placements.map { ($0.item.id, $0) }
        )
        if let parentID {
            guard let destination = byID[parentID],
                  destination.item.kind == .folder,
                  !destination.isInTrash else {
                throw NotebookBrowserChangeError.invalidDestination
            }
        }
        var parents = Dictionary(
            uniqueKeysWithValues: placements.map { ($0.item.id, $0.parentID) }
        )
        for id in ids { parents[id] = .some(parentID) }
        for id in parents.keys {
            var seen = Set<UUID>()
            var next: UUID? = id
            while let current = next {
                guard seen.insert(current).inserted,
                      parents.keys.contains(current) else {
                    throw NotebookBrowserChangeError.invalidDestination
                }
                next = parents[current] ?? nil
            }
        }
    }

    private func applyBatchMove(
        _ ids: [UUID],
        to parentID: UUID?
    ) throws {
        let moving = Set(ids)
        let byID = Dictionary(
            uniqueKeysWithValues: try items().map { ($0.id, $0) }
        )
        var sourceParents = Set<UUID?>()
        for id in ids {
            guard let item = byID[id] else {
                throw NotebookBrowserChangeError.invalidSelection
            }
            sourceParents.insert(item.parentID)
        }
        for sourceParent in sourceParents {
            // Keep an effective source rank on each moved legacy item. Undoing
            // can then reveal the original relative position without rewriting
            // unrelated source siblings.
            try ensureOrder(parentID: sourceParent)
        }
        try ensureOrder(parentID: parentID, excluding: moving)
        let remaining = try orderedChildren(
            parentID: parentID, inTrash: false
        ).filter {
            $0.item.parentID == parentID && !moving.contains($0.item.id)
        }
        let ranks = try NotebookOrderKeyFactory.distribute(
            itemIDs: ids,
            lower: remaining.last?.item.orderKey,
            upper: nil
        )
        for id in ids {
            let object = try object(for: id)
            try document.put(
                obj: object,
                key: "parent",
                value: parentID.map { .String($0.uuidString) } ?? .Null
            )
            try writeOrder(ranks[id]!, parentID: parentID, object: object)
            try writePlacementRevision(object: object)
        }
    }

    private func registerState(
        object: ObjId,
        key: String
    ) throws -> NotebookBrowserRegisterState {
        let atoms = try document.getAll(obj: object, key: key).map { value in
            switch value {
            case .Scalar(.Null):
                return NotebookBrowserRegisterState.Atom.null
            case .Scalar(.String(let text)):
                return NotebookBrowserRegisterState.Atom.string(text)
            default:
                throw NotebookCatalogError.invalidDocument
            }
        }.sorted { left, right in
            func key(_ atom: NotebookBrowserRegisterState.Atom) -> String {
                switch atom {
                case .null: "0"
                case .string(let text): "1" + text
                }
            }
            return key(left) < key(right)
        }
        return NotebookBrowserRegisterState(values: atoms)
    }

    private func writeRegisterState(
        _ state: NotebookBrowserRegisterState,
        object: ObjId,
        key: String
    ) throws {
        guard state.isRestorable else {
            throw NotebookBrowserChangeError.undoUnavailable
        }
        guard let value = state.values.first else {
            try document.delete(obj: object, key: key)
            return
        }
        switch value {
        case .null:
            try document.put(obj: object, key: key, value: .Null)
        case .string(let text):
            try document.put(obj: object, key: key, value: .String(text))
        }
    }

    private func singletonString(object: ObjId, key: String) throws -> String {
        let values = try document.getAll(obj: object, key: key)
        guard values.count == 1,
              case .Scalar(.String(let value)) = values.first else {
            throw NotebookCatalogError.invalidDocument
        }
        return value
    }

    private func validateUndo(_ receipt: NotebookBrowserUndo) throws {
        guard !receipt.itemIDs.isEmpty else {
            throw NotebookBrowserChangeError.staleUndo
        }
        let live = Dictionary(
            uniqueKeysWithValues: try items().map { ($0.id, $0) }
        )
        guard receipt.itemIDs.allSatisfy({
            live[$0]?.isPermanentlyDeleted == false
        }) else {
            throw NotebookBrowserChangeError.staleUndo
        }
        do {
            for change in receipt.exactChanges {
                let object = try object(for: change.itemID)
                guard change.before.isRestorable,
                      try registerState(object: object, key: change.key)
                        == change.after else {
                    throw NotebookBrowserChangeError.staleUndo
                }
            }
            for change in receipt.visibilityChanges {
                let object = try object(for: change.itemID)
                let expected = NotebookBrowserRegisterState(
                    values: [.string(change.afterToken)]
                )
                guard try registerState(object: object, key: "visibility")
                    == expected else {
                    throw NotebookBrowserChangeError.staleUndo
                }
            }
            for (id, revision) in receipt.expectedPlacementRevisions {
                guard try singletonString(
                    object: object(for: id), key: "placementRevision"
                ) == revision else {
                    throw NotebookBrowserChangeError.staleUndo
                }
            }
            try validateProspectiveUndoGraph(receipt)
        } catch is NotebookBrowserChangeError {
            throw NotebookBrowserChangeError.staleUndo
        } catch {
            throw NotebookBrowserChangeError.staleUndo
        }
    }

    private func validateProspectiveUndoGraph(
        _ receipt: NotebookBrowserUndo
    ) throws {
        let parentChanges = receipt.exactChanges.filter { $0.key == "parent" }
        // Visibility compensation intentionally preserves surrounding Trash
        // and recovery state. Only a move changes ancestry.
        guard !parentChanges.isEmpty else { return }
        let liveItems = try items().filter { !$0.isPermanentlyDeleted }
        let byID = Dictionary(
            uniqueKeysWithValues: liveItems.map { ($0.id, $0) }
        )
        var parents = Dictionary(
            uniqueKeysWithValues: liveItems.map { ($0.id, $0.parentID) }
        )
        for change in parentChanges {
            guard change.before.values.count == 1 else {
                throw NotebookBrowserChangeError.staleUndo
            }
            let parentID: UUID?
            switch change.before.values[0] {
            case .null:
                parentID = nil
            case .string(let value):
                guard let id = UUID(uuidString: value),
                      id.uuidString == value else {
                    throw NotebookBrowserChangeError.staleUndo
                }
                parentID = id
            }
            parents[change.itemID] = .some(parentID)
        }

        for change in parentChanges {
            var seen = Set<UUID>()
            var next: UUID? = change.itemID
            var isSelectedRoot = true
            while let current = next {
                guard seen.insert(current).inserted,
                      let item = byID[current] else {
                    throw NotebookBrowserChangeError.staleUndo
                }
                if !isSelectedRoot {
                    guard item.kind == .folder, !item.isTrashed else {
                        throw NotebookBrowserChangeError.staleUndo
                    }
                }
                isSelectedRoot = false
                next = parents[current] ?? nil
            }
        }
    }

    private func hasRestorableAncestry(
        _ id: UUID,
        itemsByID: [UUID: NotebookItem]
    ) -> Bool {
        var seen = Set<UUID>()
        var next: UUID? = id
        var isSelectedRoot = true
        while let current = next {
            guard seen.insert(current).inserted,
                  let item = itemsByID[current] else {
                return false
            }
            if !isSelectedRoot,
               item.kind != .folder || item.isTrashed {
                return false
            }
            isSelectedRoot = false
            next = item.parentID
        }
        return true
    }

    private static func orderStorageKey(_ parentID: UUID?) -> String {
        "order:" + (parentID?.uuidString ?? "root")
    }

    private static func orderSeedStorageKey(_ parentID: UUID?) -> String {
        "orderSeed:" + (parentID?.uuidString ?? "root")
    }

    /// A non-nil return means the storage-key suffix is valid. The outer
    /// optional distinguishes an invalid suffix from the valid root scope.
    private static func decodeOrderParent(_ key: String) -> UUID?? {
        let prefix = key.hasPrefix("orderSeed:") ? "orderSeed:" : "order:"
        let suffix = String(key.dropFirst(prefix.count))
        if suffix == "root" { return .some(nil) }
        guard let id = UUID(uuidString: suffix), suffix == id.uuidString else {
            return nil
        }
        return .some(id)
    }
}
