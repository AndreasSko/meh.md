import SwiftUI
import NoteCore
import TipKit

struct NotebookWindowValue: Codable, Hashable {
    let id: UUID
    let noteID: UUID?

    init(noteID: UUID? = nil) {
        id = UUID()
        self.noteID = noteID
    }
}

#if !SYNC_LAB
@main struct MyApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(NotebookAppDelegate.self)
    private var appDelegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(NotebookAppDelegate.self)
    private var appDelegate
    #endif

    @State private var workspace = NotebookWorkspace.shared

    init() {
        #if DEBUG
        // UI tests see tips only when a test asks for them.
        let environment = ProcessInfo.processInfo.environment
        if environment["MEH_SHOW_TIPS"] == "1" {
            try? Tips.resetDatastore()
        } else if environment["MEH_NOTEBOOK_PREVIEW"] == "1" {
            Tips.hideAllTipsForTesting()
        }
        #endif
        try? Tips.configure()
    }

    var body: some Scene {
        WindowGroup("meh.md", id: "notebook", for: NotebookWindowValue.self) { value in
            #if DEBUG
            if let launch = CloudKitSmokeLaunch.current {
                CloudKitSmokeCheckView(launch: launch)
            } else {
                NotebookApplicationView(
                    workspace: workspace,
                    preferredNoteID: value.wrappedValue.noteID
                )
            }
            #else
            NotebookApplicationView(
                workspace: workspace,
                preferredNoteID: value.wrappedValue.noteID
            )
            #endif
        } defaultValue: {
            NotebookWindowValue()
        }
        .commands {
            NotebookMenuCommands()
            #if os(macOS)
            NotebookFormatCommands()
            #endif
            NotebookSearchCommands()
            NotebookRecentCommands()
        }
        #if os(macOS)
        Settings {
            NotebookMacSettingsView(workspace: workspace)
        }
        #endif
    }
}
#endif

@MainActor @Observable final class NotebookMenuState {
    var newNoteRequest = 0
    var newFolderRequest = 0
    var newWindowRequest = 0
    var importRequest = 0
    var exportRequest = 0
    var moveRequest = 0
    var trashRequest = 0
    var canManageSelection = false
    var canExport = false
    var canOpenWindow = false
    var isAvailable = false
}

extension FocusedValues {
    @Entry var notebookMenu: NotebookMenuState?
}

struct NotebookMenuCommands: Commands {
    @FocusedValue(\.notebookMenu) private var menu

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") { menu?.newNoteRequest += 1 }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(menu?.isAvailable != true)
            Button("New Folder") { menu?.newFolderRequest += 1 }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(menu?.isAvailable != true)
            Button("New Window") { menu?.newWindowRequest += 1 }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(menu?.isAvailable != true || menu?.canOpenWindow != true)
            Divider()
            Button("Import Markdown…") { menu?.importRequest += 1 }
                .disabled(menu?.isAvailable != true)
            Button("Export All Notes…") { menu?.exportRequest += 1 }
                .disabled(menu?.isAvailable != true || menu?.canExport != true)
        }
        #if os(macOS)
        // iPad has no keyboard focus on the Files list, and ⌘⌫ has to keep
        // deleting text in the note.
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Move Selected…") { menu?.moveRequest += 1 }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(menu?.canManageSelection != true)
            Button("Move Selected to Trash") { menu?.trashRequest += 1 }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(menu?.canManageSelection != true)
        }
        #endif
    }
}

extension FocusedValues {
    @Entry var notebookEditor: MarkdownEditorNavigation?
}

#if os(macOS)
/// Markdown styles with their shortcuts in the Mac's Format menu, in place
/// of the system's rich-text font commands. The editor handles the keys
/// itself; the menu shows them. iPad lists them from the editor's titled
/// key commands instead.
struct NotebookFormatCommands: Commands {
    @FocusedValue(\.notebookEditor) private var editor

    var body: some Commands {
        CommandGroup(replacing: .textFormatting) {
            item("Bold", .bold, "b")
            item("Italic", .italic, "i")
            item("Strikethrough", .strikethrough, "x", [.command, .shift])
            item("Highlight", .highlight, "e", [.command, .shift])
            item("Inline Code", .inlineCode, "c", [.command, .shift])
            item("Link", .link, "k")
            Divider()
            item("Heading", .heading, "h", [.command, .shift])
            item("Task", .taskList)
            item("Check or Uncheck Task", .toggleTask, "t", [.command, .shift])
            // ⌘' needs Shift on many layouts, so Quote has no shortcut.
            item("Quote", .quote)
            item("Code Block", .codeBlock)
            item("Table", .insertTable)
        }
    }

    private func item(
        _ title: String, _ command: MarkdownEditingCommand,
        _ key: KeyEquivalent? = nil, _ modifiers: EventModifiers = .command
    ) -> some View {
        Button(title) {
            // Only while the note has keyboard focus, never behind a sheet
            // or while the Files list or a title field has it.
            guard let editor, editor.captureHasEditingFocus?() == true else { return }
            editor.performCommand?(command)
        }
        .keyboardShortcut(key.map { KeyboardShortcut($0, modifiers: modifiers) })
        .disabled(editor == nil)
    }
}
#endif
