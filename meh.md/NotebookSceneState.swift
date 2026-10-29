import Foundation
import NoteCore
import Observation
import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// One notebook window's interaction state and the actions shared by its
/// views. Views hold only a reference, which keeps each view value small.
@MainActor
@Observable
final class NotebookSceneState {
    let replica: NotebookReplica
    let workspace: NotebookWorkspace?
    let incomingImports: NotebookIncomingImportRequests?
    let preferredNoteID: UUID?
    let navigationState: NotebookNavigationState
    let recentCommands: NotebookRecentCommandState
    #if os(macOS)
    let menu = NotebookMenuState()
    #endif

    // MARK: Scene

    var busy = false
    var errorMessage: String?
    var restoredNavigation = false
    var editorNavigation = MarkdownEditorNavigation()
    var bodyFocusRequest = 0
    var unrecordedEdit = false
    var trashedOpenNote = 0
    var recentActivityFailureIDs = Set<UUID>()
    var preferredCompactColumn = NavigationSplitViewColumn.sidebar
    /// Mirrors the window's size class for actions; views read their own.
    var isCompact = false

    // MARK: Presentation

    var sharedImport: NotebookIncomingImport?
    var sharedImportID: UUID?
    var showingExport = false
    var showingImport = false
    var importingFolder = false
    var choosingImportSource = false
    var showingSettings = false
    var showingSyncDetails = false
    var showingTemplates = false
    var pendingPresentedItemID: UUID?
    var showingTrash = false
    var showingTextSize = false
    var sharedFile: NotebookSharedFile?
    var deletionSelection: NotebookDeletionSelection?
    #if os(iOS)
    let quickActionRequests = NotebookQuickActionRequests.shared
    var pendingTemplateQuickAction = false
    var awaitingQuickActionSheetDismissal = false
    #endif

    // MARK: Search

    let search = NotebookSearchState()
    /// The search field's focus, lent by the view that owns it.
    @ObservationIgnored var searchFocus: FocusState<Bool>.Binding?
    var pendingSearchQuery: String?
    var searchDestinationID: UUID?
    var quickOpenDidNavigate = false
    var resumeEditorAfterQuickOpen = false
    var searchLandingPosition: MarkdownEditorPosition?

    // MARK: Links

    let links = NotebookLinkState()
    let linkHistory = NotebookLinkNavigationHistory()
    var linkJourneyID = UUID()
    var showingBacklinks = false
    var backlinkDeparture: NotebookLinkNavigationHistory.Visit?
    var linkInsertion: NotebookLinkInsertionRequest?
    var linkChoices: [NotebookLinkNote] = []
    var linkChoiceFragment: String?
    var missingLink: NotebookLinkOccurrence?
    #if os(iOS)
    var linkRootRoute: NotebookLinkRoute?
    var linkRoutes: [NotebookLinkRoute] = []
    var activeLinkRouteID: UUID?
    var restoringLinkRouteID: UUID?
    var linkVisitPreviews: [UUID: NotebookLinkVisitPreview] = [:]
    #endif

    // MARK: Editor completion

    var variableCompletionSelection = NSRange(location: 0, length: 0)
    var snippetSourceNoteIDs: Set<UUID> = []
    var variableCompletion: NotebookSnippetVariableCompletion?
    var linkCompletion: NotebookLinkCompletion?
    var linkCompletionText = ""
    var linkCompletionSelection = 0

    // MARK: History

    var historyBrowser: NoteHistoryBrowserState?
    var isLoadingHistory = false
    var historyLoadTask: Task<Void, Never>?
    var historyLoadID = UUID()

    // MARK: Library browser

    var browsingAllRecents = false
    var visibleRecentPreviewIDs: [UUID] = []
    var editingID: UUID?
    var originalName = ""
    var proposedName = ""
    /// The inline name field's focus, lent by the view that owns it.
    @ObservationIgnored var nameFocus: FocusState<UUID?>.Binding?
    var movingIDs: [UUID] = []
    var movingFromTrash = false
    var movingNotebookID: UUID?
    var destination: UUID?
    var browserSelection = NotebookBrowserSelection()
    let browserDrag = NotebookBrowserDragState()
    var browserDropViewportFrame: CGRect = .zero
    var selectingItems = false
    /// Mirrors the Files list's focus, which its view owns.
    var browserFocused = false
    var browserUndo: NotebookBrowserUndo?
    var browserRedo: NotebookBrowserUndo?
    var fileRevealRequest: NotebookFileReveal?
    var highlightedFileID: UUID?
    #if os(iOS)
    let browserScrollView = NotebookBrowserScrollReference()
    var browserViewport: NotebookBrowserViewport?
    var browserViewportHeight: CGFloat = 0
    var browserReturnViewport: NotebookBrowserViewport?
    var browserToolbarWasHidden = false
    #endif

    // MARK: Detail title

    var detailEditingID: UUID?
    var detailOriginalName = ""
    var detailProposedTitle = ""
    var detailTitleHeight: CGFloat = 32
    var detailTitleFocusRequest: NotebookTitleFocusRequest?

    init(
        replica: NotebookReplica,
        workspace: NotebookWorkspace?,
        incomingImports: NotebookIncomingImportRequests?,
        sceneID: UUID,
        preferredNoteID: UUID?
    ) {
        self.replica = replica
        self.workspace = workspace
        self.incomingImports = incomingImports
        self.preferredNoteID = preferredNoteID
        navigationState = NotebookNavigationState(replica: replica, sceneID: sceneID)
        recentCommands = NotebookRecentCommandState(replica: replica)
    }

    var selectedID: UUID? { navigationState.selectedID }
    var session: NoteSession? { navigationState.selectedSession }
    var expandedIDs: Set<UUID> {
        get { navigationState.expandedFolderIDs }
        set { navigationState.expandedFolderIDs = newValue }
    }

    var selectedPlacement: NotebookPlacement? {
        replica.placements.first { $0.item.id == selectedID }
    }

    var isLibraryEmpty: Bool {
        !replica.placements.contains {
            !$0.isInTrash && !$0.item.isPermanentlyDeleted
        }
    }

    #if os(macOS)
    var menuAvailable: Bool {
        !busy && !search.showingQuickOpen && !showingSettings
            && !showingTrash && !showingImport && !showingExport
            && !choosingImportSource && !showingTextSize
            && movingIDs.isEmpty && deletionSelection == nil
            && errorMessage == nil && sharedImportID == nil
            && !showingBacklinks && linkInsertion == nil
            && linkChoices.isEmpty && missingLink == nil
            && workspace?.isResetPending != true
    }

    var canManageMenuSelection: Bool {
        menuAvailable && browserFocused && editingID == nil
            && detailEditingID == nil && !search.isPresented
            && !browserSelection.isEmpty
    }
    #endif

    // MARK: Scene lifecycle

    func restoreNavigation() async {
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

    func catalogSnapshotChanged(
        from previous: NotebookCatalogSnapshot?, to current: NotebookCatalogSnapshot?
    ) {
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

    func selectedNoteChanged(to id: UUID?) {
        historyLoadTask?.cancel()
        dismissEditorCompletion()
        updateSnippetMenu()
        if historyBrowser != nil { closeHistory() }
        recentCommands.selectedNoteID = id
    }

    /// Restores the reading position once a newly attached editor is ready.
    func restoreEditorPosition(noteID selectedID: UUID, session: NoteSession) {
        guard session.isEditingEnabled, historyBrowser == nil else { return }
        let incomingNavigation = editorNavigation
        guard !incomingNavigation.hasExplicitVisitDestination else { return }
        let state = navigationState
        let position = state.position(for: selectedID).flatMap {
            try? JSONDecoder().decode(MarkdownEditorPosition.self, from: $0)
        }
        incomingNavigation.whenAttached { [weak self, weak incomingNavigation, weak state] in
            guard let self, let incomingNavigation,
                  !incomingNavigation.hasExplicitVisitDestination,
                  state?.selectedID == selectedID else { return }
            if searchDestinationID == selectedID {
                revealSearchDestination(in: incomingNavigation)
            } else if let position {
                incomingNavigation.restorePosition?(position)
            }
        }
    }

    func setPreferredCompactColumn(_ column: NavigationSplitViewColumn, isCompact: Bool) {
        #if os(iOS)
        if column == .sidebar, preferredCompactColumn == .detail, isCompact {
            // A collapsed split view also reports Files while it pops a
            // link visit inside the note column; the path update follows.
            // Only leaving the first visit returns to Files.
            guard linkRoutes.isEmpty, !busy else { return }
            // Commit composition synchronously while its editor
            // is still attached; the note session remains open.
            guard editorNavigation.prepareToLeave?() != false, !unrecordedEdit else {
                errorMessage = NotebookNavigationError.unrecordedEdit.localizedDescription
                editorNavigation.resumeEditing?()
                return
            }
            rememberEditorPosition()
        }
        #endif
        preferredCompactColumn = column
    }

    func recordLocalEdit(in selectedID: UUID) {
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
    }

    // MARK: Presentation

    #if os(iOS)
    func handlePendingQuickAction() {
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

    func finishTemplatePresentation() {
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
        perform { [self] in
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

    func incomingImportRequested() {
        guard incomingImports?.requests.first != nil else { return }
        if showingSettings { showingSettings = false }
        else if showingTrash { showingTrash = false }
        else if showingTemplates, !busy { showingTemplates = false }
        else { presentSharedImport() }
    }

    func presentSharedImport() {
        guard sharedFile == nil, sharedImportID == nil, !busy,
              !showingSettings, !showingTemplates, !showingTrash,
              !showingImport, movingIDs.isEmpty, !replica.hasPendingImport,
              let request = incomingImports?.requests.first else { return }
        sharedImportID = request.id
        sharedImport = request
    }

    func finishSharedImport() {
        if let request = incomingImports?.requests.first(where: { $0.id == sharedImportID }) {
            incomingImports?.finish(request)
        }
        sharedImportID = nil
        presentSharedImport()
    }

    func importMarkdown(_ plan: NotebookImportPlan?) async throws {
        try await importMarkdown(plan, parentID: nil)
    }

    func importMarkdown(
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
        if isCompact { preferredCompactColumn = .sidebar }
    }

    func requestImport() {
        #if os(iOS)
        guard !busy else { return }
        choosingImportSource = true
        #else
        showImport(choosingFolder: false)
        #endif
    }

    func showImport(choosingFolder: Bool) {
        perform { [self] in
            try await flushEditor()
            importingFolder = choosingFolder
            showingImport = true
        }
    }

    func openTrash() {
        perform { [self] in
            try await flushEditor()
            showingTrash = true
        }
    }

    func openSettings() {
        guard !showingSettings, !showingTrash, !showingImport,
              !search.showingQuickOpen, movingIDs.isEmpty else { return }
        perform { [self] in
            try await flushEditor()
            showingSettings = true
        }
    }

    func shareMarkdown() {
        guard sharedFile == nil, let session, let noteID = selectedID else { return }
        perform { [self] in
            try await flushEditor()
            guard selectedID == noteID, session.isEditingEnabled,
                  let placement = selectedPlacement else { return }
            sharedFile = try NotebookSharedFile.markdown(
                text: session.text, filename: placement.displayName
            )
        }
    }

    // MARK: Search

    var searchTaskID: NotebookSearchTaskID {
        NotebookSearchTaskID(revision: replica.searchRevision, query: search.activeQuery,
                             active: search.isPresented || search.showingQuickOpen,
                             quick: search.showingQuickOpen,
                             recents: navigationState.recentNoteIDs)
    }

    func refreshSearch() async {
        // Warm once in the background; don't rescan on every editor
        // keystroke while search is closed.
        guard search.isPresented || search.showingQuickOpen
                || !search.hasPreparedCorpus else { return }
        await search.refresh(replica: replica, recentIDs: navigationState.recentNoteIDs)
    }

    func searchScopeChanged() {
        search.clear()
        searchLandingPosition = nil
        pendingSearchQuery = nil
        searchDestinationID = nil
    }

    func quickOpenDismissed() {
        editorNavigation.resumeEditing?()
        if !quickOpenDidNavigate {
            if resumeEditorAfterQuickOpen { editorNavigation.focusEditor?() }
            else if search.isPresented { searchFocus?.wrappedValue = true }
        }
    }

    func showFind() {
        guard !busy, !search.showingQuickOpen else { return }
        searchFocus?.wrappedValue = false
        editorNavigation.showFind?()
    }

    func showQuickOpen() {
        guard !busy, !search.showingQuickOpen, !showingSettings, !showingTemplates,
              !showingTrash, !showingImport else { return }
        resumeEditorAfterQuickOpen = editorNavigation.captureHasEditingFocus?() == true
        // Commit native marked-text safely before moving focus to the picker.
        guard editorNavigation.prepareToLeave?() != false, !unrecordedEdit else {
            errorMessage = NotebookNavigationError.unrecordedEdit.localizedDescription
            editorNavigation.resumeEditing?()
            return
        }
        searchFocus?.wrappedValue = false
        quickOpenDidNavigate = false
        search.beginQuickOpen()
    }

    func openSearchResult(
        _ result: NotebookSearchResult, query: String, fromQuickOpen: Bool = false
    ) {
        perform { [self] in
            guard replica.placements.contains(where: {
                $0.item.id == result.id && !$0.isInTrash && !$0.item.isPermanentlyDeleted
            }) else { return }
            // Save ordinary position before marking this visit as a search jump.
            rememberEditorPosition()
            searchFocus?.wrappedValue = false
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
            incoming.whenAttached { [weak self, weak incoming] in
                guard let self, let incoming, selectedID == result.id else { return }
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

    // MARK: Navigation

    func flushEditor() async throws {
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

    func rememberEditorPosition() {
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

    func selectNote(
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

    func perform(
        _ operation: @escaping @MainActor () async throws -> Void,
        onSuccess: @escaping @MainActor () -> Void = {},
        onCompletion: @escaping (Bool) -> Void = { _ in }
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
                    Task { @MainActor in nameFocus?.wrappedValue = editingID }
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

    // MARK: Detail title

    func beginDetailRenaming(_ placement: NotebookPlacement) {
        perform { [self] in
            try await flushEditor()
            detailEditingID = placement.item.id
            detailOriginalName = placement.item.name
            detailProposedTitle = NotebookNoteName.title(from: placement.item.name)
            detailTitleFocusRequest = NotebookTitleFocusRequest(
                noteID: placement.item.id, selectsAll: false
            )
        }
    }

    func submitDetailTitle(focusBody: Bool = true) {
        guard detailEditingID != nil else { return }
        perform { [self] in
            try await commitDetailTitleIfNeeded()
        } onSuccess: { [self] in
            if focusBody { bodyFocusRequest &+= 1 }
        }
    }

    /// The title field's text. Return submits the title instead of adding
    /// a line.
    func setDetailProposedTitle(_ value: String) {
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

    func cancelDetailTitle() {
        detailEditingID = nil
        detailTitleFocusRequest = nil
        detailOriginalName = ""
        detailProposedTitle = ""
        editorNavigation.resumeEditing?()
    }
}

struct NotebookSearchTaskID: Hashable {
    let revision: NotebookSearchRevision
    let query: String
    let active: Bool
    let quick: Bool
    let recents: [UUID]
}

enum NotebookNavigationError: LocalizedError {
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
