import Foundation
import NoteCore
import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

private struct EditorAttachmentID: Hashable {
    let noteID: UUID
    let isEditingEnabled: Bool
    let isShowingHistory: Bool
}

private struct NotebookFileReveal: Equatable {
    let id: UUID
    let token = UUID()
}

#if os(iOS)
private struct NotebookBrowserViewport: Equatable {
    let offset: CGFloat
    let bottomInset: CGFloat
    let size: CGSize
}

private final class NotebookBrowserScrollReference {
    weak var value: UIScrollView?
}

/// Reads the Files header's enclosing list, without owning its scrolling.
private struct NotebookBrowserScrollReader: UIViewRepresentable {
    let reference: NotebookBrowserScrollReference

    func makeUIView(context: Context) -> NotebookBrowserScrollProbe {
        let view = NotebookBrowserScrollProbe()
        view.reference = reference
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: NotebookBrowserScrollProbe, context: Context) {
        view.connect()
    }
}

private final class NotebookBrowserScrollProbe: UIView {
    var reference: NotebookBrowserScrollReference?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        connect()
    }

    func connect() {
        var ancestor = superview
        while let view = ancestor {
            if let scrollView = view as? UIScrollView {
                reference?.value = scrollView
                return
            }
            ancestor = view.superview
        }
    }
}
#endif

private struct NotebookRecentPreviewRequest: Equatable {
    let ids: [UUID]
    let revision: NotebookSearchRevision
}

private struct NotebookSidebarRow: Identifiable {
    let id: UUID
    let parentID: UUID?
    let depth: Int

    init(placement: NotebookPlacement, depth: Int) {
        id = placement.item.id
        parentID = placement.parentID
        self.depth = depth
    }
}

struct NotebookView: View {
    let replica: NotebookReplica
    var workspace: NotebookWorkspace? = nil
    let sceneID: UUID
    let preferredNoteID: UUID?
    @State private var search = NotebookSearchState()
    @FocusState private var searchFocused: Bool
    @State private var pendingSearchQuery: String?
    @State private var searchDestinationID: UUID?
    @State private var quickOpenDidNavigate = false
    @State private var resumeEditorAfterQuickOpen = false
    @State private var searchLandingPosition: MarkdownEditorPosition?
    @State private var showingImport = false
    @State private var showingSettings = false
    @State private var showingTrash = false
    @State private var showingTextSize = false
    @State private var sharedFile: NotebookSharedFile?
    @State private var historyBrowser: NoteHistoryBrowserState?
    @State private var isLoadingHistory = false
    @State private var historyLoadTask: Task<Void, Never>?
    @AppStorage("editor.fontSize") private var editorFontSize = 17.0
    @AppStorage("editor.fontFamily") private var editorFontFamilyRaw =
        EditorFontFamily.system.rawValue
    @AppStorage("editor.mode") private var editorModeRaw =
        MarkdownEditorMode.livePreview.rawValue
    @State private var deletionSelection: NotebookDeletionSelection?
    @State private var navigationState: NotebookNavigationState
    @State private var recentCommands: NotebookRecentCommandState
    @State private var restoredNavigation = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @State private var busy = false
    @State private var editorNavigation = MarkdownEditorNavigation()
    @State private var bodyFocusRequest = 0
    @State private var errorMessage: String?
    @State private var recentActivityFailureIDs = Set<UUID>()
    @State private var browsingAllRecents = false
    @State private var visibleRecentPreviewIDs: [UUID] = []
    @State private var unrecordedEdit = false
    @State private var editingID: UUID?
    @State private var originalName = ""
    @State private var proposedName = ""
    @FocusState private var focusedNameID: UUID?
    @State private var detailEditingID: UUID?
    @State private var detailOriginalName = ""
    @State private var detailProposedTitle = ""
    @State private var detailTitleHeight: CGFloat = 32
    @State private var selectGeneratedTitle = false
    @FocusState private var focusedTitleID: UUID?
    @State private var movingIDs: [UUID] = []
    @State private var movingFromTrash = false
    @State private var browserSelection = NotebookBrowserSelection()
    @State private var selectingItems = false
    @FocusState private var browserFocused: Bool
    @FocusState private var focusedRecentID: UUID?
    #if os(macOS)
        @FocusState private var recentsMoreFocused: Bool
        @FocusState private var recentsHeaderFocused: Bool
    #endif
    @State private var movingNotebookID: UUID?
    @State private var browserUndo: NotebookBrowserUndo?
    @State private var browserRedo: NotebookBrowserUndo?
    @State private var destination: UUID?
    @State private var fileRevealRequest: NotebookFileReveal?
    @State private var highlightedFileID: UUID?
    @State private var preferredCompactColumn = NavigationSplitViewColumn.sidebar
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
        @State private var quickActionRequests = NotebookQuickActionRequests.shared
        @State private var browserScrollView = NotebookBrowserScrollReference()
        @State private var browserViewport: NotebookBrowserViewport?
        @State private var browserReturnViewport: NotebookBrowserViewport?
        @State private var browserToolbarWasHidden = false
    #endif

    init(
        replica: NotebookReplica,
        workspace: NotebookWorkspace? = nil,
        sceneID: UUID,
        preferredNoteID: UUID? = nil
    ) {
        self.replica = replica
        self.workspace = workspace
        self.sceneID = sceneID
        self.preferredNoteID = preferredNoteID
        _navigationState = State(initialValue: NotebookNavigationState(
            replica: replica, sceneID: sceneID
        ))
        _recentCommands = State(initialValue: NotebookRecentCommandState(replica: replica))
    }

    private var selectedID: UUID? { navigationState.selectedID }
    private var session: NoteSession? { navigationState.selectedSession }
    private var expandedIDs: Set<UUID> {
        get { navigationState.expandedFolderIDs }
        nonmutating set { navigationState.expandedFolderIDs = newValue }
    }
    private var syncToolbarPlacement: ToolbarItemPlacement {
        #if os(macOS)
        .navigation
        #else
        .topBarLeading
        #endif
    }

    private var notebookSidebar: some View {
            ZStack {
                libraryBrowser
                    .opacity(search.isPresented ? 0 : 1)
                    .allowsHitTesting(!search.isPresented)
                    .accessibilityHidden(search.isPresented)
                if search.isPresented {
                    NotebookSearchResults(
                        results: search.results, query: search.query,
                        isPreparing: search.isPreparing,
                        unavailableCount: search.unavailableCount, error: search.error,
                        selection: $search.selectedResultID,
                        open: { openSearchResult($0, query: search.resultQuery) }
                    )
                }
            }
            .searchable(text: $search.query, isPresented: $search.isPresented,
                        placement: .toolbar, prompt: "Search all notes")
            .searchFocused($searchFocused)
            #if os(macOS)
            .scrollIndicators(.automatic)
            #endif
            .overlay(alignment: .bottom) {
                if !isPhoneLayout && !search.isPresented && !showsSelectionControls
                    && !browsingAllRecents {
                    NotebookSidebarControls(
                        busy: busy,
                        showSettings: { showingSettings = true },
                        showTrash: { openTrash() }
                    )
                }
            }
            .navigationTitle(showsSelectionControls && !search.isPresented ? "" : "meh.md")
            #if os(iOS)
            .navigationBarTitleDisplayMode(showsSelectionControls ? .inline : .large)
            #endif
            .navigationSplitViewColumnWidth(min: 220, ideal: 280)
            .toolbar {
                if !showingTrash {
                    if let workspace, !showsSelectionControls {
                        ToolbarItem(placement: syncToolbarPlacement) {
                            NotebookSyncButton(workspace: workspace)
                        }
                    }
                    if showsSelectionControls && !search.isPresented {
                        ToolbarItem(placement: .cancellationAction) { selectAllButton }
                        ToolbarItem(placement: .principal) { selectionCount }
                        ToolbarItem(placement: .confirmationAction) { selectionDone }
                        #if os(iOS)
                        ToolbarItem(placement: .bottomBar) { moveSelectedButton }
                        ToolbarSpacer(.flexible, placement: .bottomBar)
                        ToolbarItem(placement: .bottomBar) { trashSelectedButton }
                        #else
                        ToolbarItemGroup {
                            moveSelectedButton
                            trashSelectedButton
                        }
                        #endif
                    } else {
                        ToolbarItem(placement: .primaryAction) { applicationMenu }
                        if isPhoneLayout {
                            #if os(iOS)
                            DefaultToolbarItem(kind: .search, placement: .bottomBar)
                            if !search.isPresented {
                                ToolbarSpacer(.fixed, placement: .bottomBar)
                                ToolbarItem(placement: .bottomBar) { libraryNewNote }
                            }
                            #endif
                        } else {
                            ToolbarItem { libraryNewNote }
                        }
                    }
                }
            }
    }

    private var notebookDetail: some View {
            Group {
                if let session, let selectedID {
                    VStack(spacing: 0) {
                        if !session.isEditingEnabled,
                           let placement = selectedPlacement {
                            detailTitle(for: placement)
                        }
                        if let historyBrowser, historyBrowser.noteID == selectedID,
                           let placement = selectedPlacement {
                            NoteHistoryBrowserView(
                                state: historyBrowser,
                                session: session,
                                title: NotebookNoteName.title(from: placement.displayName),
                                fontSize: editorFontSize,
                                fontFamily: editorFontFamily,
                                mode: editorMode,
                                onDone: closeHistory,
                                onRestoreThisNote: restoreHistoryInPlace,
                                onRestoreAsNewNote: restoreHistoryAsNewNote,
                                onError: { errorMessage = $0.localizedDescription }
                            )
                            .id(ObjectIdentifier(historyBrowser))
                        } else {
                        NotebookNoteEditor(
                            session: session, navigation: editorNavigation,
                            isInTrash: selectedPlacement?.isInTrash == true,
                            extendsUnderTopControls: true,
                            title: selectedPlacement.map {
                                AnyView(detailTitle(for: $0))
                            },
                            titleHeight: detailTitleHeight,
                            focusRequest: bodyFocusRequest,
                            hasUnrecordedEdit: $unrecordedEdit,
                            onPersist: {
                                workspace?.contentDidSave(trigger: "note persisted")
                            },
                            onLocalEdit: {
                                searchDestinationID = nil
                                searchLandingPosition = nil
                                if !replica.isLatestRecentActivity(selectedID) {
                                    Task { @MainActor in
                                        do {
                                            try await replica.recordRecentActivity(for: selectedID)
                                            recentActivityFailureIDs.remove(selectedID)
                                        } catch {
                                            guard recentActivityFailureIDs.insert(selectedID).inserted
                                            else { return }
                                            errorMessage = error.localizedDescription
                                        }
                                    }
                                }
                                workspace?.noteDidEdit()
                            },
                            onBeginEditing: {
                                if detailEditingID == selectedID {
                                    submitDetailTitle(focusBody: false)
                                }
                            },
                            fontSize: editorFontSize,
                            fontFamily: editorFontFamily,
                            mode: editorMode
                        )
                        }
                    }
                    .allowsHitTesting(!isLoadingHistory)
                    .overlay {
                        if isLoadingHistory {
                            ProgressView("Loading History…")
                                .padding(16)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
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
                        isShowingHistory: historyBrowser != nil
                    )) {
                        guard session.isEditingEnabled, historyBrowser == nil else { return }
                        let incomingNavigation = editorNavigation
                        let state = navigationState
                        let position = state.position(for: selectedID).flatMap {
                            try? JSONDecoder().decode(MarkdownEditorPosition.self, from: $0)
                        }
                        incomingNavigation.whenAttached { [weak incomingNavigation, weak state] in
                            guard let incomingNavigation,
                                  state?.selectedID == selectedID else { return }
                            if searchDestinationID == selectedID {
                                revealSearchDestination(in: incomingNavigation)
                            } else if let position {
                                incomingNavigation.restorePosition?(position)
                            }
                        }
                    }
                    .toolbar {
                        if let placement = selectedPlacement, historyBrowser == nil {
                            #if os(iOS)
                            if horizontalSizeClass == .compact {
                                ToolbarItem {
                                    Button {
                                        createDefaultNote()
                                    } label: {
                                        Label("New Note", systemImage: "plus")
                                    }
                                    .disabled(busy)
                                    .accessibilityIdentifier("notebook-new-item")
                                }
                            }
                            #endif
                            #if os(macOS)
                            ToolbarItem {
                                EditorWritingControls(
                                    navigation: editorNavigation,
                                    isEnabled: session.isEditingEnabled
                                        && !busy
                                )
                            }
                            #endif
                            ToolbarItem {
                                Menu {
                                    Button {
                                        shareMarkdown()
                                    } label: {
                                        Label("Share Markdown…", systemImage: "square.and.arrow.up")
                                    }
                                    .disabled(!session.isEditingEnabled || busy)
                                    .accessibilityIdentifier("notebook-share-markdown")
                                    Divider()
                                    Button("Find in Note…") { showFind() }
                                        .disabled(!session.isEditingEnabled)
                                        .accessibilityIdentifier("notebook-find")
                                    Button {
                                        openHistory()
                                    } label: {
                                        Label("Version History", systemImage: "clock.arrow.circlepath")
                                    }
                                    .disabled(!session.isEditingEnabled || busy)
                                    .accessibilityIdentifier("notebook-version-history")
                                    Divider()
                                    EditorModeControl(
                                        mode: editorModeBinding,
                                        isEnabled: session.isEditingEnabled
                                            && !busy
                                    )
                                    Divider()
                                    Button {
                                        showingTextSize = true
                                    } label: {
                                        Label(
                                            "Font & Text Size…",
                                            systemImage: "textformat.size"
                                        )
                                    }
                                    Divider()
                                    actions(
                                        for: placement, allowsCreation: false,
                                        allowsRename: false, allowsShowInFiles: true
                                    )
                                } label: {
                                    Label("Note Actions", systemImage: "ellipsis.circle")
                                }
                                .accessibilityIdentifier("notebook-note-actions")
                                #if os(macOS)
                                .background(NotebookSharePicker(file: $sharedFile))
                                #endif
                                .popover(isPresented: $showingTextSize) {
                                    EditorTextSizeControl(
                                        fontSize: $editorFontSize,
                                        fontFamily: editorFontFamilyBinding
                                    )
                                        .presentationCompactAdaptation(.popover)
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView {
                        Label("Select a note", systemImage: "note.text")
                    } description: {
                        if let message = navigationState.restorationMessage {
                            Text(message)
                        }
                    }
                }
            }
    }

    private var searchNavigation: some View {
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
            notebookSidebar
        } detail: {
            notebookDetail
        }
        .focusedSceneValue(\.notebookSearch, search)
        .focusedSceneValue(\.notebookRecentCommands, recentCommands)
        .onChange(of: focusedRecentID) { _, id in
            recentCommands.focusedNoteID = id
        }
        .onChange(of: selectedID) { _, id in
            historyLoadTask?.cancel()
            if historyBrowser != nil { closeHistory() }
            recentCommands.selectedNoteID = id
        }
        .onChange(of: recentCommands.errorMessage) { _, message in
            if let message {
                errorMessage = message
                recentCommands.errorMessage = nil
            }
        }
        #if os(macOS)
        .onChange(of: recentCommands.browseAllRequest) { _, _ in
            if browsingAllRecents {
                collapseMacRecents()
            } else if hasMoreRecents {
                browsingAllRecents = true
            }
        }
        .onChange(of: hasMoreRecents, initial: true) { _, available in
            recentCommands.canBrowseAll = available
        }
        .onChange(of: browsingAllRecents) { _, expanded in
            recentCommands.isBrowsingAll = expanded
        }
        #endif
        .task(id: searchTaskID) {
            // Warm once in the background; don't rescan on every editor
            // keystroke while search is closed.
            guard search.isPresented || search.showingQuickOpen
                    || !search.hasPreparedCorpus else { return }
            await search.refresh(replica: replica, recentIDs: navigationState.recentNoteIDs)
        }
        .onChange(of: search.quickOpenRequest) { _, _ in showQuickOpen() }
        .onChange(of: search.findRequest) { _, _ in showFind() }
        .onChange(of: session?.isEditingEnabled, initial: true) { _, enabled in
            search.canFind = enabled == true
        }
        .onChange(of: workspace?.searchScopeGeneration) { _, _ in
            search.clear()
            searchLandingPosition = nil
            pendingSearchQuery = nil
            searchDestinationID = nil
        }
        .sheet(isPresented: $search.showingQuickOpen, onDismiss: {
            editorNavigation.resumeEditing?()
            if !quickOpenDidNavigate {
                if resumeEditorAfterQuickOpen { editorNavigation.focusEditor?() }
                else if search.isPresented { searchFocused = true }
            }
        }) {
            NotebookQuickOpen(search: search) { result in
                openSearchResult(result, query: search.resultQuery, fromQuickOpen: true)
            }
        }
    }

    var body: some View {
        searchNavigation
        .disabled(workspace?.isResetPending == true)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let workspace { NotebookWorkspaceStatusView(workspace: workspace) }
        }
        .onChange(of: replica.catalogSnapshot) { previous, current in
            workspace?.contentDidSave(trigger: "catalog snapshot changed")
            navigationState.refreshAvailability()
            if previous?.notebookID != current?.notebookID {
                search.clear()
                searchLandingPosition = nil
                pendingSearchQuery = nil
                searchDestinationID = nil
                browserSelection.clear()
                selectingItems = false
                movingIDs = []
                browserUndo = nil
                browserRedo = nil
            } else {
                browserSelection.prune(to: activeBrowserIDs)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { rememberEditorPosition() }
        }
        #if os(iOS)
        .onChange(of: quickActionRequests.pendingNewNotes, initial: true) { _, _ in
            handlePendingNewNoteAction()
        }
        .onChange(of: busy) { _, isBusy in
            if !isBusy { handlePendingNewNoteAction() }
        }
        #endif
        .onDisappear {
            historyLoadTask?.cancel()
            rememberEditorPosition()
        }
        .onReceive(NotificationCenter.default.publisher(for: applicationWillTerminate)) { _ in
            rememberEditorPosition()
        }
        .alert(
            "Couldn’t complete the action",
            isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(
            isPresented: Binding(
                get: { !movingIDs.isEmpty }, set: { if !$0 { movingIDs = [] } }
            )
        ) { moveSheet }
        .sheet(isPresented: $showingImport) {
            NotebookImportView(replica: replica, onImport: importMarkdown)
        }
        .sheet(isPresented: $showingTrash) {
            NavigationStack {
                trashView
            }
            #if os(macOS)
            .frame(minWidth: 400, idealWidth: 560, minHeight: 360, idealHeight: 540)
            #endif
        }
        #if os(iOS)
        .sheet(item: $sharedFile) { file in
            NotebookShareSheet(file: file)
        }
        #endif
        .sheet(isPresented: $showingSettings) {
            NotebookSettingsView(replica: replica,
                                 workspace: workspace ?? NotebookWorkspace.shared,
                                 onImport: importMarkdown,
                                 beforeExport: flushEditor)
        }
        .confirmationDialog(
            deletionSelection?.rootID == nil ? "Empty Trash?" : "Delete permanently?",
            isPresented: Binding(
                get: { deletionSelection != nil },
                set: { if !$0 { deletionSelection = nil } }
            ),
            titleVisibility: .visible,
            presenting: deletionSelection
        ) { selection in
            Button("Delete Permanently", role: .destructive) {
                deletePermanently(selection)
            }
            Button("Cancel", role: .cancel) { deletionSelection = nil }
        } message: { selection in
            Text(deletionMessage(selection))
        }
        .task {
            guard !restoredNavigation else { return }
            restoredNavigation = true
            if replica.hasPendingImport { showingImport = true }
            guard !busy else { return }
            busy = true
            await navigationState.restoreLastSelection(preferredNoteID: preferredNoteID)
            if selectedID != nil { preferredCompactColumn = .detail }
            busy = false
            #if os(iOS)
            handlePendingNewNoteAction()
            #endif
        }
        .task(id: navigationState.recentNoteIDs) {
            await navigationState.loadRecentSessions()
        }
        .task(id: NotebookRecentPreviewRequest(
            ids: visibleRecentPreviewIDs,
            revision: navigationState.recentPreviewRevision
        )) {
            guard !visibleRecentPreviewIDs.isEmpty else { return }
            await navigationState.loadRecentPreviews(for: visibleRecentPreviewIDs)
        }
        .onChange(of: search.isPresented) { _, presented in
            if presented { browsingAllRecents = false }
        }
        .onChange(of: fileRevealRequest) { _, request in
            if request != nil { browsingAllRecents = false }
        }
        .onChange(of: selectingItems) { _, selecting in
            if selecting { browsingAllRecents = false }
        }
        .onChange(of: replica.catalogSnapshot?.notebookID) { _, _ in
            browsingAllRecents = false
            visibleRecentPreviewIDs = []
        }
    }

    private var applicationWillTerminate: Notification.Name {
        #if os(macOS)
        NSApplication.willTerminateNotification
        #else
        UIApplication.willTerminateNotification
        #endif
    }

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

    private var sidebarRowHeight: CGFloat {
        #if os(macOS)
            28
        #else
            44
        #endif
    }

    private var selectedPlacement: NotebookPlacement? {
        replica.placements.first { $0.item.id == selectedID }
    }

    @ViewBuilder
    private func detailTitle(for placement: NotebookPlacement) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if detailEditingID == placement.item.id {
                TextField(
                    "Note title",
                    text: Binding(
                        get: { detailProposedTitle },
                        set: { value in
                            if value.contains(where: { $0.isNewline }) {
                                // Return can replace a fully selected title
                                // with only a newline. Keep the title when
                                // that newline is a submit action.
                                if !(value.allSatisfy(\.isNewline)
                                    && !detailProposedTitle.isEmpty) {
                                    detailProposedTitle = value.filter {
                                        !$0.isNewline
                                    }
                                }
                                submitDetailTitle()
                            } else {
                                detailProposedTitle = value
                            }
                        }
                    ),
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(editorTitleFont)
                .lineLimit(1...4)
                .focused($focusedTitleID, equals: placement.item.id)
                .disabled(busy)
                .submitLabel(.done)
                .onSubmit { submitDetailTitle() }
                .onKeyPress(.tab) {
                    submitDetailTitle()
                    return .handled
                }
                .onChange(of: busy, initial: true) { _, isBusy in
                    if !isBusy, detailEditingID == placement.item.id {
                        focusedTitleID = placement.item.id
                        if selectGeneratedTitle {
                            selectGeneratedTitle = false
                            Task { @MainActor in
                                await Task.yield()
                                #if os(macOS)
                                NSApp.sendAction(
                                    #selector(NSText.selectAll(_:)),
                                    to: nil, from: nil
                                )
                                #else
                                UIApplication.shared.sendAction(
                                    #selector(UIResponder.selectAll(_:)),
                                    to: nil, from: nil, for: nil
                                )
                                #endif
                            }
                        }
                    }
                }
                .notebookEscapeAction { cancelDetailTitle() }
                .accessibilityIdentifier("title-field")
            } else {
                Button {
                    beginDetailRenaming(placement)
                } label: {
                    Text(NotebookNoteName.title(from: placement.displayName))
                        .font(editorTitleFont)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .accessibilityIdentifier("note-title")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            if abs(detailTitleHeight - height) > 0.5 {
                detailTitleHeight = height
            }
        }
    }

    private var editorTitleFont: Font {
        let bodyFont = MarkdownPresentation.bodyFont(
            for: editorFontFamily,
            pointSize: MarkdownPresentation.normalizedFontSize(editorFontSize)
        )
        return Font(MarkdownPresentation.headingFont(level: 1, bodyFont: bodyFont))
    }

    private func recentsSection(hidesCompactRows: Bool) -> some View {
        Section {
            #if os(macOS)
            NotebookMacRecentsCompactHeader(
                isExpanded: navigationState.isRecentsExpanded
            ) { navigationState.isRecentsExpanded.toggle() }
            .focused($recentsHeaderFocused)
            .background(NotebookRecentCardBackground(
                position: navigationState.isRecentsExpanded ? .first : .only
            ))
            .anchorPreference(key: NotebookMacRecentsAnchorKey.self,
                              value: .bounds) { [$0] }
            #endif
            if navigationState.isRecentsExpanded {
                if recentPlacements.isEmpty {
                    Text("Notes you edit or rename appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        #if os(macOS)
                        .background(NotebookRecentCardBackground(position: .last))
                        .anchorPreference(key: NotebookMacRecentsAnchorKey.self,
                                          value: .bounds) { [$0] }
                        #else
                        .background(NotebookRecentCardBackground(position: .only))
                        #endif
                } else {
                    #if os(iOS)
                    VStack(spacing: 0) {
                        NotebookRecentUIKitList(
                            items: Array(allRecentUIKitItems.prefix(recentPlacements.count)),
                            rowContent: { id in
                                if let index = recentPlacements.firstIndex(where: {
                                    $0.item.id == id
                                }) {
                                    recentRow(recentPlacements[index], index: index,
                                              count: recentPlacements.count)
                                }
                            },
                            onTogglePin: { id in
                                setRecentPinned(!replica.isPinnedInRecents(id), for: id)
                            },
                            onTrash: { id, completion in
                                trashItems([id], onCompletion: completion)
                            },
                            contextMenu: recentUIKitMenu,
                            accessibilityHidden: hidesCompactRows
                        )
                        if replica.allRecentNotes.count > recentPlacements.count {
                            NotebookRecentsFooterSpacer()
                        }
                    }
                    .background(NotebookSidebarPalette.recents)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .opacity(hidesCompactRows ? 0 : 1)
                    .accessibilityHidden(hidesCompactRows)
                    .anchorPreference(key: NotebookRecentsAnchorKey.self,
                                      value: .bounds) { $0 }
                    #else
                    ForEach(Array(recentPlacements.enumerated()), id: \.element.item.id) {
                        index, placement in
                        recentRow(placement, index: index + 1,
                                  count: recentPlacements.count + 1 + (hasMoreRecents ? 1 : 0))
                            .anchorPreference(key: NotebookMacRecentsAnchorKey.self,
                                              value: .bounds) { [$0] }
                    }
                    if hasMoreRecents {
                        Button {
                            browsingAllRecents = true
                        } label: {
                            Label("More", systemImage: "chevron.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focused($recentsMoreFocused)
                        .accessibilityLabel("Browse all recent notes")
                        .accessibilityIdentifier("notebook-recents-more")
                        .background(NotebookRecentCardBackground(position: .last))
                        .anchorPreference(key: NotebookMacRecentsAnchorKey.self,
                                          value: .bounds) { [$0] }
                    }
                    #endif
                }
            }
        } header: {
            #if os(iOS)
            NotebookSectionToggle(
                title: "Recents",
                isExpanded: navigationState.isRecentsExpanded,
                identifier: "notebook-recents-toggle"
            ) { navigationState.isRecentsExpanded.toggle() }
            .opacity(hidesCompactRows ? 0 : 1)
            .accessibilityHidden(hidesCompactRows)
            .textCase(nil)
            .listRowInsets(sidebarSectionInsets)
            #endif
        }
        .selectionDisabled()
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(recentSectionInsets)
    }

    private var sidebarSectionInsets: EdgeInsets {
        EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20)
    }

    private var recentSectionInsets: EdgeInsets {
        #if os(macOS)
        EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        #else
        sidebarSectionInsets
        #endif
    }

    private var recentPlacements: [NotebookPlacement] {
        navigationState.recentNoteIDs.compactMap { id in
            replica.placements.first { $0.item.id == id }
        }
    }

    private var hasMoreRecents: Bool {
        replica.allRecentNotes.count > recentPlacements.count
    }

    #if os(macOS)
    private var allRecentPlacements: [NotebookPlacement] {
        let placements = Dictionary(uniqueKeysWithValues:
            replica.placements.map { ($0.item.id, $0) })
        return replica.allRecentNotes.compactMap { placements[$0.id] }
    }

    private func collapseMacRecents() {
        browsingAllRecents = false
        if navigationState.isRecentsExpanded && hasMoreRecents {
            recentsMoreFocused = true
        } else {
            recentsHeaderFocused = true
        }
    }
    #endif

    @ViewBuilder
    private func recentRow(
        _ placement: NotebookPlacement,
        index: Int,
        count: Int,
        showsCardBackground: Bool = true
    ) -> some View {
        let row = Button {
            perform {
                #if os(iOS)
                if horizontalSizeClass == .compact { browsingAllRecents = false }
                #endif
                try await selectNote(placement.item.id)
            }
        } label: {
            NotebookRecentRow(
                title: NotebookNoteName.title(from: placement.displayName),
                preview: recentPreview(for: placement.item.id),
                isPinned: replica.isPinnedInRecents(placement.item.id),
                isCurrent: showsCurrentNote && selectedID == placement.item.id,
                showsDivider: index < count - 1
            )
        }
        .buttonStyle(.plain)
        .focused($focusedRecentID, equals: placement.item.id)
        .accessibilityIdentifier("notebook-recent-" + placement.item.id.uuidString)
        .accessibilityValue(
            [replica.isPinnedInRecents(placement.item.id) ? String(localized: "Pinned") : nil,
             showsCurrentNote && selectedID == placement.item.id
                ? String(localized: "Current note") : nil]
                .compactMap { $0 }.joined(separator: ", ")
        )
        .notebookRecentPinAccessibilityAction(
            isPinned: replica.isPinnedInRecents(placement.item.id),
            isAvailable: replica.canPinInRecents(placement.item.id)
        ) {
            setRecentPinned(!replica.isPinnedInRecents(placement.item.id),
                            for: placement.item.id)
        }
        .accessibilityAction(named: Text("Move to Trash")) {
            trashItems([placement.item.id])
        }
        .background(NotebookRecentCardBackground(
            position: recentCardPosition(index: index, count: count)
        ).opacity(showsCardBackground ? 1 : 0))

        #if os(iOS)
        row
        #else
        row
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            let id = placement.item.id
            if replica.isPinnedInRecents(id) || replica.canPinInRecents(id) {
                recentPinButton(for: id, swipeIcon: true)
                    .tint(replica.isPinnedInRecents(id) ? .gray : .orange)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                trashItems([placement.item.id])
            } label: {
                Label("Trash", systemImage: "trash")
            }
            .accessibilityIdentifier("notebook-recent-swipe-trash")
        }
        .contextMenu {
            actions(for: placement, allowsCreation: false,
                    allowsShowInFiles: true)
        }
        #endif
    }

    #if os(iOS)
    private func recentUIKitMenu(for id: UUID) -> UIMenu {
        guard let placement = replica.placements.first(where: { $0.item.id == id })
        else { return UIMenu(children: []) }
        var menuActions: [UIMenuElement] = [
            UIAction(title: String(localized: "Rename…")) { _ in
                beginRenaming(placement)
            },
            UIAction(title: String(localized: "Move…")) { _ in
                beginMoving([id], fromTrash: false)
            },
            UIAction(title: String(localized: "Show in Files")) { _ in
                showInFiles(id)
            }
        ]
        if supportsMultipleWindows {
            menuActions.insert(UIAction(title: String(localized: "Open in New Window")) { _ in
                openWindow(id: "notebook", value: NotebookWindowValue(noteID: id))
            }, at: 0)
        }
        let pinned = replica.isPinnedInRecents(id)
        let title = pinned ? String(localized: "Unpin from Recents")
            : String(localized: "Pin in Recents")
        menuActions.append(UIAction(
            title: title,
            attributes: !pinned && !replica.canPinInRecents(id) ? .disabled : []
        ) { _ in
            setRecentPinned(!pinned, for: id)
        })
        menuActions.append(UIAction(
            title: String(localized: "Move to Trash"),
            attributes: .destructive
        ) { _ in
            changeTrash(placement, trashed: true)
        })
        return UIMenu(children: menuActions)
    }
    #endif

    private func recentCardPosition(
        index: Int,
        count: Int
    ) -> NotebookRecentCardPosition {
        if count == 1 { return .only }
        if index == 0 { return .first }
        return index == count - 1 ? .last : .middle
    }

    @ViewBuilder
    private func recentPinButton(for id: UUID, swipeIcon: Bool = false) -> some View {
        let pinned = replica.isPinnedInRecents(id)
        let title: LocalizedStringKey = pinned
            ? "Unpin from Recents" : "Pin in Recents"
        Button {
            setRecentPinned(!pinned, for: id)
        } label: {
            if swipeIcon {
                Image(systemName: pinned ? "pin.slash" : "pin.fill")
            } else {
                Text(title)
            }
        }
        .accessibilityLabel(Text(title))
        .disabled(!pinned && !replica.canPinInRecents(id))
        .accessibilityIdentifier("notebook-recent-pin-" + id.uuidString)
    }

    private func setRecentPinned(_ pinned: Bool, for id: UUID) {
        Task { @MainActor in
            do {
                try await replica.setPinnedInRecents(pinned, for: id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var showsCurrentNote: Bool {
        #if os(macOS)
        true
        #else
        horizontalSizeClass != .compact
        #endif
    }

    private func recentPreview(for id: UUID) -> String {
        guard let recent = navigationState.recentSessions[id] else {
            return navigationState.recentPreviewText[id] ?? "Preview unavailable"
        }
        if workspace?.isResetPending == true { return "Restart to finish reset" }
        guard recent.isEditingEnabled else { return "Note unavailable" }
        let preview = NotebookRecentPreview.text(from: recent.text)
        return preview.isEmpty ? "Empty note" : preview
    }

    private var visibleActiveRows: [NotebookSidebarRow] {
        navigationState.isTreeExpanded ? flattenedRows(inTrash: false) : []
    }

    private var activeTree: some View {
        ForEach(visibleActiveRows) { row in
            browserRow(row)
                .tag(row.id)
                .id(row.id)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(sidebarSectionInsets)
        }
    }

    private func browserRow(_ row: NotebookSidebarRow) -> some View {
        sidebarRow(row)
    }

    @ViewBuilder
    private func browserRowActions(for placement: NotebookPlacement) -> some View {
        if browserSelection.contains(placement.item.id), browserSelection.count > 1 {
            Button("Move Selected…") {
                beginMoving(browserSelection.orderedIDs(in: activeBrowserOrder))
            }
            Button("Trash Selected", role: .destructive) {
                trashItems(browserSelection.orderedIDs(in: activeBrowserOrder))
            }
        } else {
            actions(for: placement)
        }
    }

    private var nativeBrowserSelection: Binding<Set<UUID>> {
        Binding(get: { browserSelection.selectedIDs }, set: { ids in
            let hidden = browserSelection.selectedIDs.subtracting(visibleActiveRows.map(\.id))
            browserSelection.selectAll(Array(ids.union(hidden)))
        })
    }

    private var activeBrowserIDs: Set<UUID> {
        Set(replica.placements.filter { !$0.isInTrash }.map(\.item.id))
    }

    private var activeBrowserOrder: [UUID] {
        func descendants(_ parentID: UUID?) -> [UUID] {
            replica.orderedChildren(parentID: parentID).flatMap { placement in
                [placement.item.id] + (placement.item.kind == .folder
                    ? descendants(placement.item.id) : [])
            }
        }
        return descendants(nil)
    }

    private var showsSelectionControls: Bool {
        selectingItems || browserSelection.count > 1
    }

    private var moveSelectedButton: some View {
        Button {
            beginMoving(browserSelection.orderedIDs(in: activeBrowserOrder))
        } label: {
            Image(systemName: "arrow.forward.folder")
        }
        .accessibilityLabel("Move")
        .help("Move selected items")
        .accessibilityIdentifier("notebook-move-selected")
        .disabled(busy || browserSelection.isEmpty)
    }

    private var trashSelectedButton: some View {
        Button(role: .destructive) {
            trashItems(browserSelection.orderedIDs(in: activeBrowserOrder))
        } label: {
            Label("Trash", systemImage: "trash")
        }
        .labelStyle(.titleAndIcon)
        .accessibilityIdentifier("notebook-trash-selected")
        .disabled(busy || browserSelection.isEmpty)
    }

    private var selectAllButton: some View {
        let visible = Set(visibleActiveRows.map(\.id))
        let allSelected = !visible.isEmpty && visible.isSubset(of: browserSelection.selectedIDs)
        return Button(allSelected ? "Deselect All" : "Select All") {
            if allSelected { browserSelection.clear() }
            else { browserSelection.selectAll(Array(visible)) }
        }
        .accessibilityIdentifier("notebook-select-all")
        .disabled(busy)
    }

    private var selectionCount: some View {
        Button {
            navigationState.isTreeExpanded = true
            for id in browserSelection.selectedIDs { reveal(id) }
        } label: {
            Text("\(browserSelection.count) selected")
                .font(.headline)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("notebook-selection-count")
        .accessibilityHint("Reveals selected items in collapsed folders")
        .help("Reveal selected items")
        .disabled(busy || browserSelection.isEmpty)
    }

    private var selectionDone: some View {
        Button("Done") {
            selectingItems = false
            browserSelection.clear()
        }
        .accessibilityIdentifier("notebook-selection-done")
        .disabled(busy)
    }

    @ViewBuilder
    private var browserUndoActions: some View {
        if browserUndo?.action == .move {
            Button("Undo Move") { undoBrowserChange(redo: false) }
                .accessibilityIdentifier("notebook-browser-undo")
        }
        if browserRedo?.action == .move {
            Button("Redo Move") { undoBrowserChange(redo: true) }
                .accessibilityIdentifier("notebook-browser-redo")
        }
    }

    private var trashView: some View {
        NotebookTrashView(
            replica: replica,
            beforeMutation: flushEditor,
            onMutation: {
                browserUndo = nil
                browserRedo = nil
                if let selectedID,
                   !replica.placements.contains(where: { $0.item.id == selectedID }) {
                    navigationState.clearSelection()
                    unrecordedEdit = false
                    preferredCompactColumn = .sidebar
                }
                workspace?.contentDidSave(trigger: "trash changed")
            },
            onOpenNote: { id in
                showingTrash = false
                perform { try await selectNote(id) }
            }
        )
    }

    private func flattenedRows(
        inTrash: Bool,
        parentID: UUID? = nil,
        initialDepth: Int = 0
    ) -> [NotebookSidebarRow] {
        var result: [NotebookSidebarRow] = []
        for placement in replica.orderedChildren(
            parentID: parentID,
            inTrash: inTrash
        ) {
            result.append(NotebookSidebarRow(
                placement: placement,
                depth: initialDepth
            ))
            if placement.item.kind == .folder, expandedIDs.contains(placement.item.id) {
                result.append(
                    contentsOf: flattenedRows(
                        inTrash: inTrash,
                        parentID: placement.item.id,
                        initialDepth: initialDepth + 1
                    ))
            }
        }
        return result
    }

    @ViewBuilder
    private func sidebarRow(_ row: NotebookSidebarRow) -> some View {
        if let placement = replica.placements.first(where: { $0.item.id == row.id }) {
            HStack(spacing: 6) {
                if placement.item.kind == .folder {
                    Button { toggleFolder(row.id) } label: {
                        disclosureIcon(expanded: expandedIDs.contains(row.id))
                            .frame(minWidth: 20, minHeight: sidebarRowHeight)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(placement.displayName)
                    .accessibilityValue(expandedIDs.contains(row.id) ? "Expanded" : "Collapsed")
                    .accessibilityIdentifier("notebook-disclosure-" + row.id.uuidString)
                } else {
                    Color.clear.frame(width: 20, height: 1)
                }
                if editingID == row.id {
                    TextField("Name", text: $proposedName)
                        .textFieldStyle(.plain)
                        .focused($focusedNameID, equals: row.id)
                        .disabled(busy)
                        .onSubmit { submitInlineName() }
                        .notebookEscapeAction { cancelInlineName() }
                        .notebookSelectNameOnFocus()
                } else {
                    Label {
                        Text(placement.item.kind == .note
                            ? NotebookNoteName.title(from: placement.displayName)
                            : placement.displayName)
                            .accessibilityIdentifier("notebook-sidebar-title-" + row.id.uuidString)
                    } icon: {
                        Image(systemName: placement.item.kind == .folder
                            ? (replica.defaultNewNoteParentID == row.id ? "tray" : "folder")
                            : "note.text")
                    }
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        #if os(macOS)
                        .simultaneousGesture(TapGesture().onEnded {
                            guard !selectingItems, !busy,
                                  NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty
                            else { return }
                            // List owns range/toggle selection. A plain click also
                            // opens the note, including an already selected row.
                            browserSelection.selectOnly(row.id)
                            activateSidebarRow(placement)
                        })
                        #endif
                        .accessibilityAddTraits(
                            browserSelection.contains(row.id) ? .isSelected : []
                        )
                    if !placement.issues.isEmpty {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Recovered placement or metadata conflict")
                    }
                }
            }
            .padding(.leading, CGFloat(row.depth) * 16)
            .frame(minHeight: sidebarRowHeight)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(
                        highlightedFileID == row.id ? 0.16 : 0
                    ))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor.opacity(
                        highlightedFileID == row.id ? 0.65 : 0
                    ), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
            .accessibilityElement(children: .contain)
            .accessibilityValue(
                highlightedFileID == row.id ? "Revealed in Files" : ""
            )
            .accessibilityIdentifier(
                (placement.item.kind == .note
                    ? "notebook-sidebar-note-" : "notebook-sidebar-folder-") + row.id.uuidString)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if !selectingItems, editingID == nil {
                    Button(role: .destructive) { trashItems([row.id]) } label: {
                        Label("Trash", systemImage: "trash")
                    }
                    .accessibilityIdentifier("notebook-swipe-trash")
                }
            }
        }
    }

    private func activateSidebarRow(_ placement: NotebookPlacement) {
        guard !busy, editingID == nil, !selectingItems else { return }
        perform {
            if placement.item.kind == .note { try await selectNote(placement.item.id) }
        }
    }

    private func disclosureIcon(expanded: Bool) -> some View {
        Image(systemName: expanded ? "chevron.down" : "chevron.right")
            .font(.caption)
            .frame(width: 10)
            .foregroundStyle(Color.secondary)
    }

    private func toggleFolder(_ id: UUID) {
        if expandedIDs.contains(id) {
            expandedIDs.remove(id)
        } else {
            expandedIDs.insert(id)
        }
    }

    private func sortMenu(
        parentID: UUID?,
        label: LocalizedStringResource
    ) -> some View {
        Menu {
            Button("Name, A–Z") { sort(parentID, by: .nameAscending) }
            Button("Name, Z–A") { sort(parentID, by: .nameDescending) }
            Divider()
            Button("Created, Newest First") {
                sort(parentID, by: .createdNewest)
            }
            Button("Created, Oldest First") {
                sort(parentID, by: .createdOldest)
            }
            Button("Modified, Newest First") {
                sort(parentID, by: .modifiedNewest)
            }
            Button("Modified, Oldest First") {
                sort(parentID, by: .modifiedOldest)
            }
        } label: {
            Label(label, systemImage: "arrow.up.arrow.down")
        }
        .disabled(busy)
    }

    @ViewBuilder
    private func creationActions(parentID: UUID?) -> some View {
        Button("New Note") { createItem(kind: .note, parentID: parentID) }
            .disabled(busy)
        Button("New Folder") { createItem(kind: .folder, parentID: parentID) }
            .disabled(busy)
    }

    @ViewBuilder
    private func actions(
        for placement: NotebookPlacement, allowsCreation: Bool = true,
        allowsRename: Bool = true, allowsShowInFiles: Bool = false
    ) -> some View {
        if allowsCreation, !placement.isInTrash {
            creationActions(parentID: creationParent(for: placement))
            Divider()
        }
        if placement.item.kind == .note, !placement.isInTrash,
           supportsMultipleWindows {
            Button("Open in New Window") {
                openWindow(
                    id: "notebook",
                    value: NotebookWindowValue(noteID: placement.item.id)
                )
            }
            Divider()
        }
        if allowsRename { Button("Rename…") { beginRenaming(placement) } }
        Button("Move…") {
            beginMoving([placement.item.id], fromTrash: placement.isInTrash)
        }
        if !placement.isInTrash, placement.item.kind == .note {
            if allowsShowInFiles {
                Button("Show in Files") { showInFiles(placement.item.id) }
                    .accessibilityIdentifier("notebook-show-in-files")
            }
            recentPinButton(for: placement.item.id)
        }
        if placement.isInTrash {
            if placement.item.isTrashed {
                Button("Restore") { changeTrash(placement, trashed: false) }
            } else {
                Text("Restore the parent folder, or move this item out.")
            }
            Divider()
            Button("Delete Permanently…", role: .destructive) {
                prepareDeletion(rootID: placement.item.id)
            }
            .disabled(busy)
        } else {
            if placement.item.kind == .folder {
                let isDefault = replica.defaultNewNoteParentID == placement.item.id
                Button {
                    setDefaultNewNoteParentID(isDefault ? nil : placement.item.id)
                } label: {
                    Label(
                        isDefault ? "Use Root for New Notes" : "Use for New Notes",
                        systemImage: isDefault ? "folder" : "tray"
                    )
                }
                .disabled(busy)
                Divider()
            }
            Button("Move to Trash", role: .destructive) {
                changeTrash(placement, trashed: true)
            }
            if placement.item.kind == .folder {
                Divider()
                sortMenu(
                    parentID: placement.item.id,
                    label: "Sort Folder Once"
                )
            }
        }
    }

    private func creationParent(for placement: NotebookPlacement) -> UUID? {
        placement.item.kind == .folder ? placement.item.id : placement.item.parentID
    }

    private func beginMoving(_ ids: [UUID], fromTrash: Bool = false) {
        guard !busy, !ids.isEmpty else { return }
        let sources = effectiveSelectionRoots(ids)
        let parents = Set(sources.map(\.parentID))
        destination = parents.count == 1 ? sources.first?.parentID : nil
        movingNotebookID = replica.catalogSnapshot?.notebookID
        movingFromTrash = fromTrash
        movingIDs = ids
    }

    private var moveSheet: some View {
        NotebookMoveSheet(
            placements: replica.placements,
            sourceIDs: movingIDs,
            initialParentID: destination,
            isDestinationAllowed: { canMoveSelection(into: $0) },
            onSubmit: { parentID in
                #if DEBUG
                // Make the in-flight layout observable in isolated UI tests.
                if NotebookWorkspace.isPreviewEnabled,
                   ProcessInfo.processInfo.environment["MEH_NOTEBOOK_MOVE_TEST_DELAY"] == "1" {
                    try await Task.sleep(for: .seconds(8))
                }
                #endif
                try await commitMove(to: parentID)
            },
            onSuccess: {}
        )
    }

    private func createItem(
        kind: NotebookItemKind, parentID: UUID?,
        usesDefaultDestination: Bool = false
    ) {
        perform {
            try await flushEditor()
            let destinationID = usesDefaultDestination
                ? replica.defaultNewNoteParentID : parentID
            if let destinationID { expandedIDs.insert(destinationID) }
            switch kind {
            case .note:
                let siblingNames = replica.placements.compactMap { placement in
                    placement.parentID == destinationID && !placement.isInTrash
                        ? placement.item.name : nil
                }
                let name = NotebookNoteName.defaultFilename(
                    existingNames: siblingNames
                )
                let id = try await (usesDefaultDestination
                    ? replica.createNoteInDefaultFolder(name: name)
                    : replica.createNote(name: name, parentID: parentID))
                reveal(id)
                try await selectNote(id)
                detailEditingID = id
                detailOriginalName = name
                detailProposedTitle = NotebookNoteName.title(from: name)
                detailTitleHeight = 32
                selectGeneratedTitle = true
            case .folder:
                let id = try await replica.createFolder(
                    name: "Untitled Folder", parentID: parentID)
                beginRenaming(id: id, name: "Untitled Folder")
            }
        }
    }

    #if os(iOS)
    private func handlePendingNewNoteAction() {
        guard restoredNavigation, !busy, quickActionRequests.takeNewNote()
        else { return }
        createDefaultNote()
    }
    #endif

    private func createDefaultNote() {
        createItem(kind: .note, parentID: nil, usesDefaultDestination: true)
    }

    private func setDefaultNewNoteParentID(_ id: UUID?) {
        perform {
            try await replica.setDefaultNewNoteParentID(id)
        }
    }

    private func beginRenaming(_ placement: NotebookPlacement) {
        perform {
            try await flushEditor()
            reveal(placement.item.id)
            beginRenaming(id: placement.item.id, name: placement.item.name)
        }
    }

    private func beginRenaming(id: UUID, name: String) {
        preferredCompactColumn = .sidebar
        editingID = id
        originalName = name
        proposedName = name
        Task { @MainActor in
            focusedNameID = id
            #if os(macOS)
                await Task.yield()
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            #endif
        }
    }

    private func beginDetailRenaming(_ placement: NotebookPlacement) {
        perform {
            try await flushEditor()
            detailEditingID = placement.item.id
            detailOriginalName = placement.item.name
            detailProposedTitle = NotebookNoteName.title(from: placement.item.name)
            focusedTitleID = placement.item.id
        }
    }

    private func submitDetailTitle(focusBody: Bool = true) {
        guard detailEditingID != nil else { return }
        perform {
            try await commitDetailTitleIfNeeded()
        } onSuccess: {
            if focusBody { bodyFocusRequest &+= 1 }
        }
    }

    private func commitDetailTitleIfNeeded() async throws {
        guard let id = detailEditingID else { return }
        let filename = NotebookNoteName.filename(
            for: detailProposedTitle,
            preservingExtensionFrom: detailOriginalName
        )
        let changed = replica.placements.first { $0.item.id == id }?.item.name != filename
        if changed {
            try await replica.rename(id, to: filename)
        }
        detailEditingID = nil
        focusedTitleID = nil
        detailOriginalName = ""
        detailProposedTitle = ""
    }

    private func cancelDetailTitle() {
        detailEditingID = nil
        focusedTitleID = nil
        detailOriginalName = ""
        detailProposedTitle = ""
        editorNavigation.resumeEditing?()
    }

    private func submitInlineName() {
        perform { try await commitInlineNameIfNeeded() }
    }

    private func commitInlineNameIfNeeded() async throws {
        guard let id = editingID else { return }
        let placement = replica.placements.first { $0.item.id == id }
        let name =
            placement?.item.kind == .note
            ? NotebookNoteName.filename(
                for: NotebookNoteName.title(from: proposedName),
                preservingExtensionFrom: originalName
            ) : proposedName
        if placement?.item.name != name {
            try await replica.rename(id, to: name)
        }
        editingID = nil
        focusedNameID = nil
        originalName = ""
        proposedName = ""
        if placement?.item.kind == .note, selectedID == id {
            preferredCompactColumn = .detail
        }
    }

    private func cancelInlineName() {
        proposedName = originalName
        editingID = nil
        focusedNameID = nil
        originalName = ""
    }

    private func changeTrash(_ placement: NotebookPlacement, trashed: Bool) {
        if trashed {
            trashItems([placement.item.id])
            return
        }
        perform {
            try await flushEditor()
            try await replica.setTrashed(placement.item.id, trashed)
            reveal(placement.item.id)
        }
    }

    private var emptyTrashAction: some View {
        Button("Empty Trash…", role: .destructive) { prepareDeletion(rootID: nil) }
            .disabled(busy || !replica.placements.contains(where: \.isInTrash))
            .accessibilityIdentifier("notebook-empty-trash")
    }

    private func prepareDeletion(rootID: UUID?) {
        perform {
            try await flushEditor()
            deletionSelection = try replica.deletionSelection(rootID: rootID)
        }
    }

    private func deletionMessage(_ selection: NotebookDeletionSelection) -> String {
        let notes = selection.items.filter { $0.kind == .note }.count
        let folders = selection.items.count - notes
        let counts = [
            notes > 0 ? "\(notes) \(notes == 1 ? "note" : "notes")" : nil,
            folders > 0 ? "\(folders) \(folders == 1 ? "folder" : "folders")" : nil,
        ].compactMap { $0 }.joined(separator: " and ")
        let names = selection.items.prefix(5).map(\.name).joined(separator: ", ")
        let remainder = selection.items.count > 5 ? ", …" : ""
        return "Delete \(counts): \(names)\(remainder)? "
            + "This cannot be undone. Other devices remove these items when they sync. "
            + "Original files you imported are kept."
    }

    private func deletePermanently(_ selection: NotebookDeletionSelection) {
        deletionSelection = nil
        perform {
            try await flushEditor()
            try await replica.permanentlyDelete(selection)
            if let receipt = browserUndo,
               !selection.ids.isDisjoint(with: receipt.itemIDs) {
                browserUndo = nil
            }
            if let receipt = browserRedo,
               !selection.ids.isDisjoint(with: receipt.itemIDs) {
                browserRedo = nil
            }
            if let selectedID, selection.ids.contains(selectedID) {
                navigationState.clearSelection()
                unrecordedEdit = false
                preferredCompactColumn = .sidebar
            }
            expandedIDs.subtract(selection.ids)
            workspace?.contentDidSave(trigger: "permanent deletion")
        }
    }

    private func reveal(_ id: UUID) {
        var next = replica.placements.first { $0.item.id == id }
        while let parentID = next?.parentID {
            expandedIDs.insert(parentID)
            next = replica.placements.first { $0.item.id == parentID }
        }
    }

    private func showInFiles(_ id: UUID) {
        search.isPresented = false
        navigationState.isTreeExpanded = true
        reveal(id)
        preferredCompactColumn = .sidebar
        fileRevealRequest = NotebookFileReveal(id: id)
    }

    private func commitMove(to parentID: UUID?) async throws {
        guard !busy else { throw NotebookReplicaError.busy }
        let ids = movingIDs
        let notebookID = movingNotebookID
        let fromTrash = movingFromTrash
        busy = true
        defer {
            editorNavigation.resumeEditing?()
            busy = false
        }
        try await flushEditor()
        guard notebookID == replica.catalogSnapshot?.notebookID else {
            throw NotebookBrowserChangeError.invalidSelection
        }
        guard ids == movingIDs, canMoveSelection(into: parentID) else {
            throw NotebookBrowserChangeError.invalidSelection
        }
        if fromTrash {
            guard ids.count == 1, let id = ids.first,
                  replica.placements.first(where: { $0.item.id == id })?.isInTrash == true
            else { throw NotebookBrowserChangeError.invalidSelection }
            try await replica.move(id, to: parentID)
            browserUndo = nil
            browserRedo = nil
        } else if !selectionAlreadyAtDestination(ids, parentID: parentID) {
            let previousHeads = replica.catalogSnapshot?.heads
            let receipt = try await replica.moveItems(ids, to: parentID)
            if replica.catalogSnapshot?.heads != previousHeads {
                browserUndo = receipt
                browserRedo = nil
            }
        }
        if let parentID { expandedIDs.insert(parentID) }
        for id in ids { reveal(id) }
        browserSelection.clear()
        selectingItems = false
        movingIDs = []
    }

    private func effectiveSelectionRoots(_ ids: [UUID]) -> [NotebookPlacement] {
        let selected = Set(ids)
        return replica.placements.filter { placement in
            guard selected.contains(placement.item.id) else { return false }
            var ancestor = placement.parentID
            var visited = Set<UUID>()
            while let id = ancestor, visited.insert(id).inserted {
                if selected.contains(id) { return false }
                ancestor = replica.placements.first { $0.item.id == id }?.parentID
            }
            return true
        }
    }

    private func selectionAlreadyAtDestination(_ ids: [UUID], parentID: UUID?) -> Bool {
        let roots = effectiveSelectionRoots(ids)
        return !roots.isEmpty && roots.allSatisfy {
            $0.parentID == parentID && $0.item.parentID == parentID && $0.issues.isEmpty
        }
    }

    private func trashItems(
        _ ids: [UUID], onCompletion: @escaping (Bool) -> Void = { _ in }
    ) {
        perform({
            try await flushEditor()
            browserUndo = try await replica.trashItems(ids)
            browserRedo = nil
            browserSelection.clear()
            selectingItems = false
        }, onCompletion: onCompletion)
    }

    private func undoBrowserChange(redo: Bool) {
        guard let receipt = redo ? browserRedo : browserUndo else { return }
        perform {
            try await flushEditor()
            let inverse: NotebookBrowserUndo
            do {
                inverse = try await replica.undoBrowserChange(receipt)
            } catch let error as NotebookBrowserChangeError {
                if error == .staleUndo || error == .notebookIdentityMismatch {
                    if redo { browserRedo = nil } else { browserUndo = nil }
                }
                throw error
            }
            if redo {
                browserRedo = nil
                browserUndo = inverse
            } else {
                browserUndo = nil
                browserRedo = inverse
            }
            for id in receipt.itemIDs { reveal(id) }
        }
    }

    private func canMoveSelection(into parentID: UUID?) -> Bool {
        guard !movingIDs.isEmpty,
              movingNotebookID == replica.catalogSnapshot?.notebookID,
              movingIDs.allSatisfy({ id in
                  replica.placements.contains {
                      $0.item.id == id && !$0.item.isPermanentlyDeleted
                          && ($0.isInTrash == movingFromTrash)
                  }
              }) else { return false }
        let sources = Set(movingIDs)
        var ancestor = parentID
        var visited = Set<UUID>()
        while let id = ancestor {
            guard !sources.contains(id), visited.insert(id).inserted,
                  let placement = replica.placements.first(where: { $0.item.id == id }),
                  !placement.isInTrash, placement.item.kind == .folder
            else { return false }
            ancestor = placement.parentID
        }
        return true
    }

    private func sort(_ parentID: UUID?, by order: NotebookSortOrder) {
        perform {
            try await flushEditor()
            try await replica.sortChildren(parentID: parentID, by: order)
        }
    }

    private func importMarkdown(_ plan: NotebookImportPlan?) async throws {
        guard !busy else { throw NotebookReplicaError.busy }
        busy = true
        defer {
            editorNavigation.resumeEditing?()
            busy = false
        }
        try await flushEditor()
        if let plan {
            try await replica.importMarkdown(plan)
            expandedIDs.formUnion(plan.entries.filter { $0.kind == .folder }.map(\.id))
        } else {
            try await replica.resumePendingImport()
        }
        workspace?.contentDidSave(trigger: "import completed")
        preferredCompactColumn = .sidebar
    }


    private var isPhoneLayout: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    private var searchTaskID: SearchTaskID {
        SearchTaskID(revision: replica.searchRevision, query: search.activeQuery,
                     active: search.isPresented || search.showingQuickOpen,
                     quick: search.showingQuickOpen, recents: navigationState.recentNoteIDs)
    }

    private var libraryBrowser: some View {
        ScrollViewReader { scrollProxy in
            #if os(iOS)
            NotebookRecentsExpansionHost(
                items: allRecentUIKitItems,
                compactCount: recentPlacements.count,
                isExpanded: $browsingAllRecents,
                rowContent: { id, index, count in
                    if let placement = replica.placements.first(where: { $0.item.id == id }) {
                        recentRow(placement, index: index, count: count)
                    }
                },
                onTogglePin: { id in
                    setRecentPinned(!replica.isPinnedInRecents(id), for: id)
                },
                onTrash: { id, completion in
                    trashItems([id], onCompletion: completion)
                },
                contextMenu: recentUIKitMenu,
                onVisibleIDs: { visibleRecentPreviewIDs = $0 },
                browser: { hidesCompactRows in
                    libraryList(scrollProxy: scrollProxy, hidesCompactRows: hidesCompactRows)
                }
            )
            #else
            NotebookMacRecentsExpansionHost(
                items: allRecentPlacements,
                selectedNoteID: selectedID,
                isExpanded: $browsingAllRecents,
                onSelect: { id in
                    guard id != selectedID else { return }
                    perform { try await selectNote(id) }
                },
                onCollapse: collapseMacRecents,
                onVisibleIDs: { visibleRecentPreviewIDs = $0 },
                rowContent: { placement, index, count in
                    // The card supplies the fill. Opaque row backgrounds would
                    // hide native selection while its text turns white.
                    recentRow(placement, index: index, count: count,
                              showsCardBackground: false)
                },
                browser: {
                    libraryList(scrollProxy: scrollProxy, hidesCompactRows: false)
                }
            )
            #endif
        }
    }

    #if os(iOS)
    private var allRecentUIKitItems: [NotebookRecentUIKitItem] {
        let placements = Dictionary(uniqueKeysWithValues:
            replica.placements.map { ($0.item.id, $0) })
        return replica.allRecentNotes.compactMap { recent in
            guard let placement = placements[recent.id] else { return nil }
            return NotebookRecentUIKitItem(
                id: recent.id,
                title: NotebookNoteName.title(from: placement.displayName),
                preview: recentPreview(for: recent.id),
                isCurrent: showsCurrentNote && selectedID == recent.id,
                isPinned: recent.isPinned,
                // The full projection already excludes unavailable notes.
                canPin: replica.canPinInRecents
            )
        }
    }
    #endif

    private func libraryList(
        scrollProxy: ScrollViewProxy, hidesCompactRows: Bool
    ) -> some View {
        List(selection: nativeBrowserSelection) {
            recentsSection(hidesCompactRows: hidesCompactRows)
            Section {
                if navigationState.isTreeExpanded {
                    activeTree
                        .opacity(hidesCompactRows ? 0 : 1)
                        .accessibilityHidden(hidesCompactRows)
                }
            } header: {
                NotebookSectionToggle(
                    title: "Files",
                    isExpanded: navigationState.isTreeExpanded,
                    identifier: "notebook-tree-toggle"
                ) { navigationState.isTreeExpanded.toggle() }
                .opacity(hidesCompactRows ? 0 : 1)
                .accessibilityHidden(hidesCompactRows)
                .textCase(nil)
                .listRowInsets(sidebarSectionInsets)
                #if os(iOS)
                .background(NotebookBrowserScrollReader(reference: browserScrollView))
                #endif
            }
        }
        .listStyle(.plain)
        #if os(iOS)
        .listSectionSpacing(12)
        .listSectionMargins(.top, 8)
        .listSectionMargins(.bottom, 0)
        .onScrollGeometryChange(for: NotebookBrowserViewport.self) { geometry in
            NotebookBrowserViewport(offset: geometry.contentOffset.y,
                                    bottomInset: geometry.contentInsets.bottom,
                                    size: geometry.containerSize)
        } action: { _, viewport in
            browserViewport = viewport
            restoreBrowserViewportIfReady()
        }
        .onScrollPhaseChange { _, phase in
            if phase == .tracking || phase == .interacting {
                browserReturnViewport = nil
                browserToolbarWasHidden = false
            }
        }
        #endif
        .scrollContentBackground(.hidden)
        .background(NotebookSidebarPalette.background)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if editingID == nil {
                if ids.count == 1, let id = ids.first,
                   let placement = replica.placements.first(where: { $0.item.id == id }) {
                    browserRowActions(for: placement)
                } else if !ids.isEmpty {
                    Button("Move Selected…") {
                        beginMoving(browserSelection.orderedIDs(in: activeBrowserOrder))
                    }
                    Button("Trash Selected", role: .destructive) {
                        trashItems(browserSelection.orderedIDs(in: activeBrowserOrder))
                    }
                }
            }
        } primaryAction: { ids in
            guard ids.count == 1, let id = ids.first,
                  let placement = replica.placements.first(where: { $0.item.id == id })
            else { return }
            activateSidebarRow(placement)
        }
        .focused($browserFocused)
        .onKeyPress { press in
            guard browserFocused, editingID == nil, detailEditingID == nil,
                  !search.isPresented, !busy else { return .ignored }
            if press.modifiers.contains(.command), press.characters == "a" {
                browserSelection.selectAll(visibleActiveRows.map(\.id))
                return .handled
            }
            if press.modifiers.contains([.command, .shift]),
               press.characters.lowercased() == "m", !browserSelection.isEmpty {
                beginMoving(browserSelection.orderedIDs(in: activeBrowserOrder))
                return .handled
            }
            if press.key == .delete, press.modifiers.contains(.command),
               !browserSelection.isEmpty {
                trashItems(browserSelection.orderedIDs(in: activeBrowserOrder))
                return .handled
            }
            if press.key == .return, browserSelection.count == 1,
               let id = browserSelection.selectedIDs.first,
               let placement = replica.placements.first(where: { $0.item.id == id }) {
                activateSidebarRow(placement)
                return .handled
            }
            return .ignored
        }
        .onChange(of: preferredCompactColumn) { _, column in
            #if os(iOS)
            if horizontalSizeClass == .compact {
                if column == .detail {
                    browserReturnViewport = browserViewport
                    browserToolbarWasHidden = false
                } else if column == .sidebar {
                    restoreBrowserViewportIfReady()
                }
            }
            if horizontalSizeClass == .compact, column == .sidebar {
                rememberEditorPosition()
                navigationState.recordClosed()
            }
            #endif
            if isPhoneLayout, column == .sidebar, !selectingItems {
                browserSelection.clear()
            }
        }
        .task(id: fileRevealRequest) {
            guard let request = fileRevealRequest else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation { scrollProxy.scrollTo(request.id, anchor: .center) }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) {
                highlightedFileID = request.id
            }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.4)) {
                highlightedFileID = nil
            }
            fileRevealRequest = nil
        }
        #if os(iOS)
        .environment(\.editMode, Binding(
            get: { selectingItems ? .active : .inactive },
            set: { selectingItems = $0.isEditing }
        ))
        #endif
    }

    #if os(iOS)
    private func restoreBrowserViewportIfReady() {
        guard let saved = browserReturnViewport, let viewport = browserViewport else { return }
        guard viewport.size == saved.size, fileRevealRequest == nil else {
            browserReturnViewport = nil
            return
        }
        if viewport.bottomInset < saved.bottomInset - 0.5 {
            browserToolbarWasHidden = true
            return
        }
        guard browserToolbarWasHidden, preferredCompactColumn == .sidebar,
              viewport.bottomInset >= saved.bottomInset - 0.5,
              abs(viewport.offset - saved.offset) > 0.5,
              let scrollView = browserScrollView.value else { return }
        // Hiding the bottom toolbar can clamp an offscreen list's offset.
        // Restore only once its search toolbar has returned to the safe area.
        // Keep the snapshot through cancelled swipe-back transitions until
        // the next browser pan or note opening establishes a new position.
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: saved.offset), animated: false
        )
    }
    #endif

    private var libraryNewNote: some View {
        Button { createDefaultNote() } label: {
            Label("New Note", systemImage: "plus")
        }
        .disabled(busy)
        .accessibilityIdentifier("notebook-new-item")
    }

    private var applicationMenu: some View {
        Menu {
            if supportsMultipleWindows {
                Button("New Window") {
                    openWindow(id: "notebook", value: NotebookWindowValue())
                }
                Divider()
            }
            Button("Select Items") {
                selectingItems = true
                navigationState.isTreeExpanded = true
                browserSelection.clear()
            }
            .accessibilityIdentifier("notebook-select-items")
            sortMenu(parentID: nil, label: "Sort Files Once")
                .accessibilityIdentifier("notebook-sort-root")
            Button("New Folder") { createItem(kind: .folder, parentID: nil) }
            browserUndoActions
            Divider()
            if isPhoneLayout {
                Button { showingSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .accessibilityIdentifier("notebook-settings")
                Button { openTrash() } label: {
                    Label("Trash", systemImage: "trash")
                }
                .accessibilityIdentifier("notebook-trash-toggle")
            }
        } label: {
            Label("Browser Actions", systemImage: "ellipsis")
        }
        .disabled(busy)
        .accessibilityIdentifier("notebook-app-menu")
    }

    private func openTrash() {
        perform {
            try await flushEditor()
            showingTrash = true
        }
    }

    private func showFind() {
        guard !busy, !search.showingQuickOpen else { return }
        searchFocused = false
        editorNavigation.showFind?()
    }

    private func showQuickOpen() {
        guard !busy, !search.showingQuickOpen, !showingSettings,
              !showingTrash, !showingImport else { return }
        resumeEditorAfterQuickOpen = editorNavigation.captureHasEditingFocus?() == true
        // Commit native marked-text safely before moving focus to the picker.
        guard editorNavigation.prepareToLeave?() != false, !unrecordedEdit else {
            errorMessage = NotebookNavigationError.unrecordedEdit.localizedDescription
            editorNavigation.resumeEditing?()
            return
        }
        searchFocused = false
        quickOpenDidNavigate = false
        search.beginQuickOpen()
    }

    private func openSearchResult(
        _ result: NotebookSearchResult, query: String, fromQuickOpen: Bool = false
    ) {
        perform {
            guard replica.placements.contains(where: {
                $0.item.id == result.id && !$0.isInTrash && !$0.item.isPermanentlyDeleted
            }) else { return }
            // Save ordinary position before marking this visit as a search jump.
            rememberEditorPosition()
            searchFocused = false
            let scope = workspace?.searchScopeGeneration
            let notebookID = replica.catalogSnapshot?.notebookID
            try await selectNote(result.id, searchVisit: true)
            guard selectedID == result.id, scope == workspace?.searchScopeGeneration,
                  notebookID == replica.catalogSnapshot?.notebookID,
                  replica.placements.contains(where: {
                      $0.item.id == result.id && !$0.isInTrash && !$0.item.isPermanentlyDeleted
                  }) else { return }
            searchDestinationID = result.id
            pendingSearchQuery = query.isEmpty ? nil : query
            if fromQuickOpen {
                quickOpenDidNavigate = true
                search.showingQuickOpen = false
            }
            let incoming = editorNavigation
            incoming.whenAttached { [weak incoming] in
                guard let incoming, selectedID == result.id else { return }
                revealSearchDestination(in: incoming)
            }
        }
    }

    private func revealSearchDestination(in navigation: MarkdownEditorNavigation) {
        guard let text = session?.text else { return }
        var match = NSRange(location: 0, length: 0)
        if let query = pendingSearchQuery, !query.isEmpty {
            if let found = text.range(of: query, options: .caseInsensitive,
                                      locale: Locale(identifier: "en_US_POSIX")) {
                match = NSRange(found, in: text)
            }
        }
        navigation.revealSearchMatch?(match)
        searchLandingPosition = navigation.capturePosition?()
    }

    private func shareMarkdown() {
        guard let session, let noteID = selectedID else { return }
        perform {
            try await flushEditor()
            guard selectedID == noteID, session.isEditingEnabled,
                  let placement = selectedPlacement else { return }
            sharedFile = try NotebookSharedFile.markdown(
                text: session.text, filename: placement.displayName
            )
        }
    }

    private func flushEditor() async throws {
        try await commitInlineNameIfNeeded()
        try await commitDetailTitleIfNeeded()
        // Unavailable notes have no editable buffer to flush. They must not
        // trap navigation while the user chooses whether to recover them.
        guard session?.isEditingEnabled == true else { return }
        guard editorNavigation.prepareToLeave?() != false, !unrecordedEdit else {
            throw NotebookNavigationError.unrecordedEdit
        }
        try await session?.flush()
        rememberEditorPosition()
    }

    private func openHistory() {
        guard historyBrowser == nil, !busy, let session, let selectedID else { return }
        isLoadingHistory = true
        busy = true
        historyLoadTask = Task { @MainActor in
            defer {
                isLoadingHistory = false
                busy = false
                historyLoadTask = nil
            }
            do {
                try await flushEditor()
                guard var heads = session.currentSnapshot?.heads else {
                    throw NotebookNavigationError.unavailableHistory
                }
                var currentText = session.text
                let position = editorNavigation.capturePosition?()
                var versions: [NoteHistoryVersion] = []
                for attempt in 0...1 {
                    versions = try await session.loadHistoryVersions()
                    try Task.checkCancellation()
                    guard self.selectedID == selectedID,
                          self.session === session else { return }
                    if session.currentSnapshot?.heads == heads { break }
                    guard attempt == 0 else {
                        throw NotebookNavigationError.changedDuringHistoryLoad
                    }
                    guard let updatedHeads = session.currentSnapshot?.heads else {
                        throw NotebookNavigationError.unavailableHistory
                    }
                    heads = updatedHeads
                    currentText = session.text
                }
                historyBrowser = NoteHistoryBrowserState(
                    noteID: selectedID,
                    versions: versions,
                    expectedHeads: heads,
                    originalPosition: position,
                    text: currentText
                )
                editorNavigation.invalidate()
            } catch is CancellationError {
                editorNavigation.resumeEditing?()
            } catch {
                editorNavigation.resumeEditing?()
                errorMessage = error.localizedDescription
            }
        }
    }

    private func closeHistory() {
        guard let historyBrowser else { return }
        historyBrowser.navigation.invalidate()
        self.historyBrowser = nil
        editorNavigation = MarkdownEditorNavigation()
    }

    private func restoreHistoryInPlace() {
        guard let historyBrowser,
              let version = historyBrowser.selectedVersion,
              let session else { return }
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            do {
                try await session.restoreHistoryVersion(
                    version, expectedHeads: historyBrowser.expectedHeads
                )
                if self.historyBrowser === historyBrowser { closeHistory() }
                workspace?.contentDidSave(trigger: "note restored")
                workspace?.noteDidEdit()
            } catch NoteHistoryError.currentChanged {
                if self.historyBrowser === historyBrowser {
                    do {
                        isLoadingHistory = true
                        defer { isLoadingHistory = false }
                        guard var heads = session.currentSnapshot?.heads else {
                            throw NotebookNavigationError.unavailableHistory
                        }
                        var currentText = session.text
                        var versions: [NoteHistoryVersion] = []
                        for attempt in 0...1 {
                            versions = try await session.loadHistoryVersions()
                            if session.currentSnapshot?.heads == heads { break }
                            guard attempt == 0 else {
                                throw NotebookNavigationError.changedDuringHistoryLoad
                            }
                            guard let updatedHeads = session.currentSnapshot?.heads else {
                                throw NotebookNavigationError.unavailableHistory
                            }
                            heads = updatedHeads
                            currentText = session.text
                        }
                        if self.historyBrowser === historyBrowser {
                            historyBrowser.navigation.invalidate()
                            self.historyBrowser = NoteHistoryBrowserState(
                                noteID: historyBrowser.noteID,
                                versions: versions,
                                expectedHeads: heads,
                                originalPosition: historyBrowser.originalPosition,
                                text: currentText
                            )
                            errorMessage = String(localized:
                                "This note changed while History was open. Review the current version before restoring.")
                        }
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            } catch {
                if case .saveFailed = session.status,
                   self.historyBrowser === historyBrowser {
                    // The live text changed, but persistence failed. Show
                    // that text and the editor's Retry action.
                    closeHistory()
                }
                errorMessage = error.localizedDescription
            }
            busy = false
        }
    }

    private func restoreHistoryAsNewNote() {
        guard let historyBrowser,
              let version = historyBrowser.selectedVersion,
              let session,
              let placement = selectedPlacement else { return }
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            do {
                let text = try session.historicalText(for: version)
                let title = NotebookNoteName.title(from: placement.displayName)
                let siblings = replica.placements.compactMap { item in
                    item.parentID == placement.parentID && !item.isInTrash
                        ? item.item.name : nil
                }
                let name = NotebookNoteName.restoredFilename(
                    for: title, existingNames: siblings
                )
                let id = try await replica.createNote(
                    name: name, text: text, parentID: placement.parentID
                )
                if self.historyBrowser === historyBrowser { closeHistory() }
                try await selectNote(id)
            } catch {
                errorMessage = error.localizedDescription
            }
            busy = false
        }
    }

    private func rememberEditorPosition() {
        guard let selectedID,
              let position = editorNavigation.capturePosition?(),
              let data = try? JSONEncoder().encode(position) else { return }
        if searchDestinationID == selectedID {
            // A passive search jump preserves the ordinary position. Once the
            // reader moves elsewhere, that new position belongs to them.
            guard let landing = editorNavigation.searchLandingPosition
                    ?? searchLandingPosition,
                  position.selection != landing.selection
                    || position.scrollAnchor != landing.scrollAnchor
                    || abs(position.scrollAnchorOffset - landing.scrollAnchorOffset) > 2
            else { return }
            searchDestinationID = nil
            searchLandingPosition = nil
        }
        navigationState.setPosition(data, for: selectedID)
    }

    private func selectNote(
        _ id: UUID, revealDetail: Bool = true, searchVisit: Bool = false
    ) async throws {
        if id != selectedID {
            try await flushEditor()
            searchDestinationID = nil
            pendingSearchQuery = nil
            let notebookID = replica.catalogSnapshot?.notebookID
            let openedSession = try await replica.openNote(id, allowingRecovery: true)
            if searchVisit {
                guard replica.catalogSnapshot?.notebookID == notebookID,
                      replica.placements.contains(where: {
                          $0.item.id == id && !$0.isInTrash && !$0.item.isPermanentlyDeleted
                      }) else { return }
            }
            if navigationState.installSelection(id, session: openedSession, recordActivity: true) {
                editorNavigation.invalidate()
                editorNavigation = MarkdownEditorNavigation()
            }
        } else {
            if editingID != nil || detailEditingID != nil { try await flushEditor() }
            if !searchVisit, searchDestinationID == id {
                rememberEditorPosition()
                searchDestinationID = nil
                searchLandingPosition = nil
                if let data = navigationState.position(for: id),
                   let position = try? JSONDecoder().decode(MarkdownEditorPosition.self, from: data) {
                    editorNavigation.restorePosition?(position)
                }
            }
            navigationState.recordOpened(id)
        }
        if revealDetail { preferredCompactColumn = .detail }
    }

    private func perform(
        _ operation: @escaping @MainActor () async throws -> Void,
        onSuccess: @escaping @MainActor () -> Void = {},
        onCompletion: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        guard !busy else {
            onCompletion(false)
            return
        }
        busy = true
        Task { @MainActor in
            var succeeded = false
            do {
                try await operation()
                succeeded = true
            } catch {
                errorMessage = error.localizedDescription
                if let editingID {
                    Task { @MainActor in focusedNameID = editingID }
                } else if let detailEditingID {
                    Task { @MainActor in focusedTitleID = detailEditingID }
                }
            }
            editorNavigation.resumeEditing?()
            busy = false
            if succeeded { onSuccess() }
            onCompletion(succeeded)
        }
    }
}

private enum NotebookNavigationError: LocalizedError {
    case unrecordedEdit
    case unavailableHistory
    case changedDuringHistoryLoad
    var errorDescription: String? {
        switch self {
        case .unrecordedEdit:
            "Finish composing your text and resolve any edit error before leaving this note."
        case .unavailableHistory:
            "Version History is unavailable until this note finishes opening."
        case .changedDuringHistoryLoad:
            "This note changed while History was loading. Open History again to review the latest text."
        }
    }
}

extension View {
    @ViewBuilder
    fileprivate func notebookRecentPinAccessibilityAction(
        isPinned: Bool,
        isAvailable: Bool,
        action: @escaping () -> Void
    ) -> some View {
        if isPinned || isAvailable {
            accessibilityAction(
                named: Text(isPinned ? "Unpin from Recents" : "Pin in Recents")
            ) {
                action()
            }
        } else {
            self
        }
    }

    @ViewBuilder
    fileprivate func notebookSelectNameOnFocus() -> some View {
        #if os(iOS)
            onReceive(
                NotificationCenter.default.publisher(
                    for: UITextField.textDidBeginEditingNotification
                )
            ) { notification in
                guard let field = notification.object as? UITextField else { return }
                Task { @MainActor in field.selectAll(nil) }
            }
        #else
            self
        #endif
    }

    @ViewBuilder
    fileprivate func notebookEscapeAction(_ action: @escaping () -> Void) -> some View {
        #if os(macOS)
            onExitCommand(perform: action)
        #else
            self
        #endif
    }
}

private struct SearchTaskID: Hashable {
    let revision: NotebookSearchRevision
    let query: String
    let active: Bool
    let quick: Bool
    let recents: [UUID]
}
