import SwiftUI
import NoteCore

@main struct MyApp: App {
    @State private var workspace = AppWorkspace()

    var body: some Scene {
        #if os(macOS)
        Window("meh.md", id: "note") {
            WorkspaceView(workspace: workspace)
        }
        #else
        WindowGroup {
            WorkspaceView(workspace: workspace)
        }
        #endif
    }
}
