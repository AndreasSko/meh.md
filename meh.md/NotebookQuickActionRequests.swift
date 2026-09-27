#if os(iOS)
import Observation
import UIKit

@MainActor
@Observable
final class NotebookQuickActionRequests {
    static let shared = NotebookQuickActionRequests()
    static let newNoteType = "new-note"

    private(set) var pendingNewNotes = 0

    @discardableResult
    func receive(_ shortcutItem: UIApplicationShortcutItem) -> Bool {
        guard shortcutItem.type == Self.newNoteType else { return false }
        pendingNewNotes += 1
        return true
    }

    func takeNewNote() -> Bool {
        guard pendingNewNotes > 0 else { return false }
        pendingNewNotes -= 1
        return true
    }
}
#endif
