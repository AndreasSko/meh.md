import Foundation

public enum NotebookBrowserChangeError: Error, Equatable, LocalizedError {
    case invalidSelection
    case invalidDestination
    case notebookIdentityMismatch
    case staleUndo
    case undoUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidSelection:
            "The selected notebook items can no longer be changed."
        case .invalidDestination:
            "The destination folder can no longer accept these items."
        case .notebookIdentityMismatch:
            "This undo operation belongs to another notebook."
        case .staleUndo:
            "These items changed elsewhere. Review them before trying again."
        case .undoUnavailable:
            "This change cannot be undone safely."
        }
    }
}

/// A scene-local recipe for a compensating catalog change.
///
/// It contains only the fields changed by the browser operation. Applying it
/// never rewinds catalog history or replaces note content and names.
public struct NotebookBrowserUndo: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case move
        case trash
    }

    public let action: Action
    public let itemIDs: [UUID]

    let notebookID: UUID
    let exactChanges: [NotebookBrowserRegisterChange]
    let visibilityChanges: [NotebookBrowserVisibilityChange]
    let expectedPlacementRevisions: [UUID: String]
}

struct NotebookBrowserRegisterChange: Equatable, Sendable {
    let itemID: UUID
    let key: String
    let before: NotebookBrowserRegisterState
    let after: NotebookBrowserRegisterState
}

struct NotebookBrowserVisibilityChange: Equatable, Sendable {
    let itemID: UUID
    let beforeTrashed: Bool
    let afterToken: String
}

struct NotebookBrowserRegisterState: Equatable, Sendable {
    enum Atom: Equatable, Sendable {
        case null
        case string(String)
    }

    let values: [Atom]

    var isRestorable: Bool { values.count <= 1 }
}
