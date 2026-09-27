import SwiftUI
import NoteCore

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
            #if os(macOS)
            NotebookMenuCommands()
            #endif
            NotebookSearchCommands()
            NotebookRecentCommands()
        }
    }
}
#endif

#if os(macOS)
@MainActor @Observable final class NotebookMenuState {
    var newNoteRequest = 0
    var settingsRequest = 0
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
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { menu?.settingsRequest += 1 }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(menu?.isAvailable != true)
        }
    }
}
#endif
