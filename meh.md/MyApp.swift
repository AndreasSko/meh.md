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
            NotebookSearchCommands()
            NotebookRecentCommands()
        }
    }
}
