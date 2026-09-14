import NoteCore
import SwiftUI

struct NotebookNoteEditor: View {
    let session: NoteSession
    let navigation: MarkdownEditorNavigation
    let isInTrash: Bool
    @Binding var hasUnrecordedEdit: Bool
    var onPersist: () -> Void = {}
    var fontSize: Double = 17
    var fontFamily: EditorFontFamily = .system
    var mode: MarkdownEditorMode = .source
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
            if session.isEditingEnabled {
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
                    }, navigation: navigation, fontSize: fontSize,
                    fontFamily: fontFamily, mode: mode
                )
            } else {
                unavailableContent.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
        .onChange(of: session.persistedSnapshot) { _, _ in onPersist() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                Task { try? await session.flush() }
            }
        }
    }
    @ViewBuilder private var unavailableContent: some View {
        switch session.status {
        case .recoveryRequired:
            VStack(spacing: 12) {
                Text("A previous saved copy is available.").font(.headline)
                Text("Restoring it may lose newer edits. The damaged file will be kept.")
                Button("Restore Previous Copy") {
                    Task { await session.recoverFromPrevious() }
                }
                if let message = session.recoveryErrorMessage { Text(message) }
            }.padding()
        case .blocked, .loadFailed:
            ContentUnavailableView {
                Label("Note unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text("The saved files have been retained. This note may need recovery or a newer app version.")
            } actions: {
                Button("Retry") { Task { await session.load() } }
            }
        default:
            Text(session.isPermanentlyDeleted ? "This note was permanently deleted." : "Opening note…")
        }
    }

}
