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
    @AppStorage(MarkdownTimeCalculator.enabledKey, store: NotebookEditorPreferences.store)
    private var timeCalculatorLabs = false
    @AppStorage(MarkdownTextRules.enabledKey, store: NotebookEditorPreferences.store)
    private var textRulesLabs = false
    @AppStorage(Self.hidesControlsOnScrollKey, store: NotebookEditorPreferences.store)
    private var hidesControlsOnScroll = true
    @AppStorage(SpeakerTimer.enabledKey, store: NotebookEditorPreferences.store)
    private var speakerModeLabs = false
    @AppStorage(SpeakerTimer.lengthKey, store: NotebookEditorPreferences.store)
    private var speakerLength = 0

    /// The Settings › Appearance key for hiding the note's buttons while
    /// reading down a note.
    static let hidesControlsOnScrollKey = "editor.hidesControlsOnScroll"

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
            isEnabled: !scene.busy, isReading: scene.isReading,
            focusRequest: scene.detailTitleFocusRequest
        )
    }

    /// Beside Files a folder's page covers the note, which waits underneath.
    private var showsFolderPage: Bool { !isCompact && scene.pageFolderID != nil }

    private var speakerTimer: SpeakerTimer? {
        speakerModeLabs ? scene.speakerTimer : nil
    }

    /// Only reading the note itself tucks the bar away. History and a
    /// folder's page keep their buttons, such as Done and Restore, in view,
    /// and Speaker Mode keeps its timer in view during a talk.
    private var minimizesControls: Bool {
        hidesControlsOnScroll && scene.historyBrowser == nil && !showsFolderPage
            && speakerTimer == nil
    }

    var body: some View {
        ZStack {
            note
                .opacity(showsFolderPage ? 0 : 1)
                .allowsHitTesting(!showsFolderPage)
                .accessibilityHidden(showsFolderPage)
            #if os(macOS)
            if showsFolderPage, let folderID = scene.pageFolderID {
                NotebookFolderPage(scene: scene, folderID: folderID, isCompact: false)
            }
            #endif
        }
    }

    private var note: some View {
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
                            mode: editorMode,
                            timeCalculator: timeCalculatorLabs
                                && scene.replica.timeCalculatorNoteIDs.contains(selectedID),
                            textRules: textRulesLabs ? NotebookTextRuleLoader.configurations(
                                rules: scene.replica.textRules,
                                noteIDs: scene.replica.textRuleNoteIDs, note: selectedID
                            ) : [],
                            noteTitle: scene.selectedPlacement.map {
                                NotebookTextRuleLoader.title(of: $0.item.name)
                            } ?? "",
                            isReading: scene.isReading,
                            knownLinkNames: scene.knownLinkNames
                        )
                        }
                        if let placement = scene.selectedPlacement, placement.isInTrash,
                           scene.historyBrowser == nil {
                            NotebookTrashBar(
                                message: "In Trash",
                                actionTitle: placement.item.isTrashed ? "Restore" : nil,
                                isEnabled: !scene.busy
                            ) {
                                scene.changeTrash(placement, trashed: false)
                            }
                            .frame(maxWidth: .infinity)
                            .background(MehStyle.paperColor)
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
                                    : scene.links.suggestions(for: completion.query,
                                                              excluding: selectedID),
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
                                newNoteTitle: completion.query.contains("#") ? nil
                                    : scene.linkedNoteTitle(for: completion.query),
                                isNewNoteSelected: scene.linkNewNoteChosen,
                                createNote: {
                                    if let title = scene.linkedNoteTitle(for: completion.query) {
                                        scene.createLinkedNote(named: title,
                                            completionSnapshot: completion,
                                            textSnapshot: completionText, sourceID: selectedID)
                                    }
                                },
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
                    .toolbarMinimizationBehavior(
                        minimizesControls ? .onScrollDown : .never, for: .navigationBar
                    )
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
                        MehFace(mood: .neutral)
                    } description: {
                        if let message = scene.navigationState.restorationMessage {
                            Text(message)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("No note selected")
                    .accessibilityIdentifier("notebook-empty-detail")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MehStyle.paperColor.ignoresSafeArea())
    }

    private func shareButton(session: NoteSession) -> some View {
        Button {
            scene.shareMarkdown()
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .disabled(!session.isEditingEnabled || scene.busy || scene.sharedFile != nil)
        .accessibilityIdentifier("notebook-share-markdown")
    }

    private func backlinksButton(session: NoteSession) -> some View {
        Button {
            scene.showBacklinks()
        } label: {
            Label("Linked from…", systemImage: "link")
        }
        .disabled(!session.isEditingEnabled || scene.busy)
        .accessibilityIdentifier("notebook-backlinks")
    }

    private func findButton(session: NoteSession, title: LocalizedStringKey) -> some View {
        Button(title, systemImage: "magnifyingglass") { scene.showFind() }
            .disabled(!session.isEditingEnabled)
            .accessibilityIdentifier("notebook-find")
    }

    private func historyButton(session: NoteSession, title: LocalizedStringKey) -> some View {
        Button {
            scene.openHistory()
        } label: {
            Label(title, systemImage: "clock.arrow.circlepath")
        }
        .disabled(!session.isEditingEnabled || scene.busy)
        .accessibilityIdentifier("notebook-version-history")
    }

    /// Rules that run only in chosen notes, each turned on or off here.
    @ViewBuilder
    private func textRuleToggles(selectedID: UUID, session: NoteSession) -> some View {
        let rules = scene.replica.textRules.filter { $0.isEnabled && !$0.appliesToAllNotes }
        if !rules.isEmpty {
            Divider()
            ForEach(rules) { rule in
                Toggle(isOn: Binding(
                    get: { scene.replica.textRuleNoteIDs[rule.id]?.contains(selectedID) == true },
                    set: { enabled in
                        scene.perform {
                            try await scene.replica.setTextRule(
                                rule.id, note: selectedID, enabled: enabled)
                        }
                    }
                )) {
                    Label(NotebookTextRuleLoader.name(of: rule), systemImage: "wand.and.sparkles")
                }
                .disabled(!session.isEditingEnabled || scene.busy)
                .accessibilityIdentifier("notebook-text-rule-\(rule.id.uuidString)")
            }
        }
    }

    private func readingToggle(session: NoteSession, title: LocalizedStringKey) -> some View {
        Toggle(isOn: Binding(
            get: { scene.isReading },
            set: { scene.setReading($0) }
        )) {
            Label(title, systemImage: "eyeglasses")
        }
        .disabled(!session.isEditingEnabled)
        .accessibilityIdentifier("notebook-reading-mode")
    }

    /// Shows that Reading Mode is on, and turns it off.
    private var readingButton: some View {
        Button { scene.setReading(false) } label: {
            // Toolbars show a Label's icon only; Edit needs its word.
            HStack(spacing: 6) {
                Image(systemName: "eyeglasses")
                Text("Edit")
            }
        }
        .accessibilityLabel("Edit Note")
        .accessibilityHint("Turns off Reading Mode")
        .help("Turn off Reading Mode to edit the note")
        .accessibilityIdentifier("notebook-reading-edit")
    }

    @ToolbarContentBuilder
    private func toolbar(session: NoteSession, selectedID: UUID) -> some ToolbarContent {
        if !showsFolderPage {
            noteToolbar(session: session, selectedID: selectedID)
        }
    }

    @ToolbarContentBuilder
    private func noteToolbar(session: NoteSession, selectedID: UUID) -> some ToolbarContent {
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
            if scene.isReading {
                ToolbarItem { readingButton }
                ToolbarSpacer(.fixed)
            } else if isCompact || scene.columnVisibility == .detailOnly {
                // iPhone, and iPad with Files hidden, would otherwise have no
                // way to start a note without a keyboard.
                ToolbarItem {
                    NotebookLibraryNewNote(scene: scene)
                }
                .sharedBackgroundVisibility(.hidden)
            }
            #endif
            #if os(macOS)
            if let speakerTimer, scene.speakerIsland.spot == nil {
                ToolbarItem {
                    SpeakerToolbarIsland(timer: speakerTimer, placement: scene.speakerIsland)
                }
                .sharedBackgroundVisibility(.hidden)
            }
            if scene.isReading {
                ToolbarItem { readingButton }
            } else {
                ToolbarItem {
                    EditorWritingControls(
                        navigation: scene.editorNavigation,
                        isEnabled: session.isEditingEnabled
                            && !scene.busy
                            && scene.detailEditingID != selectedID
                    )
                }
            }
            #endif
            ToolbarItem {
                Menu {
                    #if os(iOS)
                    // A row of icons, as in Notes, keeps Move to Trash in
                    // view without scrolling the menu on iPhone.
                    ControlGroup {
                        shareButton(session: session)
                        findButton(session: session, title: "Find")
                        historyButton(session: session, title: "History")
                        // In the row, it keeps Move to Trash in view too.
                        readingToggle(session: session, title: "Reading")
                    }
                    .controlGroupStyle(.compactMenu)
                    backlinksButton(session: session)
                    #else
                    shareButton(session: session)
                    Divider()
                    if scene.linkHistory.forwardTarget != nil {
                        Button("Go Forward") {
                            scene.navigateLinkHistory(back: false)
                        }
                        .disabled(scene.busy)
                        .keyboardShortcut("]", modifiers: .command)
                        .accessibilityIdentifier("note-link-forward")
                        Divider()
                    }
                    backlinksButton(session: session)
                    findButton(session: session, title: "Find in Note…")
                    historyButton(session: session, title: "Version History")
                    #endif
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
                        if timeCalculatorLabs {
                            Divider()
                            Toggle(isOn: Binding(
                                get: { scene.replica.timeCalculatorNoteIDs.contains(selectedID) },
                                set: { enabled in
                                    scene.perform {
                                        try await scene.replica.setTimeCalculator(
                                            selectedID, enabled: enabled
                                        )
                                    }
                                }
                            )) {
                                Label("Time Calculator", systemImage: "plus.forwardslash.minus")
                            }
                            .disabled(!session.isEditingEnabled || scene.busy)
                            .accessibilityIdentifier("notebook-time-calculator")
                        }
                        if textRulesLabs {
                            textRuleToggles(selectedID: selectedID, session: session)
                        }
                    } label: {
                        Label("Editor Display", systemImage: "textformat")
                    }
                    #if os(macOS)
                    readingToggle(session: session, title: "Reading Mode")
                    #endif
                    if speakerModeLabs {
                        Toggle(isOn: Binding(
                            get: { scene.speakerTimer != nil },
                            set: { isOn in
                                scene.speakerTimer = isOn
                                    ? SpeakerTimer(lengthMinutes: speakerLength > 0 ? speakerLength : nil)
                                    : nil
                                scene.speakerIsland = SpeakerIslandPlacement()
                                // A talk is read, not written.
                                if isOn { scene.setReading(true) }
                            }
                        )) {
                            Label("Speaker Mode", systemImage: "stopwatch")
                        }
                        .accessibilityIdentifier("notebook-speaker-mode")
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
    var isReading = false
    let focusRequest: NotebookTitleFocusRequest?

    static func font(family: EditorFontFamily, size: Double) -> Font {
        let bodyFont = MarkdownPresentation.bodyFont(
            for: family,
            pointSize: MarkdownPresentation.normalizedFontSize(size)
        )
        return Font(MarkdownPresentation.headingFont(level: 1, bodyFont: bodyFont))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let folders = scene.folderChain(to: placement.parentID)
            if !folders.isEmpty, !placement.isInTrash {
                NotebookPathLine(scene: scene, folderIDs: folders, isCompact: scene.isCompact)
            }
            title
            if !isEditing, let notice = NotebookPlacementNotice(placement) {
                NotebookNoticeMark(scene: scene, placement: placement, notice: notice)
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

    private var title: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            // Reading wins over a rename that failed while turning it on.
            if isReading {
                titleText
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("note-title")
            } else if isEditing {
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
                    titleText.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .accessibilityIdentifier("note-title")
            }
        }
    }
}

private extension NotebookDetailTitle {
    var titleText: some View {
        Text(NotebookNoteName.title(from: placement.displayName))
            .font(font)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension NotebookEmptyLibraryView {
    init(scene: NotebookSceneState) {
        self.init(onStartWriting: scene.startWriting, onImportMarkdown: scene.requestImport)
    }
}
