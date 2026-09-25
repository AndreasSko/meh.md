import NoteCore
import SwiftUI

struct NotebookNoteEditor: View {
    let session: NoteSession
    let navigation: MarkdownEditorNavigation
    let isInTrash: Bool
    var extendsUnderTopControls = false
    var title: AnyView? = nil
    var titleHeight: CGFloat = 0
    var focusRequest = 0
    @Binding var hasUnrecordedEdit: Bool
    var onPersist: () -> Void = {}
    var onLocalEdit: () -> Void = {}
    var onBeginEditing: () -> Void = {}
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
                                let changed = text != session.text
                                try session.replaceAll(with: text)
                                if changed { onLocalEdit() }
                                unrecordedText = nil
                                editError = nil
                                hasUnrecordedEdit = false
                            } catch {
                                unrecordedText = text
                                editError = error.localizedDescription
                                hasUnrecordedEdit = true
                            }
                        }),
                    editRevision: session.editorRevision,
                    commitEdit: { text, revision in
                        let changed = text != session.text
                        let revision = try session.commitEditorText(text, basedOn: revision)
                        if changed { onLocalEdit() }
                        unrecordedText = nil
                        editError = nil
                        hasUnrecordedEdit = false
                        return MarkdownEditorCommit(text: session.text, revision: revision)
                    },
                    onEditError: { error in
                        editError = error.localizedDescription
                        hasUnrecordedEdit = true
                    }, navigation: navigation, onBeginEditing: onBeginEditing,
                    title: title, titleHeight: titleHeight,
                    focusRequest: focusRequest,
                    fontSize: fontSize,
                    fontFamily: fontFamily, mode: mode
                )
            } else {
                unavailableContent.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if editError != nil || saveError != nil {
                Divider()
                HStack {
                    if let editError {
                        Text("Edit not recorded: \(editError)")
                            .foregroundStyle(.red)
                    } else if let saveError {
                        Text("Couldn’t save: \(saveError)")
                        Button("Retry") { session.retrySave() }
                    }
                    Spacer(minLength: 0)
                }
                .font(.caption).padding(10)
                .accessibilityIdentifier("note-save-status")
            }
        }
        // Let note content scroll beneath the floating top controls.
        // Keep actionable errors and the keyboard within the bottom safe area.
        .ignoresSafeArea(.container, edges: ignoredSafeAreaEdges)
        .onChange(of: session.persistedSnapshot) { _, _ in onPersist() }
        .onDisappear {
            Task { try? await session.flush() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                Task { try? await session.flush() }
            }
        }
    }

    private var ignoredSafeAreaEdges: Edge.Set {
        var edges: Edge.Set = extendsUnderTopControls ? .top : []
        if editError == nil && saveError == nil { edges.insert(.bottom) }
        return edges
    }

    private var saveError: String? {
        if case .saveFailed(let message) = session.status { return message }
        return nil
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
