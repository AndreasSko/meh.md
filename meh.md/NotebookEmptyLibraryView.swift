import SwiftUI

/// A first-run prompt for a notebook that has no active notes.
struct NotebookEmptyLibraryView: View {
    let onStartWriting: () -> Void
    let onImportMarkdown: () -> Void
    @Environment(\.mehPalette) private var palette

    var body: some View {
        ContentUnavailableView {
            Label {
                Text("Nothing here yet")
            } icon: {
                MehFace(mood: .neutral)
            }
        } description: {
            Text("Start a note, or import your Markdown files.")
        } actions: {
            Button("Start Writing", action: onStartWriting)
                .buttonStyle(.borderedProminent)
                .tint(palette.inkColor)
                .foregroundStyle(palette.onInkColor)
                .accessibilityIdentifier("notebook-start-writing")

            Button("Import Markdown", action: onImportMarkdown)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("notebook-empty-import")
        }
    }
}
