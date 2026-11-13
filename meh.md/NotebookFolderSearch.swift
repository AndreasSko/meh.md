import Foundation
import NoteCore

/// A folder offered as a shortcut in the Move sheet.
struct NotebookFolderShortcut: Identifiable, Equatable {
    let id: UUID
    let name: String
    /// The names of the folders above it, from Top Level down.
    let ancestors: [String]
}

enum NotebookFolderSearch {
    /// Folders whose name or path contains every word of the query, in
    /// Files order. Folders whose own name matches come first.
    static func matches(
        _ query: String, in placements: [NotebookPlacement],
        isAllowed: (UUID) -> Bool
    ) -> [NotebookFolderShortcut] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        var byName: [NotebookFolderShortcut] = []
        var byPath: [NotebookFolderShortcut] = []
        // Grouped once, so each keystroke reads the notebook only once.
        let folders = Dictionary(grouping: placements.filter {
            $0.item.kind == .folder && !$0.isInTrash
        }, by: \.parentID)
        func visit(_ parentID: UUID?, ancestors: [String]) {
            for placement in NotebookOrdering.orderedChildren(
                folders[parentID] ?? [], parentID: parentID, inTrash: false
            ) {
                let id = placement.item.id
                let name = placement.displayName
                if isAllowed(id) {
                    let path = ancestors + [name]
                    if words.allSatisfy({ word in
                        path.contains { $0.localizedStandardContains(word) }
                    }) {
                        let folder = NotebookFolderShortcut(
                            id: id, name: name, ancestors: ancestors)
                        if words.allSatisfy(name.localizedStandardContains) {
                            byName.append(folder)
                        } else {
                            byPath.append(folder)
                        }
                    }
                }
                visit(id, ancestors: ancestors + [name])
            }
        }
        visit(nil, ancestors: [])
        return byName + byPath
    }

    /// The folders from Top Level down to `id`, or nothing when it isn't an
    /// available folder or one above it is missing or in Trash.
    static func chain(to id: UUID?, in placements: [NotebookPlacement]) -> [UUID] {
        let byID = Dictionary(uniqueKeysWithValues: placements.map { ($0.item.id, $0) })
        var chain: [UUID] = []
        var next = id
        while let current = next, !chain.contains(current),
              let placement = byID[current], placement.item.kind == .folder,
              !placement.isInTrash, !placement.item.isPermanentlyDeleted {
            chain.insert(current, at: 0)
            next = placement.parentID
        }
        return next == nil ? chain : []
    }

    /// The given folders that still take the moved items, with their paths.
    static func shortcuts(
        for ids: [UUID], in placements: [NotebookPlacement],
        isAllowed: (UUID) -> Bool
    ) -> [NotebookFolderShortcut] {
        let byID = Dictionary(uniqueKeysWithValues: placements.map { ($0.item.id, $0) })
        return ids.compactMap { id in
            guard let placement = byID[id], placement.item.kind == .folder,
                  !placement.isInTrash, isAllowed(id) else { return nil }
            var ancestors: [String] = []
            var visited: Set<UUID> = [id]
            var parentID = placement.parentID
            while let current = parentID, visited.insert(current).inserted,
                  let parent = byID[current] {
                ancestors.insert(parent.displayName, at: 0)
                parentID = parent.parentID
            }
            return NotebookFolderShortcut(
                id: id, name: placement.displayName, ancestors: ancestors)
        }
    }
}
