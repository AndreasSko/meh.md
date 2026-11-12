import AppIntents
import SwiftUI
import WidgetKit

/// A button for Control Center, the Lock Screen, the Action button and the
/// Mac menu bar that opens the app with a new note.
struct NewNoteControl: ControlWidget {
    static let kind = "new-note"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: NewNoteIntent()) {
                Label("New Note", systemImage: "square.and.pencil")
            }
        }
        .displayName("New Note")
        .description("Opens meh.md with a new note.")
    }
}

extension NewNoteIntent {
    // The intent opens the app, which runs it there.
    static func openNewNote() async {}
}
