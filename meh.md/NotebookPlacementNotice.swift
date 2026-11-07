import Foundation
import NoteCore

/// What to tell someone about an item the catalog flagged, and the choices
/// that settle it. Each choice writes one value, which clears the flag on
/// every device.
struct NotebookPlacementNotice: Equatable {
    enum Kind: Equatable {
        /// Renamed on two devices at the same time.
        case names([String])
        /// Moved to different folders on two devices at the same time.
        case folders([UUID?])
        /// Folders moved into each other, so this one went to the top level.
        case folderLoop
        /// Its folder no longer exists, so it shows at the top level.
        case folderGone
        /// Another item in the same folder has the same name.
        case sameName
    }

    let kind: Kind
    let itemKind: NotebookItemKind
    /// The name or folder it shows now.
    let shownName: String
    let shownParentID: UUID?

    /// Nil when there is nothing to tell. Two devices reordering a folder
    /// at once isn't shown: no item is hidden, and moving one settles it.
    init?(_ placement: NotebookPlacement) {
        let issues = placement.issues
        let alternatives = placement.alternatives
        if issues.contains(.concurrentRename), alternatives.names.count > 1 {
            kind = .names(alternatives.names)
        } else if issues.contains(.concurrentMove), alternatives.parentIDs.count > 1 {
            kind = .folders(alternatives.parentIDs)
        } else if issues.contains(.cycleRecovered) {
            kind = .folderLoop
        } else if issues.contains(.missingParent) {
            kind = .folderGone
        } else if issues.contains(.nameCollision) {
            kind = .sameName
        } else {
            return nil
        }
        itemKind = placement.item.kind
        shownName = placement.item.name
        shownParentID = placement.item.parentID
    }

    /// The few words on the mark beside the item.
    var mark: String {
        switch kind {
        case .names(let names): "\(names.count) names"
        case .folders(let folders): "\(folders.count) places"
        case .folderLoop: "Moved out"
        case .folderGone: "Folder gone"
        case .sameName: "Same name"
        }
    }

    var symbol: String {
        switch kind {
        case .names, .folders: "arrow.triangle.branch"
        case .folderLoop: "arrow.triangle.2.circlepath"
        case .folderGone: "folder.badge.questionmark"
        case .sameName: "equal"
        }
    }

    var title: String {
        switch kind {
        case .names: "Two names for one \(noun)"
        case .folders: "Moved to two folders"
        case .folderLoop: "Folders moved into each other"
        case .folderGone: "Its folder is gone"
        case .sameName: "Two items with one name"
        }
    }

    var message: String {
        switch kind {
        case .names:
            "This \(noun) was renamed on two devices at the same time. Which name should it keep?"
        case .folders:
            "This \(noun) was moved on two devices at the same time. Where should it live?"
        case .folderLoop:
            "Two folders were moved into each other on two devices at the same time, "
                + "so this one was moved to the top level."
        case .folderGone:
            "The folder it was in was deleted on another device, so it shows at the top level for now."
        case .sameName:
            "Another item in this folder is called \u{201C}\(NotebookNoteName.title(from: shownName))\u{201D}. "
                + "Give this \(noun) a new name to tell them apart."
        }
    }

    private var noun: String { itemKind == .folder ? "folder" : "note" }

    /// One of the names or folders someone can keep.
    struct Choice: Equatable {
        enum Value: Hashable {
            case name(String)
            case parent(UUID?)
        }

        let value: Value
        let label: String
        let isShown: Bool
        /// A folder deleted or trashed since can't be chosen.
        let isAvailable: Bool
    }

    func choices(in placements: [NotebookPlacement]) -> [Choice] {
        switch kind {
        case .names(let names):
            return names.map {
                Choice(
                    value: .name($0),
                    label: itemKind == .note ? NotebookNoteName.title(from: $0) : $0,
                    isShown: $0 == shownName, isAvailable: true)
            }
        case .folders(let parents):
            return parents.map { parentID in
                let isShown = parentID == shownParentID
                guard let parentID else {
                    return Choice(
                        value: .parent(nil), label: "Top level", isShown: isShown,
                        isAvailable: true)
                }
                let folder = placements.first {
                    $0.item.id == parentID && $0.item.kind == .folder && !$0.isInTrash
                }
                return Choice(
                    value: .parent(parentID), label: folder?.displayName ?? "Deleted folder",
                    isShown: isShown, isAvailable: folder != nil)
            }
        case .folderLoop, .folderGone, .sameName:
            return []
        }
    }

    /// The choice to keep: the one picked while it's still offered, else
    /// the one shown now, else the first that can be chosen. Choices are
    /// matched by value, so sync changing them can't select another one.
    static func selection(_ picked: Choice.Value?, in choices: [Choice]) -> Choice? {
        let available = choices.filter(\.isAvailable)
        return available.first { $0.value == picked }
            ?? available.first(where: \.isShown) ?? available.first
    }
}

/// An item moved to two folders at the same time shows in one of them and
/// as a ghost in each other one that is open, so both places are visible.
struct NotebookGhost: Equatable {
    let placement: NotebookPlacement
    /// The folder the ghost shows in, nil for the top level.
    let parentID: UUID?
    let depth: Int
    /// The row the ghost goes before; the end of the list when it is past
    /// the last row.
    let index: Int

    /// Ghosts for the given visible rows. Each goes after the rows already
    /// in its folder; a folder that is closed or hidden shows none.
    static func ghosts(
        rows: [(id: UUID, depth: Int)],
        placements: [NotebookPlacement],
        expandedIDs: Set<UUID>
    ) -> [NotebookGhost] {
        var result: [NotebookGhost] = []
        for placement in placements where !placement.isInTrash {
            guard case .folders(let parents)? = NotebookPlacementNotice(placement)?.kind
            else { continue }
            for parentID in parents where parentID != placement.parentID {
                guard let parentID else {
                    // No rows means Files is collapsed.
                    guard !rows.isEmpty else { continue }
                    result.append(NotebookGhost(
                        placement: placement, parentID: nil, depth: 0, index: rows.count))
                    continue
                }
                guard expandedIDs.contains(parentID),
                      let folder = rows.firstIndex(where: { $0.id == parentID }) else { continue }
                let depth = rows[folder].depth
                let end = rows[(folder + 1)...].firstIndex { $0.depth <= depth } ?? rows.count
                result.append(NotebookGhost(
                    placement: placement, parentID: parentID, depth: depth + 1, index: end))
            }
        }
        return result
    }
}
