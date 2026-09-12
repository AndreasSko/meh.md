import SwiftUI
import NoteCore

@main struct MyApp: App {
    @State private var markdownCopy = MarkdownCopyController()
    @State private var session = NoteSession(
        storage: NoteFileStorage(
            directory: URL.applicationSupportDirectory
                .appending(path: "Notes", directoryHint: .isDirectory)
        )
    )

    var body: some Scene {
        #if os(macOS)
        Window("meh.md", id: "note") {
            ContentView(session: session, markdownCopy: markdownCopy)
        }
        #else
        WindowGroup {
            ContentView(session: session, markdownCopy: markdownCopy)
        }
        #endif
    }
}
