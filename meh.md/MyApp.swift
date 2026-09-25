import SwiftUI
import NoteCore

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
        .commands {
            NotebookSearchCommands()
            NotebookRecentCommands()
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
        .commands {
            NotebookSearchCommands()
            NotebookRecentCommands()
        }
        #endif
    }
}
