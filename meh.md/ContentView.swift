import NoteCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    let session: NoteSession
    let markdownCopy: MarkdownCopyController
    @Environment(\.scenePhase) private var scenePhase
    @State private var choosingCopyFolder = false
    @State private var copySelectionError: String?
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
            Divider()
            markdownCopyStatus
                .font(.caption)
                .padding(.horizontal)
                .padding(.vertical, 8)
        }
        .task { await session.load() }
        .task { await markdownCopy.start() }
        .onChange(of: session.persistedSnapshot, initial: true) { _, snapshot in
            if let snapshot { markdownCopy.submit(snapshot) }
        }
        .onChange(of: markdownCopy.status) { _, status in
            if status == .current { copySelectionError = nil }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { markdownCopy.reconcileOnActivation() }
        }
        #if os(macOS)
        .fileImporter(
            isPresented: $choosingCopyFolder,
            allowedContentTypes: [.folder]
        ) { result in
            Task {
                do {
                    try await markdownCopy.chooseDirectory(result.get())
                    copySelectionError = nil
                } catch {
                    copySelectionError = error.localizedDescription
                }
            }
        }
        #endif
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
                if failure.current != .unsupportedSchemaVersion {
                    Button("Try Again") {
                        Task { await session.load() }
                    }
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

    private var markdownCopyStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(copyStatusLabel)
                Spacer()
                #if os(macOS)
                Button(markdownCopy.destinationURL == nil
                       ? "Choose Copy Folder…" : "Change Copy Folder…") {
                    copySelectionError = nil
                    choosingCopyFolder = true
                }
                .disabled(markdownCopy.isBusy)
                #else
                if copyNeedsNewDestination {
                    Button("Create New Copy") {
                        copySelectionError = nil
                        Task {
                            do {
                                try await markdownCopy.createNewCopy()
                                copySelectionError = nil
                            } catch {
                                copySelectionError = error.localizedDescription
                            }
                        }
                    }
                    .disabled(markdownCopy.isBusy)
                }
                #endif
                if copyCanRetry {
                    Button("Retry Copy") {
                        copySelectionError = nil
                        markdownCopy.retry()
                    }
                    .disabled(markdownCopy.isBusy)
                }
            }
            if let url = markdownCopy.destinationURL {
                #if os(macOS)
                Text(url.path).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                #else
                Text("Files: meh.md / \(copyRelativePath(url))")
                    .foregroundStyle(.secondary)
                #endif
                Text("Read-only copy. Edit in meh.md; outside changes are overwritten.")
                    .foregroundStyle(.secondary)
            }
            if copySelectionError != nil || copyCanRetry || copyNeedsNewDestination {
                Text(copySelectionError ?? markdownCopy.helpMessage)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("markdown-copy-status")
    }

    private var copyStatusLabel: String {
        switch markdownCopy.status {
        case .starting: "Opening Markdown copy…"
        case .notConfigured: "Choose where to keep a Markdown copy"
        case .idle: "Markdown copy waiting for saved text"
        case .updating: "Updating Markdown copy…"
        case .current: "Markdown copy up to date"
        case .paused: "Markdown copy paused"
        case .reconnectRequired: "Reconnect the Markdown copy folder"
        case .failed: "Markdown copy could not be updated"
        }
    }

    private var copyCanRetry: Bool {
        switch markdownCopy.status {
        case .failed, .reconnectRequired: true
        default: false
        }
    }

    private var copyNeedsNewDestination: Bool {
        switch markdownCopy.status {
        case .paused, .reconnectRequired: true
        default: false
        }
    }

    private func copyRelativePath(_ url: URL) -> String {
        let folder = url.deletingLastPathComponent().lastPathComponent
        return folder == "Documents"
            ? url.lastPathComponent : "\(folder)/\(url.lastPathComponent)"
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
