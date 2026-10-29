import Foundation
import NoteCore
import SwiftUI

private struct EditorAttachmentID: Hashable {
    let noteID: UUID
    let isEditingEnabled: Bool
    let isShowingHistory: Bool
}

/// The open note: its editor or History, completion lists, and note actions.
struct NotebookDetail: View {
    @Bindable var scene: NotebookSceneState
    let isCompact: Bool
    @AppStorage("editor.fontSize", store: NotebookEditorPreferences.store)
    private var editorFontSize = 17.0
    @AppStorage("editor.fontFamily", store: NotebookEditorPreferences.store)
    private var editorFontFamilyRaw =
        EditorFontFamily.system.rawValue
    @AppStorage("editor.mode", store: NotebookEditorPreferences.store)
    private var editorModeRaw =
        MarkdownEditorMode.livePreview.rawValue

    private var editorMode: MarkdownEditorMode {
        MarkdownEditorMode(rawValue: editorModeRaw) ?? .livePreview
    }

    private var editorFontFamily: EditorFontFamily {
        EditorFontFamily(rawValue: editorFontFamilyRaw) ?? .system
    }

    private var editorFontFamilyBinding: Binding<EditorFontFamily> {
        Binding(
            get: { editorFontFamily },
            set: { editorFontFamilyRaw = $0.rawValue }
        )
    }

    private var editorModeBinding: Binding<MarkdownEditorMode> {
        Binding(
            get: { editorMode },
            set: { editorModeRaw = $0.rawValue }
        )
    }

    private func title(for placement: NotebookPlacement) -> NotebookDetailTitle {
        NotebookDetailTitle(
            scene: scene, placement: placement,
            font: NotebookDetailTitle.font(family: editorFontFamily, size: editorFontSize),
            isEditing: scene.detailEditingID == placement.item.id,
            isEnabled: !scene.busy, focusRequest: scene.detailTitleFocusRequest
        )
    }

    var body: some View {
            Group {
                if let session = scene.session, let selectedID = scene.selectedID {
                    VStack(spacing: 0) {
                        if !session.isEditingEnabled,
                           let placement = scene.selectedPlacement {
                            title(for: placement)
                        }
                        if let historyBrowser = scene.historyBrowser,
                           historyBrowser.noteID == selectedID,
                           let placement = scene.selectedPlacement {
                            NoteHistoryBrowserView(
                                state: historyBrowser,
                                session: session,
                                title: NotebookNoteName.title(from: placement.displayName),
                                fontSize: editorFontSize,
                                fontFamily: editorFontFamily,
                                mode: editorMode,
                                onDone: scene.closeHistory,
                                onRestoreThisNote: scene.restoreHistoryInPlace,
                                onRestoreAsNewNote: scene.restoreHistoryAsNewNote,
                                onError: { scene.errorMessage = $0.localizedDescription }
                            )
                            .id(ObjectIdentifier(historyBrowser))
                        } else {
                        NotebookNoteEditor(
                            session: session, navigation: scene.editorNavigation,
                            isInTrash: scene.selectedPlacement?.isInTrash == true,
                            extendsUnderTopControls: true,
                            title: scene.selectedPlacement.map {
                                AnyView(title(for: $0))
                            },
                            titleHeight: scene.detailTitleHeight,
                            focusRequest: scene.bodyFocusRequest,
                            hasUnrecordedEdit: $scene.unrecordedEdit,
                            onPersist: {
                                scene.workspace?.contentDidSave(trigger: "note persisted")
                            },
                            onLocalEdit: { scene.recordLocalEdit(in: selectedID) },
                            onBeginEditing: {
                                if scene.detailEditingID == selectedID {
                                    scene.submitDetailTitle(focusBody: false)
                                }
                            },
                            fontSize: editorFontSize,
                            fontFamily: editorFontFamily,
                            mode: editorMode
                        )
                        .mehCrumple(trigger: scene.trashedOpenNote)
                        }
                        if let snippetReturn = scene.visibleSnippetReturn {
                            NotebookSnippetReturnBar(
                                title: scene.snippetReturnTitle(snippetReturn),
                                isEnabled: !scene.busy
                            ) {
                                scene.returnAndInsertSnippet(snippetReturn)
                            }
                        }
                        if let completion = scene.variableCompletion,
                           scene.canCompleteSnippetVariable {
                            let completionText = scene.linkCompletionText
                            let navigation = scene.editorNavigation
                            let caret = scene.variableCompletionSelection
                            NotebookSnippetVariableSuggestions(
                                variables: completion.suggestions,
                                selection: scene.linkCompletionSelection,
                                title: scene.selectedPlacement
                                    .map { NotebookNoteName.title(from: $0.displayName) } ?? "",
                                select: { variable in
                                    scene.insertCompletedVariable(variable, completion: completion,
                                        textSnapshot: completionText, sourceID: selectedID,
                                        selection: caret, navigation: navigation)
                                },
                                dismiss: { scene.dismissEditorCompletion() }
                            )
                        }
                        if let completion = scene.linkCompletion, scene.historyBrowser == nil {
                            let completionText = scene.linkCompletionText
                            NotebookLinkSuggestions(
                                notes: completion.query.contains("#") ? []
                                    : scene.links.suggestions(for: completion.query),
                                isLoading: scene.links.isLoading,
                                selection: scene.linkCompletionSelection,
                                headings: scene.completionHeadings,
                                selectHeading: { heading in
                                    if let target = scene.completionHeadingTarget {
                                        scene.insertCompletedLink(to: target,
                                            fragment: NotebookLinkDestination.wikiHeadingFragment(heading),
                                            completionSnapshot: completion, textSnapshot: completionText,
                                            sourceID: selectedID)
                                    }
                                },
                                select: { scene.insertCompletedLink(to: $0,
                                    completionSnapshot: completion, textSnapshot: completionText,
                                    sourceID: selectedID) },
                                dismiss: {
                                    scene.dismissEditorCompletion()
                                    scene.editorNavigation.hasLinkCompletion = false
                                }
                            )
                            .task(id: scene.replica.searchRevision.catalogHeads) {
                                await scene.links.refresh(replica: scene.replica)
                            }
                        }
                    }
                    .overlay {
                        if scene.isLoadingHistory, scene.historyBrowser == nil {
                            VStack(spacing: 12) {
                                ProgressView("Opening History…")
                                Button("Cancel", action: scene.cancelHistoryLoading)
                                    .accessibilityIdentifier("note-history-cancel-loading")
                            }
                            .padding(16)
                            .background(.regularMaterial, in: .rect(cornerRadius: 12))
                            .accessibilityIdentifier("note-history-loading")
                        }
                    }
                    .id(selectedID)
                    .navigationTitle("")
                    #if os(macOS)
                    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                    #else
                    .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
                    #endif
                    .task(id: EditorAttachmentID(
                        noteID: selectedID, isEditingEnabled: session.isEditingEnabled,
                        isShowingHistory: scene.historyBrowser != nil
                    )) {
                        scene.restoreEditorPosition(noteID: selectedID, session: session)
                    }
                    .toolbar { toolbar(session: session, selectedID: selectedID) }
                } else if scene.isLibraryEmpty {
                    NotebookEmptyLibraryView(scene: scene)
                        .disabled(scene.busy)
                } else {
                    ContentUnavailableView {
                        Label {
                            Text("Select a note")
                        } icon: {
                            MehFace(mood: .neutral)
                        }
                    } description: {
                        if let message = scene.navigationState.restorationMessage {
                            Text(message)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MehStyle.paperColor.ignoresSafeArea())
    }

    @ToolbarContentBuilder
    private func toolbar(session: NoteSession, selectedID: UUID) -> some ToolbarContent {
        #if os(macOS)
        if scene.historyBrowser == nil, scene.linkHistory.backTarget != nil {
            ToolbarItemGroup(placement: .navigation) {
                Button { scene.navigateLinkHistory(back: true) } label: {
                    Label("Previous Note", systemImage: "chevron.backward")
                }
                .disabled(scene.busy || scene.linkHistory.backTarget == nil)
                .keyboardShortcut("[", modifiers: .command)
                .help("Go back to the previous note")
                .accessibilityIdentifier("note-link-back")
            }
        }
        #endif
        if let placement = scene.selectedPlacement, scene.historyBrowser == nil {
            #if os(iOS)
            if isCompact {
                ToolbarItem {
                    NotebookLibraryNewNote(scene: scene)
                }
                .sharedBackgroundVisibility(.hidden)
            }
            #endif
            #if os(macOS)
            ToolbarItem {
                EditorWritingControls(
                    navigation: scene.editorNavigation,
                    isEnabled: session.isEditingEnabled
                        && !scene.busy
                        && scene.detailEditingID != selectedID
                )
            }
            #endif
            ToolbarItem {
                Menu {
                    Button {
                        scene.shareMarkdown()
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .disabled(!session.isEditingEnabled || scene.busy || scene.sharedFile != nil)
                    .accessibilityIdentifier("notebook-share-markdown")
                    Divider()
                    #if os(macOS)
                    if scene.linkHistory.forwardTarget != nil {
                        Button("Go Forward") {
                            scene.navigateLinkHistory(back: false)
                        }
                        .disabled(scene.busy)
                        .keyboardShortcut("]", modifiers: .command)
                        .accessibilityIdentifier("note-link-forward")
                        Divider()
                    }
                    #endif
                    Button {
                        scene.showBacklinks()
                    } label: {
                        Label("Linked from…", systemImage: "link")
                    }
                    .disabled(!session.isEditingEnabled || scene.busy)
                    .accessibilityIdentifier("notebook-backlinks")
                    Button("Find in Note…") { scene.showFind() }
                        .disabled(!session.isEditingEnabled)
                        .accessibilityIdentifier("notebook-find")
                    Button {
                        scene.openHistory()
                    } label: {
                        Label("Version History", systemImage: "clock.arrow.circlepath")
                    }
                    .disabled(!session.isEditingEnabled || scene.busy)
                    .accessibilityIdentifier("notebook-version-history")
                    Divider()
                    Menu {
                        EditorModeControl(
                            mode: editorModeBinding,
                            isEnabled: session.isEditingEnabled && !scene.busy
                        )
                        Divider()
                        Button {
                            scene.showingTextSize = true
                        } label: {
                            Label("Font & Text Size…",
                                  systemImage: "textformat.size")
                        }
                    } label: {
                        Label("Editor Display", systemImage: "textformat")
                    }
                    Divider()
                    NotebookItemActions(
                        scene: scene, placement: placement, allowsCreation: false,
                        allowsRename: false, allowsShowInFiles: true
                    )
                } label: {
                    Label("Note Actions", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("notebook-note-actions")
                #if os(macOS)
                .background(NotebookSharePicker(
                    file: $scene.sharedFile, onFinish: scene.presentSharedImport
                ))
                #endif
                .popover(isPresented: $scene.showingTextSize) {
                    EditorTextSizeControl(
                        fontSize: $editorFontSize,
                        fontFamily: editorFontFamilyBinding,
                        showsLineWidth: !isCompact
                    )
                        .presentationCompactAdaptation(.popover)
                        .onDisappear { scene.showingTextSize = false }
                }
            }
        }
    }
}

/// The open note's title, which renames the note when edited.
///
/// The editor hosts the title separately and refreshes it only when the
/// detail passes a new one, so the detail reads the title's state.
struct NotebookDetailTitle: View {
    let scene: NotebookSceneState
    let placement: NotebookPlacement
    let font: Font
    let isEditing: Bool
    let isEnabled: Bool
    let focusRequest: NotebookTitleFocusRequest?

    static func font(family: EditorFontFamily, size: Double) -> Font {
        let bodyFont = MarkdownPresentation.bodyFont(
            for: family,
            pointSize: MarkdownPresentation.normalizedFontSize(size)
        )
        return Font(MarkdownPresentation.headingFont(level: 1, bodyFont: bodyFont))
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if isEditing {
                NotebookTitleField(
                    noteID: placement.item.id,
                    text: Binding(
                        get: { scene.detailProposedTitle },
                        set: { scene.setDetailProposedTitle($0) }
                    ),
                    font: font,
                    isEnabled: isEnabled,
                    focusRequest: focusRequest,
                    onFocusHandled: { request in
                        if scene.detailTitleFocusRequest == request {
                            scene.detailTitleFocusRequest = nil
                        }
                    },
                    onSubmit: { scene.submitDetailTitle() },
                    onCancel: scene.cancelDetailTitle
                )
            } else {
                Button {
                    scene.beginDetailRenaming(placement)
                } label: {
                    Text(NotebookNoteName.title(from: placement.displayName))
                        .font(font)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .accessibilityIdentifier("note-title")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            if abs(scene.detailTitleHeight - height) > 0.5 {
                scene.detailTitleHeight = height
            }
        }
    }
}

extension NotebookEmptyLibraryView {
    init(scene: NotebookSceneState) {
        self.init(onStartWriting: scene.startWriting, onImportMarkdown: scene.requestImport)
    }
}
