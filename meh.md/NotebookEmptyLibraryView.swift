import SwiftUI

/// A first-run prompt for a notebook that has no active notes.
struct NotebookEmptyLibraryView: View {
    let onStartWriting: () -> Void
    let onImportMarkdown: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Your library is empty", systemImage: "note.text")
        } description: {
            Text("Start a note, or import your Markdown files.")
        } actions: {
            Button("Start Writing", action: onStartWriting)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("notebook-start-writing")

            Button("Import Markdown", action: onImportMarkdown)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("notebook-empty-import")
        }
    }
}
