import SwiftUI

/// File actions of the focused notebook window. A nil action is unavailable
/// right now, e.g. Move and Move to Trash while the file browser is not
/// focused or nothing is selected.
struct NotebookFileActions {
    var newNote: (() -> Void)?
    var newFolder: (() -> Void)?
    var moveSelection: (() -> Void)?
    var trashSelection: (() -> Void)?
}

extension FocusedValues {
    @Entry var notebookFileActions: NotebookFileActions?
}

/// Puts the notebook's file actions in the menu bar, and in the iPad
/// keyboard shortcut overlay, like other document-based apps.
struct NotebookFileCommands: Commands {
    @FocusedValue(\.notebookFileActions) private var actions
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") { actions?.newNote?() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(actions?.newNote == nil)
            Button("New Folder") { actions?.newFolder?() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(actions?.newFolder == nil)
            if supportsMultipleWindows {
                Button("New Window") {
                    openWindow(id: "notebook", value: NotebookWindowValue())
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
            }
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            // Shortcuts are only attached while the browser can use them, so
            // Command-Delete keeps deleting text in the editor.
            if let move = actions?.moveSelection {
                Button("Move…", action: move)
                    .keyboardShortcut("m", modifiers: [.command, .shift])
            } else {
                Button("Move…") {}.disabled(true)
            }
            if let trash = actions?.trashSelection {
                Button("Move to Trash", action: trash)
                    .keyboardShortcut(.delete, modifiers: .command)
            } else {
                Button("Move to Trash") {}.disabled(true)
            }
        }
    }
}
