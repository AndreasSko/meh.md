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
    var highlights = true
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

    func creationPosition(relativeTo id: UUID) -> NotebookCreationPosition {
        guard let list = value as? UICollectionView,
              let interaction = list.interactions.compactMap({
                  $0 as? UIContextMenuInteraction
              }).first,
              interaction.menuAppearance != .unknown else { return .after(id) }
        let point = interaction.location(in: list)
        guard list.bounds.contains(point),
              let indexPath = list.indexPathForItem(at: point),
              let attributes = list.layoutAttributesForItem(at: indexPath),
              attributes.frame.contains(point) else { return .after(id) }
        return point.y < attributes.frame.midY ? .before(id) : .after(id)
    }
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

private struct NotebookLinkRoute: Hashable {
    let id = UUID()
    let noteID: UUID
}

#if os(iOS)
private struct NotebookLinkVisitPreview {
    let text: String
    let position: MarkdownEditorPosition?
    let viewportInsets: UIEdgeInsets?
    let viewportOriginY: CGFloat?
    let titleHeight: CGFloat
}
#endif

struct NotebookView: View {
    let replica: NotebookReplica
    var workspace: NotebookWorkspace? = nil
    var incomingImports: NotebookIncomingImportRequests? = nil
    @State private var sharedImport: NotebookIncomingImport?
    @State private var sharedImportID: UUID?
    let sceneID: UUID
    let preferredNoteID: UUID?
    @State private var search = NotebookSearchState()
    @State private var links = NotebookLinkState()
    @State private var linkHistory = NotebookLinkNavigationHistory()
    @State private var linkJourneyID = UUID()
    @State private var showingBacklinks = false
    @State private var backlinkDeparture: NotebookLinkNavigationHistory.Visit?
    @State private var linkInsertion: NotebookLinkInsertionRequest?
    @State private var variableCompletionSelection = NSRange(location: 0, length: 0)
    @State private var snippetSourceNoteIDs: Set<UUID> = []
    @State private var variableCompletion: NotebookSnippetVariableCompletion?
    @State private var linkCompletion: NotebookLinkCompletion?
    @State private var linkCompletionText = ""
    @State private var linkCompletionSelection = 0
    @State private var linkChoices: [NotebookLinkNote] = []
    @State private var linkChoiceFragment: String?
    @State private var missingLink: NotebookLinkOccurrence?
    @Environment(\.openURL) private var openURL
    #if os(macOS)
    @State private var menu = NotebookMenuState()
    #endif
    @FocusState private var searchFocused: Bool
    @State private var pendingSearchQuery: String?
    @State private var searchDestinationID: UUID?
    @State private var quickOpenDidNavigate = false
    @State private var resumeEditorAfterQuickOpen = false
    @State private var searchLandingPosition: MarkdownEditorPosition?
    @State private var showingImport = false
    @State private var showingSettings = false
    @State private var showingTemplates = false
    @State private var pendingPresentedItemID: UUID?
    @State private var showingTrash = false
    @State private var showingTextSize = false
    @State private var sharedFile: NotebookSharedFile?
    @State private var historyBrowser: NoteHistoryBrowserState?
    @State private var isLoadingHistory = false
    @State private var historyLoadTask: Task<Void, Never>?
    @State private var historyLoadID = UUID()
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
    @State private var detailTitleFocusRequest: NotebookTitleFocusRequest?
    @State private var movingIDs: [UUID] = []
    @State private var movingFromTrash = false
    @State private var browserSelection = NotebookBrowserSelection()
    @State private var browserDrag = NotebookBrowserDragState()
    @State private var browserDropViewportFrame: CGRect = .zero
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
        @State private var pendingTemplateQuickAction = false
        @State private var awaitingQuickActionSheetDismissal = false
        @State private var browserScrollView = NotebookBrowserScrollReference()
        @State private var browserViewport: NotebookBrowserViewport?
        @State private var browserViewportHeight: CGFloat = 0
        @State private var browserReturnViewport: NotebookBrowserViewport?
        @State private var browserToolbarWasHidden = false
        @State private var linkRootRoute: NotebookLinkRoute?
        @State private var linkRoutes: [NotebookLinkRoute] = []
        @State private var activeLinkRouteID: UUID?
        @State private var restoringLinkRouteID: UUID?
        @State private var linkVisitPreviews: [UUID: NotebookLinkVisitPreview] = [:]
    #endif

    init(
        replica: NotebookReplica,
        workspace: NotebookWorkspace? = nil,
        incomingImports: NotebookIncomingImportRequests? = nil,
        sceneID: UUID,
        preferredNoteID: UUID? = nil
    ) {
        self.replica = replica
        self.workspace = workspace
        self.incomingImports = incomingImports
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
    #if os(macOS)
    private var menuAvailable: Bool {
        !busy && !search.showingQuickOpen && !showingSettings
            && !showingTrash && !showingImport && !showingTextSize
            && movingIDs.isEmpty && deletionSelection == nil
            && errorMessage == nil && sharedImportID == nil
            && !showingBacklinks && linkInsertion == nil
            && linkChoices.isEmpty && missingLink == nil
            && workspace?.isResetPending != true
    }
    #endif
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
                        showSettings: { openSettings() },
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
                        if let completion = variableCompletion, canCompleteSnippetVariable {
                            let completionText = linkCompletionText
                            let navigation = editorNavigation
                            let caret = variableCompletionSelection
                            NotebookSnippetVariableSuggestions(
                                variables: completion.suggestions,
                                selection: linkCompletionSelection,
                                title: selectedPlacement
                                    .map { NotebookNoteName.title(from: $0.displayName) } ?? "",
                                select: { variable in
                                    insertCompletedVariable(variable, completion: completion,
                                        textSnapshot: completionText, sourceID: selectedID,
                                        selection: caret, navigation: navigation)
                                },
                                dismiss: { dismissEditorCompletion() }
                            )
                        }
                        if let completion = linkCompletion, historyBrowser == nil {
                            let completionText = linkCompletionText
                            NotebookLinkSuggestions(
                                notes: completion.query.contains("#") ? [] : links.suggestions(for: completion.query),
                                isLoading: links.isLoading,
                                selection: linkCompletionSelection,
                                headings: completionHeadings,
                                selectHeading: { heading in
                                    if let target = completionHeadingTarget {
                                        insertCompletedLink(to: target,
                                            fragment: NotebookLinkDestination.wikiHeadingFragment(heading),
                                            completionSnapshot: completion, textSnapshot: completionText,
                                            sourceID: selectedID)
                                    }
                                },
                                select: { insertCompletedLink(to: $0,
                                    completionSnapshot: completion, textSnapshot: completionText,
                                    sourceID: selectedID) },
                                dismiss: {
                                    dismissEditorCompletion()
                                    editorNavigation.hasLinkCompletion = false
                                }
                            )
                            .task(id: replica.searchRevision.catalogHeads) {
                                await links.refresh(replica: replica)
                            }
                        }
                    }
                    .overlay {
                        if isLoadingHistory, historyBrowser == nil {
                            VStack(spacing: 12) {
                                ProgressView("Opening History…")
                                Button("Cancel", action: cancelHistoryLoading)
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
                        isShowingHistory: historyBrowser != nil
                    )) {
                        guard session.isEditingEnabled, historyBrowser == nil else { return }
                        let incomingNavigation = editorNavigation
                        guard !incomingNavigation.hasExplicitVisitDestination else { return }
                        let state = navigationState
                        let position = state.position(for: selectedID).flatMap {
                            try? JSONDecoder().decode(MarkdownEditorPosition.self, from: $0)
                        }
                        incomingNavigation.whenAttached { [weak incomingNavigation, weak state] in
                            guard let incomingNavigation,
                                  !incomingNavigation.hasExplicitVisitDestination,
                                  state?.selectedID == selectedID else { return }
                            if searchDestinationID == selectedID {
                                revealSearchDestination(in: incomingNavigation)
                            } else if let position {
                                incomingNavigation.restorePosition?(position)
                            }
                        }
                    }
                    .toolbar {
                        if historyBrowser == nil, !usesCompactLinkNavigation,
                           linkHistory.backTarget != nil {
                            ToolbarItemGroup(placement: .navigation) {
                                Button { navigateLinkHistory(back: true) } label: {
                                    Label("Previous Note", systemImage: "chevron.backward")
                                }
                                .disabled(busy || linkHistory.backTarget == nil)
                                .keyboardShortcut("[", modifiers: .command)
                                .help("Go back to the previous note")
                                .accessibilityIdentifier("note-link-back")
                            }
                        }
                        if let placement = selectedPlacement, historyBrowser == nil {
                            #if os(iOS)
                            if horizontalSizeClass == .compact {
                                ToolbarItem {
                                    libraryNewNote
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
                                        Label("Share", systemImage: "square.and.arrow.up")
                                    }
                                    .disabled(!session.isEditingEnabled || busy || sharedFile != nil)
                                    .accessibilityIdentifier("notebook-share-markdown")
                                    Divider()
                                    #if os(macOS)
                                    if linkHistory.forwardTarget != nil {
                                        Button("Go Forward") {
                                            navigateLinkHistory(back: false)
                                        }
                                        .disabled(busy)
                                        .keyboardShortcut("]", modifiers: .command)
                                        .accessibilityIdentifier("note-link-forward")
                                        Divider()
                                    }
                                    #endif
                                    Button {
                                        showBacklinks()
                                    } label: {
                                        Label("Linked from…", systemImage: "link")
                                    }
                                    .disabled(!session.isEditingEnabled || busy)
                                    .accessibilityIdentifier("notebook-backlinks")
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
                                .background(NotebookSharePicker(
                                    file: $sharedFile, onFinish: presentSharedImport
                                ))
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

    private var usesCompactLinkNavigation: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    @ViewBuilder
    private var notebookNavigationContainer: some View {
        #if os(iOS)
        if usesCompactLinkNavigation {
            NavigationStack(path: Binding<[NotebookLinkRoute]>(
                get: {
                    guard preferredCompactColumn == .detail, let linkRootRoute else { return [] }
                    return [linkRootRoute] + linkRoutes
                },
                set: { routes in
                    if routes.isEmpty {
                        guard !busy else { return }
                        // Commit composition synchronously while its editor
                        // is still attached; the note session remains open.
                        guard editorNavigation.prepareToLeave?() != false, !unrecordedEdit else {
                            errorMessage = NotebookNavigationError.unrecordedEdit.localizedDescription
                            return
                        }
                        rememberEditorPosition()
                        preferredCompactColumn = .sidebar
                    } else if routes.first == linkRootRoute {
                        navigateCompactLinks(to: Array(routes.dropFirst()))
                    }
                }
            )) {
                notebookSidebar
                    .navigationDestination(for: NotebookLinkRoute.self) { route in
                        compactLinkScreen(route, isCurrent: activeLinkRouteID == route.id)
                    }
            }
        } else {
            NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
                notebookSidebar
            } detail: {
                notebookDetail
            }
        }
        #else
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
            notebookSidebar
        } detail: {
            notebookDetail
        }
        #endif
    }

    #if os(iOS)
    private func compactLinkScreen(_ route: NotebookLinkRoute?,
                                   isCurrent: Bool) -> some View {
        let title = route.flatMap { route in
            replica.placements.first { $0.item.id == route.noteID }
        }.map { NotebookNoteName.title(from: $0.displayName) } ?? ""
        // Opening the incoming session can publish before the route changes.
        // A departing screen must keep its own preview throughout that gap.
        let showsLiveEditor = isCurrent && route?.noteID == selectedID
        let showsHistory = showsLiveEditor && historyBrowser != nil
        let isRestoring = session?.isEditingEnabled == true
            && (route.map { restoringLinkRouteID == $0.id } ?? false)
        return ZStack {
            if showsLiveEditor {
                notebookDetail
                    .opacity(isRestoring ? 0 : 1)
                    .allowsHitTesting(!isRestoring)
            }
            if let route, let preview = linkVisitPreviews[route.id],
               !showsLiveEditor || isRestoring {
                NotebookPreviousLinkView(
                    text: preview.text, position: preview.position, title: title,
                    viewportInsets: preview.viewportInsets, titleHeight: preview.titleHeight,
                    viewportOriginY: preview.viewportOriginY,
                    titleFont: editorTitleFont,
                    fontSize: editorFontSize, fontFamily: editorFontFamily,
                    mode: editorMode
                )
                .transition(.identity)
            } else if !showsLiveEditor {
                Color(uiColor: .systemBackground)
            }
        }
        // Editor previews manage their own bar insets. History uses a SwiftUI
        // heading, which must stay below the status and navigation bars.
        // Keep editor geometry fixed when a link preview is removed.
        .ignoresSafeArea(.container,
                         edges: showsHistory ? .bottom : [.top, .bottom])
        .animation(nil, value: isRestoring)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Keep the title in the native Back menu, while the document's
            // existing title remains the only visible heading.
            ToolbarItem(placement: .principal) {
                Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
            }
        }
    }

    private func navigateCompactLinks(to routes: [NotebookLinkRoute]) {
        guard !busy, routes.count < linkRoutes.count,
              Array(linkRoutes.prefix(routes.count)) == routes else { return }
        let steps = linkRoutes.count - routes.count
        guard linkHistory.backTarget(steps: steps) != nil else { return }
        // Accept the native pop immediately. Keeping the old path during an
        // asynchronous save makes NavigationStack undo and replay the pop.
        let previousRoutes = linkRoutes
        rememberLinkVisitPreview()
        linkRoutes = routes
        navigateLinkHistory(back: true, steps: steps, compactRoutesBeforePop: previousRoutes)
    }
    #endif

    private var snippetNavigation: some View {
        notebookNavigationContainer
        .task(id: ObjectIdentifier(editorNavigation)) { configureSnippetNavigation() }
        .onChange(of: replica.snippets, initial: true) { _, _ in updateSnippetMenu() }
        .onChange(of: replica.snippetSources) { _, _ in updateSnippetMenu() }
        .onChange(of: busy) { _, _ in updateSnippetMenu() }
        .onChange(of: historyBrowser == nil) { _, _ in updateSnippetMenu() }
        .onChange(of: session?.isEditingEnabled) { _, _ in updateSnippetMenu() }
    }

    private var searchNavigation: some View {
        snippetNavigation
        .task(id: ObjectIdentifier(editorNavigation)) { configureLinkNavigation() }
        .focusedSceneValue(\.notebookSearch, search)
        .focusedSceneValue(\.notebookRecentCommands, recentCommands)
        .onChange(of: focusedRecentID) { _, id in
            recentCommands.focusedNoteID = id
        }
        .onChange(of: selectedID) { _, id in
            historyLoadTask?.cancel()
            dismissEditorCompletion()
            updateSnippetMenu()
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
        .focusedSceneValue(\.notebookMenu, menu)
        .onChange(of: menuAvailable, initial: true) { _, available in
            menu.isAvailable = available
        }
        .onChange(of: menu.newNoteRequest) { _, _ in
            guard menuAvailable else { return }
            createDefaultNote()
        }
        .onChange(of: menu.settingsRequest) { _, _ in
            guard menuAvailable else { return }
            openSettings()
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
                browserDrag.reset()
                search.clear()
                links.clear()
                resetLinkJourney()
                dismissEditorCompletion()
                showingBacklinks = false
                linkInsertion = nil
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
        .onChange(of: replica.linkMaintenanceIssueMessage) { _, message in
            if let message { errorMessage = message }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                browserDrag.reset()
                rememberEditorPosition()
            }
        }
        #if os(iOS)
        .onChange(of: quickActionRequests.pendingActionCount, initial: true) { _, _ in
            handlePendingQuickAction()
        }
        .onChange(of: busy) { _, isBusy in
            if !isBusy { handlePendingQuickAction() }
        }
        .onChange(of: deletionSelection) { _, selection in
            if selection == nil { handlePendingQuickAction() }
        }
        #endif
        .onDisappear {
            browserDrag.reset()
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
            Button("OK", role: .cancel) {
                errorMessage = nil
                replica.acknowledgeLinkMaintenanceIssue()
            }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(
            isPresented: Binding(
                get: { !movingIDs.isEmpty }, set: { if !$0 { movingIDs = [] } }
            ),
            onDismiss: presentSharedImport
        ) { moveSheet }
        .sheet(isPresented: $showingBacklinks, onDismiss: {
            backlinkDeparture = nil
        }) {
            if let selectedID {
                NotebookBacklinksView(state: links, replica: replica, noteID: selectedID) {
                    openBacklink($0, targetID: selectedID)
                }
                .id(selectedID)
            }
        }
        .sheet(item: $linkInsertion, onDismiss: {
            editorNavigation.resumeEditing?()
            editorNavigation.focusEditor?()
        }) { request in
            NotebookLinkPicker(state: links, replica: replica,
                select: { insertPickedLink(to: $0, request: request) },
                insertURL: { insertPickedURL($0, request: request) })
        }
        .confirmationDialog("Choose linked note", isPresented: Binding(
            get: { !linkChoices.isEmpty },
            set: { if !$0 { linkChoices = [] } }
        ), titleVisibility: .visible) {
            ForEach(linkChoices, id: \.id) { note in
                Button(note.fullPath) {
                    linkChoices = []
                    perform { try await visitLinkedNote(note.id, fragment: linkChoiceFragment) }
                }
            }
        }
        .confirmationDialog("Create linked note?", isPresented: Binding(
            get: { missingLink != nil }, set: { if !$0 { missingLink = nil } }
        ), titleVisibility: .visible) {
            if let missingLink {
                Button("Create Note") { createMissingLinkedNote(missingLink) }
            }
            Button("Cancel", role: .cancel) { missingLink = nil }
        } message: {
            Text(missingLink?.destination ?? "")
        }
        .notebookMarkdownImporter(
            isPresented: $showingImport, replica: replica, onImport: importMarkdown
        )
        .sheet(isPresented: $showingTrash, onDismiss: finishTemplatePresentation) {
            NavigationStack {
                trashView
            }
            #if os(macOS)
            .frame(minWidth: 400, idealWidth: 560, minHeight: 360, idealHeight: 540)
            #endif
        }
        #if os(iOS)
        .sheet(item: $sharedFile, onDismiss: presentSharedImport) { file in
            NotebookShareSheet(file: file) {
                if sharedFile?.id == file.id { sharedFile = nil }
            }
        }
        #endif
        .sheet(isPresented: $showingTemplates, onDismiss: finishTemplatePresentation) {
            NotebookTemplatePicker(
                replica: replica,
                onCreate: createTemplateNote,
                onOpenNote: openReusableSource
            )
        }
        .sheet(isPresented: $showingSettings, onDismiss: finishTemplatePresentation) {
            NotebookSettingsView(replica: replica,
                                 workspace: workspace ?? NotebookWorkspace.shared,
                                 onImport: importMarkdown,
                                 beforeExport: flushEditor,
                                 onOpenNote: openReusableSource)
        }
        .sheet(item: $sharedImport, onDismiss: finishSharedImport) { request in
            NotebookSharedImportView(plan: request.plan, replica: replica) { parentID in
                try await importMarkdown(request.plan, parentID: parentID)
            }
        }
        .onChange(of: incomingImports?.requests.first?.id, initial: true) { _, _ in
            guard incomingImports?.requests.first != nil else { return }
            if showingSettings { showingSettings = false }
            else if showingTrash { showingTrash = false }
            else if showingTemplates, !busy { showingTemplates = false }
            else { presentSharedImport() }
        }
        .onChange(of: busy) { _, busy in
            if !busy { presentSharedImport() }
        }
        .onChange(of: replica.hasPendingImport) { _, pending in
            if !pending { presentSharedImport() }
        }
        .onChange(of: showingImport) { _, presented in
            if !presented { presentSharedImport() }
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
            resetLinkJourney()
            if selectedID != nil { preferredCompactColumn = .detail }
            busy = false
            #if os(iOS)
            handlePendingQuickAction()
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
                NotebookTitleField(
                    noteID: placement.item.id,
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
                    font: editorTitleFont,
                    isEnabled: !busy,
                    focusRequest: detailTitleFocusRequest,
                    onFocusHandled: { request in
                        if detailTitleFocusRequest == request {
                            detailTitleFocusRequest = nil
                        }
                    },
                    onSubmit: { submitDetailTitle() },
                    onCancel: cancelDetailTitle
                )
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
                            onHide: { id, completion in
                                setRecentHidden(true, for: id, onCompletion: completion)
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
        .accessibilityAction(named: Text("Hide from Recents")) {
            setRecentHidden(true, for: placement.item.id)
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
                Image(systemName: "trash")
            }
            .accessibilityLabel("Move to Trash")
            .accessibilityIdentifier("notebook-recent-swipe-trash")
            Button {
                setRecentHidden(true, for: placement.item.id)
            } label: {
                Image(systemName: "eye.slash")
            }
            .tint(.gray)
            .accessibilityLabel("Hide from Recents")
            .accessibilityIdentifier("notebook-recent-swipe-hide")
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
            title: String(localized: "Hide from Recents"),
            image: UIImage(systemName: "eye.slash"),
            attributes: busy ? .disabled : []
        ) { _ in
            setRecentHidden(true, for: id)
        })
        menuActions.append(UIAction(
            title: replica.isTemplateSource(id)
                ? String(localized: "Stop Using as Template")
                : String(localized: "Use as Template"),
            image: UIImage(systemName: "doc.on.doc"),
            attributes: busy ? .disabled : []
        ) { _ in
            setTemplateSource(id, enabled: !replica.isTemplateSource(id))
        })
        menuActions.append(UIAction(
            title: replica.isSnippetSource(id)
                ? String(localized: "Stop Using as Snippet")
                : String(localized: "Use as Snippet"),
            image: UIImage(systemName: "text.badge.plus"),
            attributes: busy ? .disabled : []
        ) { _ in
            setSnippetSource(id, enabled: !replica.isSnippetSource(id))
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

    private func setRecentHidden(
        _ hidden: Bool, for id: UUID,
        onCompletion: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        perform({
            try await replica.setHiddenFromRecents(hidden, for: id)
        }, onCompletion: onCompletion)
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
        let rows = visibleActiveRows
        let target = browserDrag.target
        let targetDepth = rows.first { $0.id == target?.rowID }?.depth ?? 0
        let afterEndID = browserAfterEndID(in: rows)
        return ForEach(rows) { row in
            browserRow(row, afterEndID: afterEndID, targetDepth: targetDepth)
                .tag(row.id)
                .id(row.id)
                .listRowSeparator(.hidden)
                // A custom clear background also hides the native selected fill.
                .listRowBackground(browserSelection.contains(row.id) ? nil : Color.clear)
                .listRowInsets(sidebarSectionInsets)
        }
    }

    private func browserRow(
        _ row: NotebookSidebarRow, afterEndID: UUID?, targetDepth: Int
    ) -> some View {
        sidebarRow(row)
            .notebookDragSource(enabled: editingID == nil) {
                beginBrowserDrag(row.id)
            }
            .notebookBrowserRowGeometry(itemID: row.id, state: browserDrag)
            .overlay(alignment: .top) {
                if browserDrag.target?.position == .before,
                   browserDrag.target?.rowID == row.id {
                    browserInsertionLine(depth: row.depth)
                }
            }
            .overlay(alignment: .bottom) {
                if afterEndID == row.id {
                    browserInsertionLine(depth: targetDepth)
                }
            }
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(
                        browserDrag.target?.rowID == row.id
                            && browserDrag.target?.position == .into ? 0.16 : 0
                    ))
            }
    }

    private func browserInsertionLine(depth: Int) -> some View {
        Rectangle().fill(Color.accentColor).frame(height: 2)
            .padding(.leading, CGFloat(depth) * 16 + 20)
            .allowsHitTesting(false)
    }

    private func browserAfterEndID(in rows: [NotebookSidebarRow]) -> UUID? {
        guard let target = browserDrag.target, target.position == .after,
              let id = target.rowID,
              let start = rows.firstIndex(where: { $0.id == id })
        else { return nil }
        let depth = rows[start].depth
        return rows.dropFirst(start + 1).prefix { $0.depth > depth }.last?.id ?? id
    }

    private func beginBrowserDrag(_ id: UUID) -> NSItemProvider {
        guard !busy, editingID == nil, !search.isPresented,
              let notebookID = replica.catalogSnapshot?.notebookID else {
            return NSItemProvider()
        }
        let ids = browserSelection.contains(id) && browserSelection.count > 1
            ? browserSelection.orderedIDs(in: activeBrowserOrder) : [id]
        let rootsByID = Dictionary(uniqueKeysWithValues:
            effectiveSelectionRoots(ids).map { ($0.item.id, $0) })
        let roots = ids.compactMap { rootsByID[$0] }
        guard !roots.isEmpty, roots.allSatisfy({ !$0.isInTrash }) else {
            return NSItemProvider()
        }
        return browserDrag.begin(NotebookBrowserDrag(
            notebookID: notebookID,
            sources: roots.map {
                NotebookBrowserPlacementExpectation(
                    itemID: $0.item.id, parentID: $0.item.parentID
                )
            }
        ))
    }

    private func browserDropInteraction() -> NotebookBrowserDropInteraction {
        NotebookBrowserDropInteraction(
            state: browserDrag,
            resolve: { point in
                guard !busy, editingID == nil, let drag = browserDrag.drag,
                      drag.notebookID == replica.catalogSnapshot?.notebookID else { return nil }
                let viewport = browserDropViewportFrame
                guard !viewport.isEmpty, viewport.contains(point) else { return nil }
                let header = browserDrag.filesHeaderFrame
                guard !header.isEmpty, point.y >= header.minY else { return nil }
                let rows = visibleActiveRows.compactMap { row -> (NotebookSidebarRow, CGRect)? in
                    guard let frame = browserDrag.rowFrame(for: row.id), !frame.isEmpty,
                          frame.intersects(viewport) else { return nil }
                    return (row, frame)
                }
                guard visibleActiveRows.isEmpty || !rows.isEmpty else { return nil }
                let id: UUID?
                let position: NotebookBrowserDropTarget.Position
                if header.contains(point) || rows.isEmpty
                    || point.y > (rows.map { $0.1.maxY }.max() ?? header.maxY) {
                    id = nil
                    position = .root
                } else if let (row, frame) = rows.min(by: {
                    abs($0.1.midY - point.y) < abs($1.1.midY - point.y)
                }) {
                    id = row.id
                    let isFolder = replica.placements.first { $0.item.id == id }?.item.kind == .folder
                    let fraction = (point.y - frame.minY) / frame.height
                    if isFolder, fraction > 0.25, fraction < 0.75 { position = .into }
                    else { position = fraction < 0.5 ? .before : .after }
                } else { return nil }
                return NotebookBrowserDragPlacement.target(
                    rowID: id, position: position,
                    drag: drag, placements: replica.placements
                )
            },
            expand: { id in
                if let id { expandedIDs.insert(id) }
                else { navigationState.isTreeExpanded = true }
            },
            commit: { drag, target in
                guard !busy else {
                    errorMessage = String(localized:
                        "Another action is still finishing. Try moving the files again.")
                    return
                }
                perform {
                    guard workspace == nil || workspace?.replica === replica else { return }
                    try await flushEditor()
                    guard workspace == nil || workspace?.replica === replica else { return }
                    let oldHeads = replica.catalogSnapshot?.heads
                    let undo = try await replica.placeItems(
                        drag.itemIDs, to: target.parentID, before: target.beforeID,
                        expecting: drag.sources, notebookID: drag.notebookID
                    )
                    if replica.catalogSnapshot?.heads != oldHeads {
                        browserUndo = undo
                        browserRedo = nil
                    }
                    if let parentID = target.parentID { expandedIDs.insert(parentID) }
                    for id in drag.itemIDs { reveal(id) }
                }
            }
        )
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

    private func inlineNameField(for id: UUID) -> some View {
        #if os(macOS)
        NotebookInlineNameField(text: $proposedName, isEnabled: !busy)
        #else
        TextField("Name", text: $proposedName)
            .focused($focusedNameID, equals: id)
        #endif
    }

    @ViewBuilder
    private func sidebarRow(_ row: NotebookSidebarRow) -> some View {
        if let placement = replica.placements.first(where: { $0.item.id == row.id }) {
            HStack(spacing: 6) {
                if placement.item.kind == .folder {
                    #if os(macOS)
                    NotebookNativeDisclosureButton(
                        isExpanded: expandedIDs.contains(row.id),
                        label: placement.displayName,
                        identifier: "notebook-disclosure-" + row.id.uuidString,
                        action: { toggleFolder(row.id) }
                    )
                    .frame(width: 20, height: sidebarRowHeight)
                    #else
                    Button { toggleFolder(row.id) } label: {
                        disclosureIcon(expanded: expandedIDs.contains(row.id))
                            .frame(minWidth: 20, minHeight: sidebarRowHeight)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(placement.displayName)
                    .accessibilityValue(expandedIDs.contains(row.id) ? "Expanded" : "Collapsed")
                    .accessibilityIdentifier("notebook-disclosure-" + row.id.uuidString)
                    #endif
                } else {
                    Color.clear.frame(width: 20, height: 1)
                }
                if editingID == row.id {
                    inlineNameField(for: row.id)
                        .textFieldStyle(.plain)
                        .accessibilityIdentifier("notebook-inline-name")
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
                            guard placement.item.kind == .note,
                                  !selectingItems, !busy,
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
        guard !busy, !showsSelectionControls,
              editingID != placement.item.id else { return }
        if placement.item.kind == .folder, editingID == nil {
            toggleFolder(placement.item.id)
            return
        }
        perform {
            // A tap outside the naming row finishes its pending name before
            // navigating. Otherwise an unsubmitted folder traps all Files taps.
            try await commitInlineNameIfNeeded()
            if placement.item.kind == .folder {
                toggleFolder(placement.item.id)
            } else {
                try await selectNote(placement.item.id)
            }
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
    private func creationActions(for placement: NotebookPlacement) -> some View {
        let parentID = creationParent(for: placement)
        let position = contextualCreationPosition(for: placement)
        Button("New Note") {
            createItem(kind: .note, parentID: parentID, position: position)
        }
            .disabled(busy)
        templateCreationButton
        Button("New Folder") {
            createItem(kind: .folder, parentID: parentID, position: position)
        }
            .disabled(busy)
    }

    private func contextualCreationPosition(
        for placement: NotebookPlacement
    ) -> NotebookCreationPosition {
        if placement.item.kind == .folder { return .first }
        #if os(iOS)
        return browserScrollView.creationPosition(relativeTo: placement.item.id)
        #else
        return .after(placement.item.id)
        #endif
    }

    @ViewBuilder
    private func actions(
        for placement: NotebookPlacement, allowsCreation: Bool = true,
        allowsRename: Bool = true, allowsShowInFiles: Bool = false
    ) -> some View {
        if allowsCreation, !placement.isInTrash {
            creationActions(for: placement)
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
        if !placement.isInTrash {
            let registered = replica.isTemplateSource(placement.item.id)
            let title: LocalizedStringKey = placement.item.kind == .folder
                ? (registered ? "Stop Using as Template Folder" : "Use as Template Folder")
                : (registered ? "Stop Using as Template" : "Use as Template")
            Button {
                setTemplateSource(placement.item.id, enabled: !registered)
            } label: {
                Label(title, systemImage: "doc.on.doc")
            }
            .disabled(busy)
            .accessibilityIdentifier("notebook-use-as-template-\(placement.item.id)")
            let snippetRegistered = replica.isSnippetSource(placement.item.id)
            let snippetTitle: LocalizedStringKey = placement.item.kind == .folder
                ? (snippetRegistered ? "Stop Using as Snippet Folder" : "Use as Snippet Folder")
                : (snippetRegistered ? "Stop Using as Snippet" : "Use as Snippet")
            Button {
                setSnippetSource(placement.item.id, enabled: !snippetRegistered)
            } label: {
                Label(snippetTitle, systemImage: "text.badge.plus")
            }
            .disabled(busy)
            .accessibilityIdentifier("notebook-use-as-snippet-\(placement.item.id)")
        }
        Button("Move…") {
            beginMoving([placement.item.id], fromTrash: placement.isInTrash)
        }
        if !placement.isInTrash, placement.item.kind == .note {
            if allowsShowInFiles {
                Button("Show in Files") { showInFiles(placement.item.id) }
                    .accessibilityIdentifier("notebook-show-in-files")
            }
            if !replica.isHiddenFromRecents(placement.item.id) {
                recentPinButton(for: placement.item.id)
            }
            let hidden = replica.isHiddenFromRecents(placement.item.id)
            let visibilityTitle: LocalizedStringKey = hidden
                ? "Show in Recents" : "Hide from Recents"
            Button {
                setRecentHidden(!hidden, for: placement.item.id)
            } label: {
                Label(visibilityTitle,
                      systemImage: hidden ? "eye" : "eye.slash")
            }
            .disabled(busy)
            .accessibilityIdentifier("notebook-recents-visibility-" + placement.item.id.uuidString)
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
        position: NotebookCreationPosition = .append,
        usesDefaultDestination: Bool = false
    ) {
        var createdFolderID: UUID?
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
                    : replica.createNote(
                        name: name, parentID: parentID, position: position))
                reveal(id)
                try await selectNote(id)
                detailEditingID = id
                detailOriginalName = name
                detailProposedTitle = NotebookNoteName.title(from: name)
                detailTitleHeight = 32
                detailTitleFocusRequest = NotebookTitleFocusRequest(
                    noteID: id, selectsAll: true
                )
            case .folder:
                createdFolderID = try await replica.createFolder(
                    name: "Untitled Folder", parentID: parentID,
                    position: position)
            }
        } onSuccess: {
            guard let id = createdFolderID else { return }
            navigationState.isTreeExpanded = true
            reveal(id)
            beginRenaming(id: id, name: "Untitled Folder")
            fileRevealRequest = NotebookFileReveal(id: id, highlights: false)
        }
    }

    #if os(iOS)
    private func handlePendingQuickAction() {
        guard restoredNavigation, !busy else { return }
        if pendingTemplateQuickAction {
            presentPendingTemplateQuickAction()
            return
        }
        guard let action = quickActionRequests.takeNextAction() else { return }
        switch action {
        case .newNote: createDefaultNote()
        case .newFromTemplate:
            pendingTemplateQuickAction = true
            presentPendingTemplateQuickAction()
        }
    }

    private func presentPendingTemplateQuickAction() {
        guard pendingTemplateQuickAction, !busy, !awaitingQuickActionSheetDismissal,
              deletionSelection == nil else { return }
        if showingTemplates {
            pendingTemplateQuickAction = false
            return
        }
        if showingSettings || showingTrash {
            // Present only after SwiftUI has completed the existing dismissal.
            awaitingQuickActionSheetDismissal = true
            showingSettings = false
            showingTrash = false
            return
        }
        pendingTemplateQuickAction = false
        showTemplates()
    }
    #endif

    private func createDefaultNote() {
        createItem(kind: .note, parentID: nil, usesDefaultDestination: true)
    }

    private func showTemplates() {
        perform {
            try await flushEditor()
            showingTemplates = true
        }
    }

    private func setSnippetSource(_ id: UUID, enabled: Bool) {
        perform {
            try await replica.setSnippetSource(id, enabled: enabled)
        }
    }

    private func updateSnippetMenu() {
        snippetSourceNoteIDs = Set(replica.snippets.map(\.id))
        editorNavigation.snippetMenu.update(replica.snippets, sources: replica.snippetSources)
        if variableCompletion != nil && !canCompleteSnippetVariable { dismissEditorCompletion() }
        editorNavigation.snippetMenu.isEnabled = !busy && historyBrowser == nil
            && session?.isEditingEnabled == true
    }

    private func configureSnippetNavigation() {
        let navigation = editorNavigation
        updateSnippetMenu()
        navigation.insertSnippet = { [weak navigation] id in
            guard let navigation, navigation === editorNavigation,
                  !busy, historyBrowser == nil, let targetID = selectedID,
                  session?.isEditingEnabled == true else { return }
            guard let insert = navigation.prepareSnippetInsertion?() else {
                errorMessage = String(localized:
                    "Place the cursor in the note before inserting a snippet. For a table cell, switch to Source mode.")
                return
            }
            let title = selectedPlacement.map {
                NotebookNoteName.title(from: $0.displayName)
            } ?? ""
            let date = Date()
            Task { @MainActor in
                do {
                    let source = try await replica.snippetText(id)
                    guard selectedID == targetID, navigation === editorNavigation,
                          !busy, historyBrowser == nil,
                          session?.isEditingEnabled == true else { return }
                    let text = NotebookSnippetText.expand(
                        text: source, title: title, date: date
                    )
                    guard insert(text) else {
                        errorMessage = String(localized:
                            "The note or cursor changed while the snippet was loading. Choose the snippet again.")
                        return
                    }
                } catch {
                    guard selectedID == targetID, navigation === editorNavigation else { return }
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func setTemplateSource(_ id: UUID, enabled: Bool) {
        perform {
            try await flushEditor()
            try await replica.setTemplateSource(id, enabled: enabled)
        }
    }

    private func createTemplateNote(_ sourceID: UUID) async throws {
        guard !busy else { throw NotebookReplicaError.busy }
        busy = true
        defer { busy = false }
        try await flushEditor()
        let id = try await replica.createNoteFromTemplate(sourceID)
        if showingTemplates {
            pendingPresentedItemID = id
        } else {
            // A completed write must still open its note if presentation
            // ended while storage was saving; never leave a stale route.
            reveal(id)
            try await selectNote(id)
        }
    }

    private func openReusableSource(_ id: UUID) {
        pendingPresentedItemID = id
        showingSettings = false
        showingTemplates = false
    }

    private func finishTemplatePresentation() {
        openPendingPresentedItem()
        #if os(iOS)
        awaitingQuickActionSheetDismissal = false
        handlePendingQuickAction()
        #endif
        presentSharedImport()
    }

    private func openPendingPresentedItem() {
        guard let id = pendingPresentedItemID else { return }
        pendingPresentedItemID = nil
        perform {
            guard let placement = replica.placements.first(where: {
                $0.item.id == id && !$0.isInTrash && !$0.item.isPermanentlyDeleted
            }) else { throw NotebookReplicaError.noteUnavailable(id) }
            if placement.item.kind == .folder {
                try await flushEditor()
                guard replica.placements.contains(where: {
                    $0.item.id == id && $0.item.kind == .folder
                        && !$0.isInTrash && !$0.item.isPermanentlyDeleted
                }) else { throw NotebookReplicaError.noteUnavailable(id) }
                expandedIDs.insert(id)
                showInFiles(id)
            } else {
                reveal(id)
                try await selectNote(id)
            }
        }
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
        #if os(iOS)
        Task { @MainActor in
            focusedNameID = id
        }
        #endif
    }

    private func beginDetailRenaming(_ placement: NotebookPlacement) {
        perform {
            try await flushEditor()
            detailEditingID = placement.item.id
            detailOriginalName = placement.item.name
            detailProposedTitle = NotebookNoteName.title(from: placement.item.name)
            detailTitleFocusRequest = NotebookTitleFocusRequest(
                noteID: placement.item.id, selectsAll: false
            )
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
        detailTitleFocusRequest = nil
        detailOriginalName = ""
        detailProposedTitle = ""
    }

    private func cancelDetailTitle() {
        detailEditingID = nil
        detailTitleFocusRequest = nil
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
            // Inline rename reopens this note without selecting it again.
            // Replace the retained Files-transition path before pushing it.
            if usesCompactLinkNavigation, preferredCompactColumn != .detail {
                resetLinkJourney()
            }
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

    private func revealLinkedNoteInFiles(_ id: UUID) {
        navigationState.isTreeExpanded = true
        reveal(id)
        // Keep deliberate batch selections intact. Otherwise the native Files
        // selection should track the note reached through links or history.
        // A compact split view treats List selection as a new detail root;
        // changing it during a link push would discard the native link stack.
        if !usesCompactLinkNavigation, !selectingItems, browserSelection.count <= 1 {
            browserSelection.selectOnly(id)
        }
        fileRevealRequest = NotebookFileReveal(id: id, highlights: false)
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
        let byID = Dictionary(uniqueKeysWithValues:
            replica.placements.map { ($0.item.id, $0) })
        return NotebookBrowserDragPlacement.allowsDestination(
            parentID, excluding: Set(movingIDs), byID: byID)
    }

    private func sort(_ parentID: UUID?, by order: NotebookSortOrder) {
        perform {
            try await flushEditor()
            try await replica.sortChildren(parentID: parentID, by: order)
        }
    }

    private func presentSharedImport() {
        guard sharedFile == nil, sharedImportID == nil, !busy,
              !showingSettings, !showingTemplates, !showingTrash,
              !showingImport, movingIDs.isEmpty, !replica.hasPendingImport,
              let request = incomingImports?.requests.first else { return }
        sharedImportID = request.id
        sharedImport = request
    }

    private func finishSharedImport() {
        if let request = incomingImports?.requests.first(where: { $0.id == sharedImportID }) {
            incomingImports?.finish(request)
        }
        sharedImportID = nil
        presentSharedImport()
    }

    private func importMarkdown(_ plan: NotebookImportPlan?) async throws {
        try await importMarkdown(plan, parentID: nil)
    }

    private func importMarkdown(
        _ plan: NotebookImportPlan?, parentID: UUID?
    ) async throws {
        guard !busy else { throw NotebookReplicaError.busy }
        busy = true
        defer {
            editorNavigation.resumeEditing?()
            busy = false
        }
        try await flushEditor()
        if let plan {
            try await replica.importMarkdown(plan, parentID: parentID)
            expandedIDs.formUnion(plan.entries.filter { $0.kind == .folder }.map(\.id))
            var ancestor = parentID
            var visited = Set<UUID>()
            while let id = ancestor, visited.insert(id).inserted,
                  let placement = replica.placements.first(where: { $0.item.id == id }) {
                expandedIDs.insert(id)
                ancestor = placement.parentID
            }
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
                onHide: { id, completion in
                    setRecentHidden(true, for: id, onCompletion: completion)
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
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .global)
                } action: { browserDrag.filesHeaderFrame = $0 }
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(
                            browserDrag.target?.position == .root ? 0.16 : 0
                        ))
                }
                #if os(iOS)
                .background(NotebookBrowserScrollReader(reference: browserScrollView))
                .background(NotebookBrowserUIKitDropReader(interaction: browserDropInteraction()))
                #else
                .background(NotebookBrowserAppKitScrollReader(state: browserDrag))
                #endif
            }
        }
        .listStyle(.plain)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            browserDropViewportFrame = frame
        }
        #if os(macOS)
        .overlay(NotebookBrowserAppKitDragReader(
            state: browserDrag,
            canBegin: {
                !busy && editingID == nil && !search.isPresented
                    && replica.catalogSnapshot?.notebookID != nil
            },
            sourceAt: { point in
                guard browserDropViewportFrame.contains(point) else { return nil }
                return visibleActiveRows.first { row in
                    browserDrag.rowFrame(for: row.id)?.contains(point) == true
                }?.id
            },
            selectSource: { id in
                if !browserSelection.contains(id) { browserSelection.selectOnly(id) }
                browserFocused = true
            },
            begin: beginBrowserDrag
        ))
        .overlay(NotebookBrowserAppKitDropSurface(interaction: browserDropInteraction()))
        #endif
        #if os(iOS)
        // Keep a small buffer above the floating controls, including in
        // shorter windows, without leaving half the browser empty.
        .contentMargins(.bottom, max(96, browserViewportHeight / 5),
                        for: .scrollContent)
        .listSectionSpacing(12)
        .listSectionMargins(.top, 8)
        .listSectionMargins(.bottom, 0)
        .onScrollGeometryChange(for: NotebookBrowserViewport.self) { geometry in
            NotebookBrowserViewport(offset: geometry.contentOffset.y,
                                    bottomInset: geometry.contentInsets.bottom,
                                    size: geometry.containerSize)
        } action: { _, viewport in
            browserViewport = viewport
            // Rendering must depend only on size. Reading the full viewport
            // for the margin would rebuild the list on every scroll offset.
            if browserViewportHeight != viewport.size.height {
                browserViewportHeight = viewport.size.height
            }
            restoreBrowserViewportIfReady()
        }
        .onScrollPhaseChange { _, phase in
            if phase == .tracking || phase == .interacting {
                browserReturnViewport = nil
                browserToolbarWasHidden = false
            }
        }
        #else
        .contentMargins(.bottom, 120, for: .scrollContent)
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
        #if os(iOS)
        .onDragSessionUpdated { session in
            switch session.phase {
            case .initial, .active: browserDrag.isSessionActive = true
            case .ended, .dataTransferCompleted: browserDrag.reset()
            default: break
            }
        }
        #endif
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
                linkJourneyID = UUID()
                linkHistory.clear()
                // Keep the outgoing screen's identity/content through the
                // Files transition. Direct selection starts a fresh journey.
            }
            #endif
            if isPhoneLayout, column == .sidebar, !selectingItems {
                browserSelection.clear()
            }
        }
        .task(id: fileRevealRequest) {
            guard let request = fileRevealRequest else { return }
            await Task.yield()
            #if os(iOS)
            // A new inline editor replaces the row's drag source. Allow
            // that layout to finish before revealing a virtualized row.
            if editingID == request.id {
                try? await Task.sleep(for: .milliseconds(100))
            }
            #endif
            guard !Task.isCancelled else { return }
            withAnimation { scrollProxy.scrollTo(request.id, anchor: .center) }
            guard request.highlights else {
                fileRevealRequest = nil
                return
            }
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
        #if os(iOS)
        NotebookNewNoteButton(
            isEnabled: !busy, hasTemplates: !replica.templates.isEmpty,
            onNewNote: createDefaultNote,
            onNewFromTemplate: showTemplates
        )
        .frame(width: 44, height: 44)
        #else
        Menu {
            Button("New Note") { createDefaultNote() }
            templateCreationButton
        } label: {
            Label("New Note", systemImage: "plus")
        } primaryAction: {
            createDefaultNote()
        }
        .disabled(busy)
        .accessibilityIdentifier("notebook-new-item")
        .accessibilityLabel("New Note")
        #endif
    }

    private var templateCreationButton: some View {
        Button(action: showTemplates) {
            Label("New from Template…", systemImage: "doc.on.doc")
        }
        .disabled(busy || replica.templates.isEmpty)
        .accessibilityIdentifier("notebook-new-from-template")
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
            templateCreationButton
            Button("New Folder") { createItem(kind: .folder, parentID: nil) }
            browserUndoActions
            Divider()
            if isPhoneLayout {
                Button { openSettings() } label: {
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

    private func openSettings() {
        guard !showingSettings, !showingTrash, !showingImport,
              !search.showingQuickOpen, movingIDs.isEmpty else { return }
        perform {
            try await flushEditor()
            showingSettings = true
        }
    }

    private func showQuickOpen() {
        guard !busy, !search.showingQuickOpen, !showingSettings, !showingTemplates,
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
        guard sharedFile == nil, let session, let noteID = selectedID else { return }
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
        try Task.checkCancellation()
        try await commitInlineNameIfNeeded()
        try Task.checkCancellation()
        try await commitDetailTitleIfNeeded()
        try Task.checkCancellation()
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
        guard historyBrowser == nil, !isLoadingHistory, !busy,
              let session, let selectedID else { return }
        isLoadingHistory = true
        busy = true
        let loadID = UUID()
        historyLoadID = loadID
        historyLoadTask = Task { @MainActor in
            var isOpening = true
            defer {
                if historyLoadID == loadID {
                    isLoadingHistory = false
                    if isOpening { busy = false }
                    historyLoadTask = nil
                }
            }
            do {
                try await flushEditor()
                try Task.checkCancellation()
                guard self.selectedID == selectedID,
                      self.session === session,
                      let heads = session.currentSnapshot?.heads else { return }
                let reader = try session.makeHistoryReader()
                let browser = NoteHistoryBrowserState(
                    noteID: selectedID,
                    versions: [],
                    expectedHeads: heads,
                    originalPosition: editorNavigation.capturePosition?(),
                    text: session.text,
                    reader: reader
                )
                historyBrowser = browser
                editorNavigation.invalidate()
                // History can be closed while its frozen index is building.
                // Subsequent live edits are checked again before restoration.
                isOpening = false
                busy = false
                for try await update in await reader.updates() {
                    try Task.checkCancellation()
                    guard historyBrowser === browser else { return }
                    browser.apply(update)
                }
            } catch is CancellationError {
                if historyLoadID == loadID {
                    editorNavigation.resumeEditing?()
                }
            } catch {
                if historyLoadID == loadID {
                    closeHistory()
                    editorNavigation.resumeEditing?()
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func cancelHistoryLoading() {
        let ownsBusy = isLoadingHistory && historyBrowser == nil
        historyLoadID = UUID()
        historyLoadTask?.cancel()
        historyLoadTask = nil
        isLoadingHistory = false
        if ownsBusy {
            busy = false
            editorNavigation.resumeEditing?()
        }
    }

    private func closeHistory() {
        cancelHistoryLoading()
        guard let historyBrowser else { return }
        historyBrowser.cancel()
        historyBrowser.navigation.invalidate()
        self.historyBrowser = nil
        editorNavigation = MarkdownEditorNavigation()
    }

    private func restoreHistoryInPlace() {
        guard let historyBrowser,
              !historyBrowser.isLoadingPreview,
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
                    closeHistory()
                    busy = false
                    openHistory()
                    errorMessage = String(localized:
                        "This note changed while History was open. Review the current version before restoring.")
                    return
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
              !historyBrowser.isLoadingPreview,
              let version = historyBrowser.selectedVersion,
              let placement = selectedPlacement else { return }
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            do {
                let text = try await historyBrowser.reader.historicalText(for: version)
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

    private var canCompleteSnippetVariable: Bool {
        guard let selectedID, !busy, historyBrowser == nil,
              session?.isEditingEnabled == true else { return false }
        return snippetSourceNoteIDs.contains(selectedID)
    }

    private func dismissEditorCompletion() {
        linkCompletion = nil
        variableCompletion = nil
        editorNavigation.hasLinkCompletion = false
    }

    private func insertCompletedVariable(_ variable: NotebookSnippetVariable,
        completion: NotebookSnippetVariableCompletion, textSnapshot: String,
        sourceID: UUID, selection: NSRange, navigation: MarkdownEditorNavigation) {
        guard sourceID == selectedID, navigation === editorNavigation,
              navigation.isValid, canCompleteSnippetVariable,
              replica.snippets.contains(where: { $0.id == sourceID }),
              session?.text == textSnapshot,
              navigation.capturePosition?()?.selection == selection else { return }
        let change = MarkdownEditingChange(range: completion.range,
            replacement: variable.token,
            selection: NSRange(location: completion.range.location + variable.token.utf16.count,
                length: 0))
        if navigation.insertLink?(change, textSnapshot) != true {
            errorMessage = NotebookLinkUIError.changed.localizedDescription
        }
        dismissEditorCompletion()
    }

    private var completionHeadingTarget: NotebookLinkNote? {
        guard let completion = linkCompletion, completion.query.contains("#"),
              let selectedID else { return nil }
        let path = NotebookLinkParser.literalDestinationParts(completion.query).path
        let probe = "[[\(path.isEmpty ? "#__heading" : path)]]"
        guard let occurrence = NotebookLinkParser.parse(probe).first,
              case .resolved(let id, _) = NotebookLinkResolver.resolve(
                occurrence, sourceID: selectedID, notes: replica.linkNotes)
        else { return nil }
        return replica.linkNotes.first { $0.id == id }
    }

    private var completionHeadings: [String] {
        guard let target = completionHeadingTarget, let completion = linkCompletion else { return [] }
        let fragment = NotebookLinkParser.literalDestinationParts(completion.query).fragment ?? ""
        let headings = target.id == selectedID
            ? NotebookLinkParser.headings(in: linkCompletionText)
            : links.headingNames[target.id] ?? []
        return headings.filter { fragment.isEmpty || $0.localizedCaseInsensitiveContains(fragment) }
    }

    private func configureLinkNavigation() {
        let navigation = editorNavigation
        navigation.openLink = { link in openNoteLink(link) }
        navigation.requestLink = { [weak navigation] text, range in
            guard let selectedID, !busy else { return }
            let existing = NotebookLinkParser.parse(text).first {
                !$0.isEmbed && (NSIntersectionRange($0.range, range).length > 0
                    || NSLocationInRange(range.location, $0.range))
            }
            let selectedText = (text as NSString).substring(with: range)
            linkInsertion = NotebookLinkInsertionRequest(
                sourceID: selectedID, text: text,
                range: existing?.range ?? range,
                label: existing?.label ?? selectedText)
            dismissEditorCompletion()
            navigation?.hasLinkCompletion = false
        }
        navigation.completionCommand = { [weak navigation] command in
            if let completion = variableCompletion {
                guard canCompleteSnippetVariable, navigation === editorNavigation else {
                    dismissEditorCompletion()
                    return false
                }
                switch command {
                case "dismiss": dismissEditorCompletion()
                case "accept":
                    guard let selectedID, !completion.suggestions.isEmpty else { return false }
                    insertCompletedVariable(
                        completion.suggestions[min(linkCompletionSelection,
                            completion.suggestions.count - 1)],
                        completion: completion, textSnapshot: linkCompletionText,
                        sourceID: selectedID, selection: variableCompletionSelection,
                        navigation: editorNavigation)
                case "next":
                    linkCompletionSelection = min(max(0, completion.suggestions.count - 1),
                        linkCompletionSelection + 1)
                case "previous": linkCompletionSelection = max(0, linkCompletionSelection - 1)
                default: return false
                }
                return true
            }
            guard let completion = linkCompletion else { return false }
            let suggestions = links.suggestions(for: completion.query)
            let headings = completionHeadings
            let isHeading = completion.query.contains("#")
            let count = isHeading ? headings.count : suggestions.count
            switch command {
            case "dismiss":
                dismissEditorCompletion()
                navigation?.hasLinkCompletion = false
            case "accept":
                guard count > 0 else { return false }
                if isHeading, let target = completionHeadingTarget {
                    let heading = headings[min(linkCompletionSelection, headings.count - 1)]
                    insertCompletedLink(to: target,
                        fragment: NotebookLinkDestination.wikiHeadingFragment(heading))
                } else {
                    insertCompletedLink(to: suggestions[min(linkCompletionSelection, suggestions.count - 1)])
                }
            case "next":
                linkCompletionSelection = min(max(0, count - 1), linkCompletionSelection + 1)
            case "previous":
                linkCompletionSelection = max(0, linkCompletionSelection - 1)
            default: return false
            }
            return true
        }
        navigation.selectionChanged = { [weak navigation] text, range, editing in
            guard navigation === editorNavigation, editing, !busy, historyBrowser == nil,
                  let session, session.isEditingEnabled,
                  text.utf8.elementsEqual(session.text.utf8), linkInsertion == nil else {
                dismissEditorCompletion()
                navigation?.hasLinkCompletion = false
                return
            }
            let variable = canCompleteSnippetVariable
                ? NotebookSnippetVariableCompletion.detect(in: text, selection: range) : nil
            if variable?.query != variableCompletion?.query { linkCompletionSelection = 0 }
            if variableCompletion != variable { variableCompletion = variable }
            if variable != nil { variableCompletionSelection = range }
            let completion = variable == nil
                ? NotebookLinkCompletion.detect(in: text, selection: range) : nil
            if completion?.query != linkCompletion?.query { linkCompletionSelection = 0 }
            linkCompletion = completion
            navigation?.hasLinkCompletion = completion != nil || variable != nil
            // Only an active completion needs a source snapshot. Publishing
            // the whole note here otherwise redraws this scene on every key.
            if completion != nil || variable != nil { linkCompletionText = text }
        }
    }

    private func currentLinkVisit() -> NotebookLinkNavigationHistory.Visit? {
        guard let selectedID else { return nil }
        let position = editorNavigation.capturePosition?().flatMap {
            try? JSONEncoder().encode($0)
        }
        return .init(noteID: selectedID, position: position)
    }

    private func resetLinkJourney() {
        linkJourneyID = UUID()
        backlinkDeparture = nil
        linkHistory.clear()
        #if os(iOS)
        linkRoutes = []
        linkVisitPreviews = [:]
        restoringLinkRouteID = nil
        linkRootRoute = selectedID.map { NotebookLinkRoute(noteID: $0) }
        activeLinkRouteID = linkRootRoute?.id
        #endif
    }

    private func rememberLinkVisitPreview(route: NotebookLinkRoute? = nil) {
        #if os(iOS)
        guard let route = route ?? linkRoutes.last ?? linkRootRoute, let session else { return }
        linkVisitPreviews[route.id] = NotebookLinkVisitPreview(
            text: session.text, position: editorNavigation.capturePosition?(),
            viewportInsets: editorNavigation.captureViewportInsets?(),
            viewportOriginY: editorNavigation.captureViewportOriginY?(),
            titleHeight: detailTitleHeight
        )
        #endif
    }

    private func showBacklinks() {
        perform {
            try await flushEditor()
            dismissEditorCompletion()
            editorNavigation.hasLinkCompletion = false
            // A presented sheet changes the underlying editor's viewport.
            // Back should return to the reading position before presentation.
            backlinkDeparture = currentLinkVisit()
            rememberLinkVisitPreview()
            if let selectedID { links.prepareBacklinks(replica: replica, targetID: selectedID) }
            showingBacklinks = true
        }
    }

    private func openNoteLink(_ occurrence: NotebookLinkOccurrence) {
        guard let sourceID = selectedID else { return }
        perform {
            try await flushEditor()
            guard sourceID == selectedID,
                  NotebookLinkParser.parse(session?.text ?? "").contains(occurrence)
            else { throw NotebookLinkUIError.changed }
            let notes = replica.linkNotes
            switch NotebookLinkResolver.resolve(occurrence, sourceID: sourceID, notes: notes) {
            case .resolved(let targetID, let fragment):
                try await visitLinkedNote(targetID, fragment: fragment)
            case .ambiguous(let ids):
                linkChoices = notes.filter { ids.contains($0.id) }
                linkChoiceFragment = NotebookLinkResolver.fragment(of: occurrence)
            case .missing:
                missingLink = occurrence
            case .external(let url):
                openURL(url)
            case .unsupported:
                throw NotebookLinkUIError.unsupported
            }
        }
    }

    private func visitLinkedNote(_ id: UUID, fragment: String?,
                                 occurrence: NotebookLinkOccurrence? = nil,
                                 targetID: UUID? = nil) async throws {
        try await flushEditor()
        if let occurrence, let targetID {
            let opened = try await replica.openNote(id)
            guard currentBacklinkRange(occurrence, sourceID: id, targetID: targetID,
                text: opened.text) != nil else { throw NotebookLinkUIError.changed }
        }
        let sheetDeparture = occurrence != nil && targetID == selectedID
            && backlinkDeparture?.noteID == selectedID ? backlinkDeparture : nil
        let previous = sheetDeparture ?? currentLinkVisit()
        if sheetDeparture == nil { rememberLinkVisitPreview() }
        rememberEditorPosition()
        try await selectNote(id, linkVisit: true)
        guard selectedID == id else { return }
        revealLinkedNoteInFiles(id)
        if let previous { linkHistory.recordDeparture(previous) }
        #if os(iOS)
        let retainedRoutes = Set(linkRoutes.map(\.id) + [linkRootRoute?.id].compactMap { $0 })
        linkVisitPreviews = linkVisitPreviews.filter { retainedRoutes.contains($0.key) }
        linkRoutes.append(NotebookLinkRoute(noteID: id))
        activeLinkRouteID = linkRoutes.last?.id
        if linkRoutes.count > linkHistory.limit {
            if let oldRoot = linkRootRoute { linkVisitPreviews[oldRoot.id] = nil }
            linkRootRoute = linkRoutes.removeFirst()
        }
        #endif
        dismissEditorCompletion()
        let incoming = editorNavigation
        incoming.hasExplicitVisitDestination = true
        incoming.whenAttached { [weak incoming] in
            guard let incoming, selectedID == id, let text = session?.text else { return }
            var destination: NSRange?
            if let occurrence, let targetID {
                destination = currentBacklinkRange(occurrence, sourceID: id,
                    targetID: targetID, text: text)
                guard destination != nil else {
                    errorMessage = NotebookLinkUIError.changed.localizedDescription
                    return
                }
            } else if let fragment {
                destination = NotebookLinkParser.targetRange(for: fragment, in: text)
                if destination == nil { errorMessage = NotebookLinkUIError.missingFragment.localizedDescription }
            }
            // Plain links open at the start; returning restores the visit position.
            incoming.revealSearchMatch?(destination ?? NSRange(location: 0, length: 0))
        }
    }

    private func currentBacklinkRange(_ occurrence: NotebookLinkOccurrence,
                                      sourceID: UUID, targetID: UUID, text: String) -> NSRange? {
        let current = NotebookLinkParser.parse(text).filter {
            if case .resolved(let resolved, _) = NotebookLinkResolver.resolve(
                $0, sourceID: sourceID, notes: replica.linkNotes) { return resolved == targetID }
            return false
        }
        if let exact = current.first(where: { $0 == occurrence }) { return exact.range }
        let matching = current.filter {
            $0.destination == occurrence.destination && $0.label == occurrence.label
        }
        return matching.count == 1 ? matching[0].range : nil
    }

    private func navigateLinkHistory(back: Bool, steps: Int = 1,
                                     compactRoutesBeforePop: [NotebookLinkRoute]? = nil) {
        let target = back ? linkHistory.backTarget(steps: steps) : linkHistory.forwardTarget
        guard let target else { return }
        let journeyID = linkJourneyID
        perform {
            do {
                try await flushEditor()
                guard linkJourneyID == journeyID else { return }
                guard let current = currentLinkVisit() else { return }
                rememberLinkVisitPreview(route: compactRoutesBeforePop?.last)
                try await selectNote(target.noteID,
                                     revealDetail: !usesCompactLinkNavigation, linkVisit: true)
                guard linkJourneyID == journeyID else { return }
                guard selectedID == target.noteID else { throw NotebookLinkUIError.changed }
                revealLinkedNoteInFiles(target.noteID)
                if back { linkHistory.commitBack(current: current, steps: steps) }
                else { linkHistory.commitForward(current: current) }
                #if os(iOS)
                if back {
                    if compactRoutesBeforePop == nil {
                        linkRoutes.removeLast(min(steps, linkRoutes.count))
                    }
                } else {
                    linkRoutes.append(NotebookLinkRoute(noteID: target.noteID))
                }
                let incomingRoute = linkRoutes.last ?? linkRootRoute
                if usesCompactLinkNavigation, session?.isEditingEnabled == true,
                   let incomingRoute,
                   target.position != nil, linkVisitPreviews[incomingRoute.id] != nil {
                    // Keep the already-positioned transition preview until
                    // TextKit finishes restoring the replacement editor.
                    restoringLinkRouteID = incomingRoute.id
                } else {
                    restoringLinkRouteID = nil
                }
                activeLinkRouteID = incomingRoute?.id
                // Popped screens remain alive through UIKit's transition. Keep
                // their previews until the next push or a fresh journey.
                #endif
                let incoming = editorNavigation
                incoming.hasExplicitVisitDestination = true
                #if os(iOS)
                let restorationRouteID = restoringLinkRouteID
                #endif
                incoming.whenAttached { [weak incoming] in
                    guard let incoming, selectedID == target.noteID else { return }
                    let finishRestoration = {
                        #if os(iOS)
                        guard incoming === editorNavigation, linkJourneyID == journeyID,
                              restoringLinkRouteID == restorationRouteID else { return }
                        restoringLinkRouteID = nil
                        #endif
                    }
                    if let data = target.position,
                       let position = try? JSONDecoder().decode(MarkdownEditorPosition.self, from: data) {
                        #if os(iOS)
                        if usesCompactLinkNavigation, let restore = incoming.restorePositionAndNotify {
                            restore(position, finishRestoration)
                        } else {
                            incoming.restorePosition?(position)
                            finishRestoration()
                        }
                        #else
                        incoming.restorePosition?(position)
                        #endif
                    } else {
                        finishRestoration()
                    }
                }
            } catch {
                #if os(iOS)
                if linkJourneyID == journeyID {
                    restoringLinkRouteID = nil
                    if let compactRoutesBeforePop {
                        // Failed saves leave the visit/history intact and
                        // return to its original screen without losing text.
                        linkRoutes = compactRoutesBeforePop
                    }
                }
                #endif
                throw error
            }
        }
    }

    private func openBacklink(_ backlink: NotebookBacklink, targetID: UUID) {
        perform {
            try await visitLinkedNote(backlink.sourceID, fragment: nil,
                occurrence: backlink.occurrence, targetID: targetID)
            showingBacklinks = false
        }
    }

    private func insertCompletedLink(to target: NotebookLinkNote, fragment: String? = nil,
                                     completionSnapshot: NotebookLinkCompletion? = nil,
                                     textSnapshot: String? = nil, sourceID: UUID? = nil) {
        // A touch on the suggestion list can end native text input before the
        // button action arrives. Use that row's captured authoring intent;
        // the editor's text/revision guards still reject stale insertions.
        guard let completion = completionSnapshot ?? linkCompletion,
              let sourceID = sourceID ?? selectedID, sourceID == selectedID,
              let source = replica.linkNotes.first(where: { $0.id == sourceID }),
              let currentTarget = replica.linkNotes.first(where: { $0.id == target.id }),
              let destination = NotebookLinkDestination.make(target: currentTarget, source: source,
                kind: .wiki,
                fragment: fragment ?? NotebookLinkParser.literalDestinationParts(completion.query).fragment,
                includeExtension: false) else { return }
        let alias = links.alias(for: completion.query, noteID: target.id)
        let escapedAlias = alias.map {
            $0.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "]", with: "\\]")
        }
        let replacement = "[[\(destination)\(escapedAlias.map { "|" + $0 } ?? "")]]"
        let change = MarkdownEditingChange(range: completion.range, replacement: replacement,
            selection: NSRange(location: completion.range.location + replacement.utf16.count, length: 0))
        if editorNavigation.insertLink?(change, textSnapshot ?? linkCompletionText) != true {
            errorMessage = NotebookLinkUIError.changed.localizedDescription
        }
        dismissEditorCompletion()
        editorNavigation.hasLinkCompletion = false
    }

    private func insertPickedLink(to target: NotebookLinkNote,
                                  request: NotebookLinkInsertionRequest) {
        guard let source = replica.linkNotes.first(where: { $0.id == request.sourceID }),
              let currentTarget = replica.linkNotes.first(where: { $0.id == target.id }),
              let destination = NotebookLinkDestination.make(target: currentTarget,
                source: source, kind: .markdown) else { return }
        insertPickedURL(destination, request: request,
            defaultLabel: NotebookNoteName.title(from: target.name))
    }

    private func insertPickedURL(_ destination: String, request: NotebookLinkInsertionRequest,
                                 defaultLabel: String = "Link") {
        guard selectedID == request.sourceID else { return }
        let label = (request.label.isEmpty ? defaultLabel : request.label)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        let safeDestination = destination
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
            .replacingOccurrences(of: " ", with: "%20")
        let replacement = "[\(label)](\(safeDestination))"
        let change = MarkdownEditingChange(range: request.range, replacement: replacement,
            selection: NSRange(location: request.range.location + replacement.utf16.count, length: 0))
        if editorNavigation.insertLink?(change, request.text) != true {
            errorMessage = NotebookLinkUIError.changed.localizedDescription
        }
        linkInsertion = nil
    }

    private func createMissingLinkedNote(_ link: NotebookLinkOccurrence) {
        guard let sourceID = selectedID else { return }
        perform {
            try await flushEditor()
            let notes = replica.linkNotes
            guard case .missing = NotebookLinkResolver.resolve(link, sourceID: sourceID,
                notes: notes), let source = notes.first(where: { $0.id == sourceID })
            else { throw NotebookLinkUIError.changed }
            let path = NotebookLinkResolver.path(of: link)
            let explicitRelative = path.hasPrefix("./") || path.hasPrefix("../")
            let base = link.kind == .markdown || explicitRelative ? source.path : (source.rootPath ?? "")
            var components = base.split(separator: "/").map(String.init)
            for part in path.split(separator: "/") {
                if part == "." { continue }
                if part == ".." {
                    guard !components.isEmpty else { throw NotebookLinkUIError.unsupported }
                    components.removeLast()
                } else { components.append(String(part)) }
            }
            guard var name = components.popLast(), !name.isEmpty else { throw NotebookLinkUIError.unsupported }
            if !name.lowercased().hasSuffix(".md") && !name.lowercased().hasSuffix(".markdown") { name += ".md" }
            var parentID: UUID?
            for folder in components {
                let matches = replica.placements.filter {
                    $0.item.kind == .folder && !$0.isInTrash
                        && $0.parentID == parentID && $0.displayName == folder
                }
                guard matches.count == 1 else { throw NotebookLinkUIError.missingFolder }
                parentID = matches[0].item.id
            }
            let id = try await replica.createNote(name: name, parentID: parentID)
            missingLink = nil
            try await visitLinkedNote(id, fragment: nil)
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
        _ id: UUID, revealDetail: Bool = true, searchVisit: Bool = false,
        linkVisit: Bool = false
    ) async throws {
        if id != selectedID {
            try await flushEditor()
            searchDestinationID = nil
            pendingSearchQuery = nil
            let notebookID = replica.catalogSnapshot?.notebookID
            let openedSession = try await replica.openNote(id, allowingRecovery: true)
            if searchVisit || linkVisit {
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
        if selectedID == id, !linkVisit { resetLinkJourney() }
        if revealDetail, preferredCompactColumn != .detail {
            preferredCompactColumn = .detail
        }
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
                    detailTitleFocusRequest = NotebookTitleFocusRequest(
                        noteID: detailEditingID, selectsAll: false
                    )
                }
            }
            editorNavigation.resumeEditing?()
            busy = false
            if succeeded { onSuccess() }
            onCompletion(succeeded)
        }
    }
}

#if os(iOS)
/// The preceding screen stays readable during an interactive Back gesture.
/// Only the top visit owns an editable session and navigation callbacks.
private struct NotebookPreviousLinkView: View {
    let text: String
    let position: MarkdownEditorPosition?
    let title: String
    let viewportInsets: UIEdgeInsets?
    let titleHeight: CGFloat
    let viewportOriginY: CGFloat?
    let titleFont: Font
    let fontSize: Double
    let fontFamily: EditorFontFamily
    let mode: MarkdownEditorMode
    var body: some View {
        MarkdownEditor(
            text: .constant(text), isReadOnly: true,
            title: AnyView(Text(title).font(titleFont)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)),
            titleHeight: titleHeight, fontSize: fontSize, fontFamily: fontFamily, mode: mode,
            initialPreviewPosition: position, initialPreviewInsets: viewportInsets,
            initialPreviewOriginY: viewportOriginY
        )
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif

private enum NotebookLinkUIError: LocalizedError {
    case changed, unsupported, missingFragment, missingFolder
    var errorDescription: String? {
        switch self {
        case .changed: "This link changed. Open it again to use its current destination."
        case .unsupported: "This link points to content that meh.md does not support yet."
        case .missingFragment: "The note opened, but its linked heading or block could not be found."
        case .missingFolder: "Create the destination folder in Files before creating this linked note."
        }
    }
}

#if os(macOS)
/// A virtualized sidebar field owns focus only after its native row mounts.
private struct NotebookInlineNameField: View {
    @Binding var text: String
    let isEnabled: Bool
    @FocusState private var isFocused: Bool
    @State private var selection: TextSelection?
    @State private var isReady = false
    @State private var hasFocused = false

    private struct Readiness: Equatable {
        let isReady: Bool
        let isEnabled: Bool
    }

    var body: some View {
        TextField("Name", text: $text, selection: $selection)
            .focused($isFocused)
            .background {
                NotebookInlineNameReadiness { isReady = $0 }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .task(id: Readiness(isReady: isReady, isEnabled: isEnabled)) {
                guard isReady, isEnabled, !hasFocused else { return }
                isFocused = true
                selection = TextSelection(range: text.startIndex..<text.endIndex)
            }
            .onChange(of: isFocused) { _, focused in
                if focused { hasFocused = true }
            }
            .onDisappear { isFocused = false }
    }
}

private struct NotebookInlineNameReadiness: NSViewRepresentable {
    let onReady: (Bool) -> Void

    func makeNSView(context: Context) -> NotebookInlineNameReadinessView {
        let view = NotebookInlineNameReadinessView()
        view.onReady = onReady
        return view
    }

    func updateNSView(_ view: NotebookInlineNameReadinessView, context: Context) {
        view.onReady = onReady
        view.checkReadiness()
    }
}

private final class NotebookInlineNameReadinessView: NSView {
    var onReady: ((Bool) -> Void)?
    private var reportedReady = false
    private var attachmentGeneration = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachmentGeneration &+= 1
        checkReadiness()
    }

    override func layout() {
        super.layout()
        checkReadiness()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func checkReadiness() {
        let ready = window != nil && bounds.width > 0 && bounds.height > 0
        guard reportedReady != ready else { return }
        // Reveal the mounted field through its actual native scroll ancestors
        // before requesting focus; no responder-chain action or timer is used.
        reportedReady = ready
        if ready { scrollToVisible(bounds) }
        let generation = attachmentGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.attachmentGeneration == generation,
                  ready == (self.window != nil
                      && self.bounds.width > 0 && self.bounds.height > 0)
            else { return }
            self.onReady?(ready)
        }
    }
}
#endif

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
