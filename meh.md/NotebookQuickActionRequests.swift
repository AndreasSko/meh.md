#if os(iOS)
import Observation
import UIKit

@MainActor
@Observable
final class NotebookQuickActionRequests {
    enum Action {
        case newNote
        case newFromTemplate
    }

    static let shared = NotebookQuickActionRequests()
    static let newNoteType = "new-note"
    static let newFromTemplateType = "new-from-template"

    private var pendingActions: [Action] = []

    var pendingActionCount: Int { pendingActions.count }

    @discardableResult
    func receive(_ shortcutItem: UIApplicationShortcutItem) -> Bool {
        let action: Action
        switch shortcutItem.type {
        case Self.newNoteType: action = .newNote
        case Self.newFromTemplateType: action = .newFromTemplate
        default: return false
        }
        pendingActions.append(action)
        return true
    }

    func takeNextAction() -> Action? {
        guard !pendingActions.isEmpty else { return nil }
        return pendingActions.removeFirst()
    }
}
#endif
