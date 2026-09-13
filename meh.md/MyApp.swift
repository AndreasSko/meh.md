import SwiftUI
import NoteCore

@main struct MyApp: App {
    @State private var workspace = NotebookWorkspace(preview: NotebookWorkspace.isPreviewEnabled)

    var body: some Scene {
        #if os(macOS)
        Window("meh.md", id: "note") {
            #if DEBUG
            if let launch = CloudKitSmokeLaunch.current {
                CloudKitSmokeCheckView(launch: launch)
            } else {
                NotebookApplicationView(workspace: workspace)
            }
            #else
            NotebookApplicationView(workspace: workspace)
            #endif
        }
        #else
        WindowGroup {
            #if DEBUG
            if let launch = CloudKitSmokeLaunch.current {
                CloudKitSmokeCheckView(launch: launch)
            } else {
                NotebookApplicationView(workspace: workspace)
            }
            #else
            NotebookApplicationView(workspace: workspace)
            #endif
        }
        #endif
    }
}
