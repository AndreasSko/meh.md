import SwiftUI

/// A first-run prompt for a notebook that has no active notes.
struct NotebookEmptyLibraryView: View {
    let onStartWriting: () -> Void
    let onImportMarkdown: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label {
                Text("Your library is empty")
            } icon: {
                // The app icon's face, in place of a generic symbol.
                Text(verbatim: "•_•")
                    .font(.system(size: 44, weight: .bold, design: .monospaced))
                    .accessibilityHidden(true)
            }
        } description: {
            Text("Start a note, or import your Markdown files.")
        } actions: {
            Button("Start Writing", action: onStartWriting)
                .buttonStyle(.borderedProminent)
                .tint(MehStyle.inkColor)
                .foregroundStyle(MehStyle.onInkColor)
                .accessibilityIdentifier("notebook-start-writing")

            Button("Import Markdown", action: onImportMarkdown)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("notebook-empty-import")
        }
    }
}
