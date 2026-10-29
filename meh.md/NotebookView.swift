import Foundation
import NoteCore
import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// A notebook window. Its sections are separate views that share one
/// `NotebookSceneState`, so each view value stays small. Debug builds keep
/// a copy of a view for every closure in its body, and the iPhone's main
/// thread has only 1 MiB of stack.
struct NotebookView: View {
    @State private var scene: NotebookSceneState
    @FocusState private var searchFocused: Bool
    @FocusState private var focusedNameID: UUID?
    @FocusState private var browserFocused: Bool
    @FocusState private var focusedRecentID: UUID?
    #if os(macOS)
        @FocusState private var recentsMoreFocused: Bool
        @FocusState private var recentsHeaderFocused: Bool
    #endif
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    init(
        replica: NotebookReplica,
        workspace: NotebookWorkspace? = nil,
        incomingImports: NotebookIncomingImportRequests? = nil,
        sceneID: UUID,
        preferredNoteID: UUID? = nil
    ) {
        _scene = State(initialValue: NotebookSceneState(
            replica: replica, workspace: workspace, incomingImports: incomingImports,
            sceneID: sceneID, preferredNoteID: preferredNoteID
        ))
    }

    private var isCompact: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    private var focus: NotebookSceneFocus {
        #if os(macOS)
        NotebookSceneFocus(search: $searchFocused, name: $focusedNameID,
                           browser: $browserFocused, recent: $focusedRecentID,
                           recentsMore: $recentsMoreFocused,
                           recentsHeader: $recentsHeaderFocused)
        #else
        NotebookSceneFocus(search: $searchFocused, name: $focusedNameID,
                           browser: $browserFocused, recent: $focusedRecentID)
        #endif
    }

    var body: some View {
        NotebookNavigationContainer(scene: scene, focus: focus, isCompact: isCompact)
            .modifier(NotebookSnippetNavigation(scene: scene))
            .modifier(NotebookSearchNavigation(scene: scene))
            .modifier(NotebookScenePresentation(scene: scene))
            .onChange(of: isCompact, initial: true) { _, compact in
                scene.isCompact = compact
            }
            .onChange(of: focusedRecentID) { _, id in
                scene.recentCommands.focusedNoteID = id
            }
            #if os(macOS)
            // The Mac menu bar's Move and Trash act on a focused Files list.
            .onChange(of: browserFocused, initial: true) { _, focused in
                scene.browserFocused = focused
            }
            #endif
            .onAppear {
                scene.searchFocus = $searchFocused
                scene.nameFocus = $focusedNameID
            }
    }
}

/// The window's focus, passed to the sidebar. It is declared in
/// `NotebookView`: declared inside the sidebar column, setting it no longer
/// focused the inline name field in Files.
struct NotebookSceneFocus {
    let search: FocusState<Bool>.Binding
    let name: FocusState<UUID?>.Binding
    let browser: FocusState<Bool>.Binding
    let recent: FocusState<UUID?>.Binding
    #if os(macOS)
    let recentsMore: FocusState<Bool>.Binding
    let recentsHeader: FocusState<Bool>.Binding
    #endif
}

private struct NotebookNavigationContainer: View {
    let scene: NotebookSceneState
    let focus: NotebookSceneFocus
    /// One column, like iPhone or a folded iPhone Duo.
    let isCompact: Bool

    var body: some View {
        NavigationSplitView(preferredCompactColumn: Binding(
            get: { scene.preferredCompactColumn },
            set: { scene.setPreferredCompactColumn($0, isCompact: isCompact) }
        )) {
            NotebookSidebar(scene: scene, focus: focus, isCompact: isCompact)
        } detail: {
            #if os(iOS)
            // One container for every width, so folding iPhone Duo or
            // resizing a window keeps the editor and its link visits.
            NavigationStack(path: Binding(
                // A single column showing Files pops every visit at once.
                get: { showsFilesColumn ? [] : scene.linkRoutes },
                set: { routes in
                    guard !showsFilesColumn else { return }
                    scene.navigateLinkRoutes(to: routes)
                }
            )) {
                NotebookLinkScreen(scene: scene, route: scene.linkRootRoute,
                                   isCompact: isCompact, isRoot: true)
                    .navigationDestination(for: NotebookLinkRoute.self) { route in
                        NotebookLinkScreen(scene: scene, route: route, isCompact: isCompact)
                    }
            }
            #else
            NotebookDetail(scene: scene, isCompact: isCompact)
            #endif
        }
    }

    private var showsFilesColumn: Bool {
        isCompact && scene.preferredCompactColumn == .sidebar
    }
}

#if os(iOS)
private struct NotebookLinkScreen: View {
    let scene: NotebookSceneState
    let route: NotebookLinkRoute?
    let isCompact: Bool
    var isRoot = false
    @AppStorage("editor.fontSize", store: NotebookEditorPreferences.store)
    private var editorFontSize = 17.0
    @AppStorage("editor.fontFamily", store: NotebookEditorPreferences.store)
    private var editorFontFamilyRaw =
        EditorFontFamily.system.rawValue
    @AppStorage("editor.mode", store: NotebookEditorPreferences.store)
    private var editorModeRaw =
        MarkdownEditorMode.livePreview.rawValue

    var body: some View {
        let title = route.flatMap { route in
            scene.replica.placements.first { $0.item.id == route.noteID }
        }.map { NotebookNoteName.title(from: $0.displayName) } ?? ""
        let fontFamily = EditorFontFamily(rawValue: editorFontFamilyRaw) ?? .system
        // Opening the incoming session can publish before the route changes.
        // A departing screen must keep its own preview throughout that gap.
        // Without a selection the root shows the empty detail instead.
        let showsLiveEditor = (isRoot && scene.selectedID == nil)
            || (scene.activeLinkRouteID == route?.id && route?.noteID == scene.selectedID)
        let showsHistory = showsLiveEditor && scene.historyBrowser != nil
        let showsSnippetReturn = showsLiveEditor && scene.visibleSnippetReturn != nil
        let isRestoring = scene.session?.isEditingEnabled == true
            && (route.map { scene.restoringLinkRouteID == $0.id } ?? false)
        return ZStack {
            if showsLiveEditor {
                NotebookDetail(scene: scene, isCompact: isCompact)
                    .opacity(isRestoring ? 0 : 1)
                    .allowsHitTesting(!isRestoring)
            }
            if let route, let preview = scene.linkVisitPreviews[route.id],
               !showsLiveEditor || isRestoring {
                NotebookPreviousLinkView(
                    text: preview.text, position: preview.position, title: title,
                    viewportInsets: preview.viewportInsets, titleHeight: preview.titleHeight,
                    viewportOriginY: preview.viewportOriginY,
                    titleFont: NotebookDetailTitle.font(
                        family: fontFamily, size: editorFontSize
                    ),
                    fontSize: editorFontSize, fontFamily: fontFamily,
                    mode: MarkdownEditorMode(rawValue: editorModeRaw) ?? .livePreview
                )
                .transition(.identity)
            } else if !showsLiveEditor {
                MehStyle.paperColor
            }
        }
        // Editor previews manage their own bar insets. History uses a SwiftUI
        // heading, which must stay below the status and navigation bars, and
        // the snippet return bar must stay above the home indicator.
        // Keep editor geometry fixed when a link preview is removed.
        .ignoresSafeArea(.container, edges: showsHistory ? .bottom
                         : showsSnippetReturn ? .top : [.top, .bottom])
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
}

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
    @Environment(\.mehPalette) private var palette
    var body: some View {
        MarkdownEditor(
            text: .constant(text), isReadOnly: true,
            title: AnyView(Text(title).font(titleFont)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)),
            titleHeight: titleHeight, fontSize: fontSize, fontFamily: fontFamily, mode: mode,
            palette: palette,
            initialPreviewPosition: position, initialPreviewInsets: viewportInsets,
            initialPreviewOriginY: viewportOriginY
        )
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .background(MehStyle.paperColor.ignoresSafeArea())
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif

/// Keeps the editor's snippet menu current.
private struct NotebookSnippetNavigation: ViewModifier {
    let scene: NotebookSceneState

    func body(content: Content) -> some View {
        content
        .task(id: ObjectIdentifier(scene.editorNavigation)) { scene.configureSnippetNavigation() }
        .onChange(of: scene.replica.snippets, initial: true) { _, _ in scene.updateSnippetMenu() }
        .onChange(of: scene.replica.snippetSources) { _, _ in scene.updateSnippetMenu() }
        .onChange(of: scene.busy) { _, _ in
            scene.updateSnippetMenu()
            scene.insertPendingSnippet()
        }
        .onChange(of: scene.historyBrowser == nil) { _, _ in scene.updateSnippetMenu() }
        .onChange(of: scene.session?.isEditingEnabled) { _, _ in scene.updateSnippetMenu() }
    }
}

/// Connects links, search, and the scene's commands.
private struct NotebookSearchNavigation: ViewModifier {
    let scene: NotebookSceneState
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content
        .task(id: ObjectIdentifier(scene.editorNavigation)) {
            scene.configureLinkNavigation(openURL: openURL)
        }
        .focusedSceneValue(\.notebookSearch, scene.search)
        .focusedSceneValue(\.notebookRecentCommands, scene.recentCommands)
        #if os(iOS)
        .onChange(of: scene.canGoBack, initial: true) { _, available in
            scene.search.canGoBack = available
        }
        .onChange(of: scene.search.goBackRequest) { _, _ in
            if scene.canGoBack { scene.navigateLinkHistory(back: true) }
        }
        #endif
        .onChange(of: scene.selectedID) { _, id in scene.selectedNoteChanged(to: id) }
        .onChange(of: scene.recentCommands.errorMessage) { _, message in
            if let message {
                scene.errorMessage = message
                scene.recentCommands.errorMessage = nil
            }
        }
        #if os(macOS)
        .modifier(NotebookMenuNavigation(scene: scene))
        #endif
        .task(id: scene.searchTaskID) { await scene.refreshSearch() }
        .onChange(of: scene.search.quickOpenRequest) { _, _ in scene.showQuickOpen() }
        .onChange(of: scene.search.findRequest) { _, _ in scene.showFind() }
        .onChange(of: scene.session?.isEditingEnabled, initial: true) { _, enabled in
            scene.search.canFind = enabled == true
        }
        .onChange(of: scene.workspace?.searchScopeGeneration) { _, _ in
            scene.searchScopeChanged()
        }
        .sheet(isPresented: Bindable(scene.search).showingQuickOpen,
               onDismiss: scene.quickOpenDismissed) {
            NotebookQuickOpen(search: scene.search) { result in
                scene.openSearchResult(result, query: scene.search.resultQuery,
                                       fromQuickOpen: true)
            }
        }
    }
}

#if os(macOS)
/// Handles the Mac menu bar's notebook commands.
private struct NotebookMenuNavigation: ViewModifier {
    let scene: NotebookSceneState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    func body(content: Content) -> some View {
        let menu = scene.menu
        content
        .onChange(of: scene.hasMoreRecents, initial: true) { _, available in
            scene.recentCommands.canBrowseAll = available
        }
        .onChange(of: scene.browsingAllRecents) { _, expanded in
            scene.recentCommands.isBrowsingAll = expanded
        }
        .focusedSceneValue(\.notebookMenu, menu)
        .onChange(of: scene.menuAvailable, initial: true) { _, available in
            menu.isAvailable = available
        }
        .onChange(of: scene.canManageMenuSelection, initial: true) { _, available in
            menu.canManageSelection = available
        }
        .onChange(of: scene.isLibraryEmpty, initial: true) { _, empty in
            menu.canExport = !empty
        }
        .onChange(of: supportsMultipleWindows, initial: true) { _, supported in
            menu.canOpenWindow = supported
        }
        .onChange(of: menu.newFolderRequest) { _, _ in
            guard scene.menuAvailable else { return }
            scene.createItem(kind: .folder, parentID: nil)
        }
        .onChange(of: menu.newWindowRequest) { _, _ in
            guard scene.menuAvailable, supportsMultipleWindows else { return }
            openWindow(id: "notebook", value: NotebookWindowValue())
        }
        .onChange(of: menu.importRequest) { _, _ in
            guard scene.menuAvailable else { return }
            scene.requestImport()
        }
        .onChange(of: menu.exportRequest) { _, _ in
            guard scene.menuAvailable, !scene.isLibraryEmpty else { return }
            scene.showingExport = true
        }
        .onChange(of: menu.moveRequest) { _, _ in
            guard scene.canManageMenuSelection else { return }
            scene.beginMoving(scene.selectedBrowserIDs)
        }
        .onChange(of: menu.trashRequest) { _, _ in
            guard scene.canManageMenuSelection else { return }
            scene.trashItems(scene.selectedBrowserIDs)
        }
        .onChange(of: menu.newNoteRequest) { _, _ in
            guard scene.menuAvailable else { return }
            scene.createDefaultNote()
        }
        .onChange(of: menu.settingsRequest) { _, _ in
            guard scene.menuAvailable else { return }
            scene.openSettings()
        }
    }
}
#endif

/// The scene's sheets, dialogs, and lifecycle work.
private struct NotebookScenePresentation: ViewModifier {
    @Bindable var scene: NotebookSceneState
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
        .disabled(scene.workspace?.isResetPending == true)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let workspace = scene.workspace { NotebookWorkspaceStatusView(workspace: workspace) }
        }
        .onChange(of: scene.replica.catalogSnapshot) { previous, current in
            scene.catalogSnapshotChanged(from: previous, to: current)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                scene.browserDrag.reset()
                scene.rememberEditorPosition()
            }
        }
        #if os(iOS)
        .onChange(of: scene.quickActionRequests.pendingActionCount, initial: true) { _, _ in
            scene.handlePendingQuickAction()
        }
        .onChange(of: scene.busy) { _, isBusy in
            if !isBusy { scene.handlePendingQuickAction() }
        }
        .onChange(of: scene.deletionSelection) { _, selection in
            if selection == nil { scene.handlePendingQuickAction() }
        }
        #endif
        .onDisappear {
            scene.browserDrag.reset()
            scene.historyLoadTask?.cancel()
            scene.rememberEditorPosition()
        }
        .onReceive(NotificationCenter.default.publisher(for: applicationWillTerminate)) { _ in
            scene.rememberEditorPosition()
        }
        .alert(
            "Couldn’t complete the action",
            isPresented: Binding(
                get: { scene.errorMessage != nil },
                set: { if !$0 { scene.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { scene.errorMessage = nil }
        } message: {
            Text(scene.errorMessage ?? "")
        }
        .sheet(
            isPresented: Binding(
                get: { !scene.movingIDs.isEmpty }, set: { if !$0 { scene.movingIDs = [] } }
            ),
            onDismiss: scene.presentSharedImport
        ) { moveSheet }
        .sheet(isPresented: $scene.showingBacklinks, onDismiss: {
            scene.backlinkDeparture = nil
        }) {
            if let selectedID = scene.selectedID {
                NotebookBacklinksView(state: scene.links, replica: scene.replica,
                                      noteID: selectedID) {
                    scene.openBacklink($0, targetID: selectedID)
                }
                .id(selectedID)
            }
        }
        .sheet(item: $scene.linkInsertion, onDismiss: scene.linkInsertionDismissed) { request in
            NotebookLinkPicker(state: scene.links, replica: scene.replica,
                select: { scene.insertPickedLink(to: $0, request: request) },
                insertURL: { scene.insertPickedURL($0, request: request) })
        }
        .confirmationDialog("Choose linked note", isPresented: Binding(
            get: { !scene.linkChoices.isEmpty },
            set: { if !$0 { scene.linkChoices = [] } }
        ), titleVisibility: .visible) {
            ForEach(scene.linkChoices, id: \.id) { note in
                Button(note.fullPath) { scene.chooseLinkedNote(note) }
            }
        }
        .confirmationDialog("Create linked note?", isPresented: Binding(
            get: { scene.missingLink != nil }, set: { if !$0 { scene.missingLink = nil } }
        ), titleVisibility: .visible) {
            if let missingLink = scene.missingLink {
                Button("Create Note") { scene.createMissingLinkedNote(missingLink) }
            }
            Button("Cancel", role: .cancel) { scene.missingLink = nil }
        } message: {
            Text(scene.missingLink?.destination ?? "")
        }
        .notebookMarkdownExporter(
            isPresented: $scene.showingExport, replica: scene.replica,
            beforeExport: scene.flushEditor
        )
        .notebookMarkdownImporter(
            isPresented: $scene.showingImport, choosingFolder: scene.importingFolder,
            replica: scene.replica, onImport: scene.importMarkdown
        )
        .confirmationDialog("Import Markdown", isPresented: $scene.choosingImportSource) {
            Button("Import Files…") { scene.showImport(choosingFolder: false) }
                .accessibilityIdentifier("notebook-import-files")
            Button("Import Folder…") { scene.showImport(choosingFolder: true) }
                .accessibilityIdentifier("notebook-import-folder")
        }
        .sheet(isPresented: $scene.showingTrash, onDismiss: scene.finishTemplatePresentation) {
            NavigationStack {
                NotebookTrashView(
                    replica: scene.replica,
                    beforeMutation: scene.flushEditor,
                    onMutation: scene.trashDidChange,
                    onOpenNote: scene.openNoteFromTrash
                )
            }
            #if os(macOS)
            .frame(minWidth: 400, idealWidth: 560, minHeight: 360, idealHeight: 540)
            #endif
        }
        #if os(iOS)
        .sheet(item: $scene.sharedFile, onDismiss: scene.presentSharedImport) { file in
            NotebookShareSheet(file: file) {
                if scene.sharedFile?.id == file.id { scene.sharedFile = nil }
            }
        }
        #endif
        .sheet(isPresented: $scene.showingTemplates,
               onDismiss: scene.finishTemplatePresentation) {
            NotebookTemplatePicker(
                replica: scene.replica,
                onCreate: scene.createTemplateNote,
                onOpenNote: scene.openReusableSource
            )
        }
        .sheet(isPresented: $scene.showingSettings,
               onDismiss: scene.finishTemplatePresentation) {
            NotebookSettingsView(replica: scene.replica,
                                 workspace: scene.workspace ?? NotebookWorkspace.shared,
                                 beforeExport: scene.flushEditor,
                                 onOpenNote: scene.openReusableSource)
        }
        .sheet(item: $scene.sharedImport, onDismiss: scene.finishSharedImport) { request in
            NotebookSharedImportView(plan: request.plan, replica: scene.replica) { parentID in
                try await scene.importMarkdown(request.plan, parentID: parentID)
            }
        }
        .onChange(of: scene.incomingImports?.requests.first?.id, initial: true) { _, _ in
            scene.incomingImportRequested()
        }
        .onChange(of: scene.busy) { _, busy in
            if !busy { scene.presentSharedImport() }
        }
        .onChange(of: scene.replica.hasPendingImport) { _, pending in
            if !pending { scene.presentSharedImport() }
        }
        .onChange(of: scene.showingImport) { _, presented in
            if !presented { scene.presentSharedImport() }
        }
        .confirmationDialog(
            scene.deletionSelection?.rootID == nil ? "Empty Trash?" : "Delete permanently?",
            isPresented: Binding(
                get: { scene.deletionSelection != nil },
                set: { if !$0 { scene.deletionSelection = nil } }
            ),
            titleVisibility: .visible,
            presenting: scene.deletionSelection
        ) { selection in
            Button("Delete Permanently", role: .destructive) {
                scene.deletePermanently(selection)
            }
            Button("Cancel", role: .cancel) { scene.deletionSelection = nil }
        } message: { selection in
            Text(scene.deletionMessage(selection))
        }
        .task { await scene.restoreNavigation() }
        .task(id: scene.navigationState.recentNoteIDs) {
            await scene.navigationState.loadRecentSessions()
        }
        .task(id: NotebookRecentPreviewRequest(
            ids: scene.visibleRecentPreviewIDs,
            revision: scene.navigationState.recentPreviewRevision
        )) {
            guard !scene.visibleRecentPreviewIDs.isEmpty else { return }
            await scene.navigationState.loadRecentPreviews(for: scene.visibleRecentPreviewIDs)
        }
        .onChange(of: scene.search.isPresented) { _, presented in
            if presented { scene.browsingAllRecents = false }
        }
        .onChange(of: scene.fileRevealRequest) { _, request in
            if request != nil { scene.browsingAllRecents = false }
        }
        .onChange(of: scene.selectingItems) { _, selecting in
            if selecting { scene.browsingAllRecents = false }
        }
        .onChange(of: scene.replica.catalogSnapshot?.notebookID) { _, _ in
            scene.browsingAllRecents = false
            scene.visibleRecentPreviewIDs = []
        }
    }

    private var moveSheet: some View {
        NotebookMoveSheet(
            placements: scene.replica.placements,
            sourceIDs: scene.movingIDs,
            initialParentID: scene.destination,
            isDestinationAllowed: { scene.canMoveSelection(into: $0) },
            onSubmit: { parentID in
                #if DEBUG
                // Make the in-flight layout observable in isolated UI tests.
                if NotebookWorkspace.isPreviewEnabled,
                   ProcessInfo.processInfo.environment["MEH_NOTEBOOK_MOVE_TEST_DELAY"] == "1" {
                    try await Task.sleep(for: .seconds(8))
                }
                #endif
                try await scene.commitMove(to: parentID)
            },
            onSuccess: {}
        )
    }

    private var applicationWillTerminate: Notification.Name {
        #if os(macOS)
        NSApplication.willTerminateNotification
        #else
        UIApplication.willTerminateNotification
        #endif
    }
}

private struct NotebookRecentPreviewRequest: Equatable {
    let ids: [UUID]
    let revision: NotebookSearchRevision
}
