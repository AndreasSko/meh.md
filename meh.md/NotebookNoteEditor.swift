import NoteCore
import SwiftUI

struct NotebookNoteEditor: View {
    let session: NoteSession
    let navigation: MarkdownEditorNavigation
    let isInTrash: Bool
    @Binding var hasUnrecordedEdit: Bool
    @State private var editError: String?
    @State private var unrecordedText: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            if isInTrash {
                Label(
                    "In Trash · Your content is still retained.",
                    systemImage: "trash"
                )
                .font(.caption).padding(10)
            }
            MarkdownEditor(
                text: Binding(
                    get: { unrecordedText ?? session.text },
                    set: { text in
                        do {
                            try session.replaceAll(with: text)
                            unrecordedText = nil
                            editError = nil
                            hasUnrecordedEdit = false
                        } catch {
                            unrecordedText = text
                            editError = error.localizedDescription
                            hasUnrecordedEdit = true
                        }
                    }),
                editRevision: session.currentSnapshot?.data,
                commitEdit: { text, revision in
                    let snapshot = try session.commitEditorText(text, basedOn: revision)
                    unrecordedText = nil
                    editError = nil
                    hasUnrecordedEdit = false
                    return MarkdownEditorCommit(text: session.text, revision: snapshot.data)
                },
                onEditError: { error in
                    editError = error.localizedDescription
                    hasUnrecordedEdit = true
                }, navigation: navigation
            )
            .disabled(!session.isEditingEnabled)
            Divider()
            HStack {
                if let editError {
                    Text("Edit not recorded: \(editError)").foregroundStyle(.red)
                } else {
                    switch session.status {
                    case .saved:
                        Label("Saved on this device", systemImage: "checkmark")
                    case .saving: Text("Saving…")
                    case .saveFailed(let message):
                        Text("Couldn’t save: \(message)")
                        Button("Retry") { session.retrySave() }
                    default: Text("Note unavailable")
                    }
                }
                Spacer(minLength: 0)
            }
            .font(.caption).padding(10)
            .accessibilityIdentifier("note-save-status")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                Task { try? await session.flush() }
            }
        }
    }
}

struct NotebookPreviewView: View {
    @State private var workspace = NotebookWorkspace()

    var body: some View {
        Group {
            if let replica = workspace.replica {
                NotebookView(replica: replica)
            } else if let message = workspace.errorMessage {
                ContentUnavailableView {
                    Label("Notebook unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") { Task { await workspace.start() } }
                }
            } else {
                ProgressView("Opening notebook…")
            }
        }
        .task { await workspace.start() }
    }
}
