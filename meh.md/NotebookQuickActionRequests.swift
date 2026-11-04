import Foundation
import MehWidgetData
import Observation
#if os(iOS)
import UIKit
#endif

/// Requests from outside a notebook window: Home Screen quick actions and
/// widget taps. A widget tap belongs to the window that received its link;
/// the first ready window takes a quick action.
@MainActor
@Observable
final class NotebookQuickActionRequests {
    enum Action: Equatable {
        case newNote
        case newFromTemplate
        case openNote(UUID)
    }

    static let shared = NotebookQuickActionRequests()
    static let newNoteType = "new-note"
    static let newFromTemplateType = "new-from-template"

    private var pendingActions: [(action: Action, sceneID: UUID?)] = []

    var pendingActionCount: Int { pendingActions.count }

    #if os(iOS)
    @discardableResult
    func receive(_ shortcutItem: UIApplicationShortcutItem) -> Bool {
        let action: Action
        switch shortcutItem.type {
        case Self.newNoteType: action = .newNote
        case Self.newFromTemplateType: action = .newFromTemplate
        default: return false
        }
        pendingActions.append((action, nil))
        return true
    }
    #endif

    func receive(_ link: MehWidgetLink, in sceneID: UUID) {
        switch link {
        case .newNote: pendingActions.append((.newNote, sceneID))
        case .note(let id): pendingActions.append((.openNote(id), sceneID))
        }
    }

    func takeNextAction(for sceneID: UUID) -> Action? {
        guard let index = pendingActions.firstIndex(where: {
            $0.sceneID == nil || $0.sceneID == sceneID
        }) else { return nil }
        return pendingActions.remove(at: index).action
    }
}
