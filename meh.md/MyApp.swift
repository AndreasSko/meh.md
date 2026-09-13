import SwiftUI
import NoteCore

@main struct MyApp: App {
    @State private var workspace = AppWorkspace()

    var body: some Scene {
        #if os(macOS)
        Window("meh.md", id: "note") {
            #if DEBUG
            if let launch = CloudKitSmokeLaunch.current {
                CloudKitSmokeCheckView(launch: launch)
            } else {
                WorkspaceView(workspace: workspace)
            }
            #else
            WorkspaceView(workspace: workspace)
            #endif
        }
        #else
        WindowGroup {
            #if DEBUG
            if let launch = CloudKitSmokeLaunch.current {
                CloudKitSmokeCheckView(launch: launch)
            } else {
                WorkspaceView(workspace: workspace)
            }
            #else
            WorkspaceView(workspace: workspace)
            #endif
        }
        #endif
    }
}
