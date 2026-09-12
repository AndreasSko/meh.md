import NoteCore
import SwiftUI

struct ContentView: View {
    let session: NoteSession
    @State private var editError: String?
    @State private var unrecordedText: String?

    var body: some View {
        VStack(spacing: 0) {
            if session.isEditingEnabled {
                MarkdownEditor(text: Binding(
                    get: { unrecordedText ?? session.text },
                    set: { newText in
                        do {
                            try session.replaceAll(with: newText)
                            unrecordedText = nil
                            editError = nil
                        } catch {
                            unrecordedText = newText
                            editError = error.localizedDescription
                        }
                    }
                ))
            } else {
                unavailableContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            if let editError {
                Text("An edit could not be recorded: \(editError)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding()
            }
            Group {
                if unrecordedText != nil {
                    Text("Unsaved changes — keep this note open.")
                } else {
                    saveStatus
                }
            }
                .font(.caption)
                .padding(.horizontal)
                .padding(.vertical, 8)
        }
        .task { await session.load() }
    }

    @ViewBuilder
    private var unavailableContent: some View {
        switch session.status {
        case .recoveryRequired:
            VStack(spacing: 12) {
                Text("The latest saved note could not be opened.")
                    .font(.headline)
                Text("A previous saved copy is available. Restoring it may lose newer edits. The damaged file will be kept.")
                    .multilineTextAlignment(.center)
                Button("Restore Previous Copy") {
                    Task { await session.recoverFromPrevious() }
                }
                if let message = session.recoveryErrorMessage {
                    Text(message).foregroundStyle(.red)
                }
            }
            .padding()
        case .loadFailed(let message):
            VStack(spacing: 12) {
                Text("Your note could not be opened.").font(.headline)
                Text(message).multilineTextAlignment(.center)
                Button("Try Again") {
                    Task { await session.load() }
                }
            }
            .padding()
        case .blocked(let failure):
            VStack(spacing: 12) {
                Text("Your note could not be opened.")
                    .font(.headline)
                Text(failure.current == .unsupportedSchemaVersion
                     ? "This note requires a newer version of meh.md."
                     : "The saved files are unavailable or damaged. They have been kept for recovery.")
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    Task { await session.load() }
                }
            }
            .padding()
        default:
            ProgressView("Opening note…")
        }
    }

    @ViewBuilder
    private var saveStatus: some View {
        HStack {
            switch session.status {
            case .saved:
                Label("Saved on this device", systemImage: "checkmark")
            case .saving:
                Text("Saving…")
            case .saveFailed(let message):
                VStack(alignment: .leading, spacing: 4) {
                    Text("Couldn’t save. Your edits are still open.")
                    Text(message).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Retry") { session.retrySave() }
            case .loading:
                Text("Opening…")
            case .recoveryRequired:
                Text("Recovery needed")
            case .blocked, .loadFailed:
                Text("Note unavailable")
            }
            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("note-save-status")
    }
}

#Preview {
    MarkdownEditor(text: .constant("""
    # A quieter place to write

    The Markdown stays **visible**, including _emphasis_, `code`, and
    [links](https://example.com).

    - Write on Mac
    - Keep every character: café, naïve, 👋🏽
    """))
}
