import Foundation
import NoteCore
import SwiftUI

#if os(iOS)
    import UIKit
#endif

struct NotebookFileReveal: Equatable {
    let id: UUID
    var highlights = true
    let token = UUID()
}

struct NotebookSidebarRow: Identifiable {
    let id: UUID
    let parentID: UUID?
    let depth: Int

    init(placement: NotebookPlacement, depth: Int) {
        id = placement.item.id
        parentID = placement.parentID
        self.depth = depth
    }
}

#if os(iOS)
struct NotebookBrowserViewport: Equatable {
    let offset: CGFloat
    let bottomInset: CGFloat
    let size: CGSize
}

final class NotebookBrowserScrollReference {
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
#endif

/// Files, Recents, and their item actions.
extension NotebookSceneState {
    var activeNoteCount: Int {
        replica.placements.count { !$0.isInTrash && $0.item.kind == .note }
    }

    var recentPlacements: [NotebookPlacement] {
        navigationState.recentNoteIDs.compactMap { id in
            replica.placements.first { $0.item.id == id }
        }
    }

    var hasMoreRecents: Bool {
        replica.allRecentNotes.count > recentPlacements.count
    }

    #if os(macOS)
    var allRecentPlacements: [NotebookPlacement] {
        let placements = Dictionary(uniqueKeysWithValues:
            replica.placements.map { ($0.item.id, $0) })
        return replica.allRecentNotes.compactMap { placements[$0.id] }
    }
    #endif

    func recentPreview(for id: UUID) -> String {
        guard let recent = navigationState.recentSessions[id] else {
            return navigationState.recentPreviewText[id] ?? "Preview unavailable"
        }
        if workspace?.isResetPending == true { return "Restart to finish reset" }
        guard recent.isEditingEnabled else { return "Note unavailable" }
        let preview = NotebookRecentPreview.text(from: recent.text)
        return preview.isEmpty ? "Empty note" : preview
    }

    func setRecentPinned(_ pinned: Bool, for id: UUID) {
        Task { @MainActor in
            do {
                try await replica.setPinnedInRecents(pinned, for: id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func setRecentHidden(
        _ hidden: Bool, for id: UUID,
        onCompletion: @escaping (Bool) -> Void = { _ in }
    ) {
        perform({ [self] in
            try await replica.setHiddenFromRecents(hidden, for: id)
        }, onCompletion: onCompletion)
    }

    // MARK: Files

    var visibleActiveRows: [NotebookSidebarRow] {
        navigationState.isTreeExpanded ? flattenedRows(inTrash: false) : []
    }

    var activeBrowserIDs: Set<UUID> {
        Set(replica.placements.filter { !$0.isInTrash }.map(\.item.id))
    }

    var activeBrowserOrder: [UUID] {
        func descendants(_ parentID: UUID?) -> [UUID] {
            replica.orderedChildren(parentID: parentID).flatMap { placement in
                [placement.item.id] + (placement.item.kind == .folder
                    ? descendants(placement.item.id) : [])
            }
        }
        return descendants(nil)
    }

    var selectedBrowserIDs: [UUID] {
        browserSelection.orderedIDs(in: activeBrowserOrder)
    }

    var showsSelectionControls: Bool {
        selectingItems || browserSelection.count > 1
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

    func beginSelectingItems() {
        selectingItems = true
        navigationState.isTreeExpanded = true
        browserSelection.clear()
    }

    func endSelectingItems() {
        selectingItems = false
        browserSelection.clear()
    }

    func setNativeBrowserSelection(_ ids: Set<UUID>) {
        let hidden = browserSelection.selectedIDs.subtracting(visibleActiveRows.map(\.id))
        browserSelection.selectAll(Array(ids.union(hidden)))
    }

    func activateSidebarRow(_ placement: NotebookPlacement) {
        guard !busy, !showsSelectionControls,
              editingID != placement.item.id else { return }
        if placement.item.kind == .folder, editingID == nil {
            toggleFolder(placement.item.id)
            return
        }
        perform { [self] in
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

    func toggleFolder(_ id: UUID) {
        if expandedIDs.contains(id) {
            expandedIDs.remove(id)
        } else {
            expandedIDs.insert(id)
        }
    }

    #if os(iOS)
    func compactChanged(to compact: Bool) {
        // Unfolding iPhone Duo on Files shows the open note next to it,
        // so folding again keeps that note. Its link journey ended when
        // Files opened, so drop the old visits.
        guard !compact, preferredCompactColumn == .sidebar, selectedID != nil else { return }
        resetLinkJourney()
        preferredCompactColumn = .detail
    }
    #endif

    /// Leaving or reaching Files in one column ends the open note's visit.
    func preferredCompactColumnChanged(to column: NavigationSplitViewColumn,
                                       isCompact: Bool) {
        #if os(iOS)
        if isCompact {
            if column == .detail {
                browserReturnViewport = browserViewport
                browserToolbarWasHidden = false
            } else if column == .sidebar {
                restoreBrowserViewportIfReady()
            }
        }
        if isCompact, column == .sidebar {
            rememberEditorPosition()
            navigationState.recordClosed()
            linkJourneyID = UUID()
            linkHistory.clear()
            // Keep the outgoing screen's identity/content through the
            // Files transition. Direct selection starts a fresh journey.
        }
        #endif
        if isCompact, column == .sidebar, !selectingItems {
            browserSelection.clear()
        }
    }

    #if os(iOS)
    func browserViewportChanged(to viewport: NotebookBrowserViewport) {
        browserViewport = viewport
        // Rendering must depend only on size. Reading the full viewport
        // for the margin would rebuild the list on every scroll offset.
        if browserViewportHeight != viewport.size.height {
            browserViewportHeight = viewport.size.height
        }
        restoreBrowserViewportIfReady()
    }

    func browserScrollBegan() {
        browserReturnViewport = nil
        browserToolbarWasHidden = false
    }

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

    // MARK: Dragging

    func browserAfterEndID(in rows: [NotebookSidebarRow]) -> UUID? {
        guard let target = browserDrag.target, target.position == .after,
              let id = target.rowID,
              let start = rows.firstIndex(where: { $0.id == id })
        else { return nil }
        let depth = rows[start].depth
        return rows.dropFirst(start + 1).prefix { $0.depth > depth }.last?.id ?? id
    }

    func beginBrowserDrag(_ id: UUID) -> NSItemProvider {
        guard !busy, editingID == nil, !search.isPresented,
              let notebookID = replica.catalogSnapshot?.notebookID else {
            return NSItemProvider()
        }
        let ids = browserSelection.contains(id) && browserSelection.count > 1
            ? selectedBrowserIDs : [id]
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

    func browserDropInteraction() -> NotebookBrowserDropInteraction {
        NotebookBrowserDropInteraction(
            state: browserDrag,
            resolve: { [self] point in
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
            expand: { [self] id in
                if let id { expandedIDs.insert(id) }
                else { navigationState.isTreeExpanded = true }
            },
            commit: { [self] drag, target in
                guard !busy else {
                    errorMessage = String(localized:
                        "Another action is still finishing. Try moving the files again.")
                    return
                }
                perform { [self] in
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

    // MARK: Creating and renaming

    func contextualCreationPosition(
        for placement: NotebookPlacement
    ) -> NotebookCreationPosition {
        if placement.item.kind == .folder { return .first }
        #if os(iOS)
        return browserScrollView.creationPosition(relativeTo: placement.item.id)
        #else
        return .after(placement.item.id)
        #endif
    }

    func creationParent(for placement: NotebookPlacement) -> UUID? {
        placement.item.kind == .folder ? placement.item.id : placement.item.parentID
    }

    func createItem(
        kind: NotebookItemKind, parentID: UUID?,
        position: NotebookCreationPosition = .append,
        usesDefaultDestination: Bool = false, startsWriting: Bool = false
    ) {
        var createdFolderID: UUID?
        perform { [self] in
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
                if !startsWriting {
                    detailEditingID = id
                    detailOriginalName = name
                    detailProposedTitle = NotebookNoteName.title(from: name)
                    detailTitleHeight = 32
                    detailTitleFocusRequest = NotebookTitleFocusRequest(
                        noteID: id, selectsAll: true
                    )
                }
            case .folder:
                createdFolderID = try await replica.createFolder(
                    name: "Untitled Folder", parentID: parentID,
                    position: position)
            }
        } onSuccess: { [self] in
            if startsWriting {
                // This explicit visit owns focus, rather than the ordinary
                // position-restoration task that also waits for attachment.
                let incoming = editorNavigation
                let noteID = selectedID
                incoming.hasExplicitVisitDestination = true
                incoming.whenAttached { [weak self, weak incoming] in
                    guard let self, let incoming, incoming === editorNavigation,
                          selectedID == noteID else { return }
                    incoming.focusEditor?()
                }
            }
            guard let id = createdFolderID else { return }
            navigationState.isTreeExpanded = true
            reveal(id)
            beginRenaming(id: id, name: "Untitled Folder")
            fileRevealRequest = NotebookFileReveal(id: id, highlights: false)
        }
    }

    func createDefaultNote() {
        createItem(kind: .note, parentID: nil, usesDefaultDestination: true)
    }

    func startWriting() {
        createItem(kind: .note, parentID: nil,
                   usesDefaultDestination: true, startsWriting: true)
    }

    func setDefaultNewNoteParentID(_ id: UUID?) {
        perform { [self] in
            try await replica.setDefaultNewNoteParentID(id)
        }
    }

    func beginRenaming(_ placement: NotebookPlacement) {
        perform { [self] in
            try await flushEditor()
            reveal(placement.item.id)
            beginRenaming(id: placement.item.id, name: placement.item.name)
        }
    }

    private func beginRenaming(id: UUID, name: String) {
        if isCompact { preferredCompactColumn = .sidebar }
        editingID = id
        originalName = name
        proposedName = name
        #if os(iOS)
        Task { @MainActor in
            nameFocus?.wrappedValue = id
        }
        #endif
    }

    func submitInlineName() {
        perform { [self] in try await commitInlineNameIfNeeded() }
    }

    func commitInlineNameIfNeeded() async throws {
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
        nameFocus?.wrappedValue = nil
        originalName = ""
        proposedName = ""
        if placement?.item.kind == .note, selectedID == id {
            // Inline rename reopens this note without selecting it again.
            // Replace the retained Files-transition path before pushing it.
            if isCompact, preferredCompactColumn != .detail {
                resetLinkJourney()
            }
            preferredCompactColumn = .detail
        }
    }

    func cancelInlineName() {
        proposedName = originalName
        editingID = nil
        nameFocus?.wrappedValue = nil
        originalName = ""
    }

    // MARK: Trash and deletion

    func changeTrash(_ placement: NotebookPlacement, trashed: Bool) {
        if trashed {
            trashItems([placement.item.id])
            return
        }
        perform { [self] in
            try await flushEditor()
            try await replica.setTrashed(placement.item.id, trashed)
            reveal(placement.item.id)
        }
    }

    /// Swipe actions pass `crumplesOpenNote: false` to keep the list's own
    /// animation; everywhere else the open note crumples once it's trashed.
    func trashItems(
        _ ids: [UUID], crumplesOpenNote: Bool = true,
        onCompletion: @escaping (Bool) -> Void = { _ in }
    ) {
        let trashesOpenNote = crumplesOpenNote && containsOpenNote(ids)
        perform({ [self] in
            try await flushEditor()
            browserUndo = try await replica.trashItems(ids)
            if trashesOpenNote { trashedOpenNote += 1 }
            browserRedo = nil
            browserSelection.clear()
            selectingItems = false
        }, onCompletion: onCompletion)
    }

    /// Whether trashing `ids` takes the open note with it, directly or
    /// inside a folder.
    private func containsOpenNote(_ ids: [UUID]) -> Bool {
        guard let selectedID else { return false }
        let parents = Dictionary(uniqueKeysWithValues: replica.placements.map {
            ($0.item.id, $0.parentID)
        })
        var current: UUID? = selectedID
        while let id = current {
            if ids.contains(id) { return true }
            current = parents[id] ?? nil
        }
        return false
    }

    func trashDidChange() {
        browserUndo = nil
        browserRedo = nil
        if let selectedID,
           !replica.placements.contains(where: { $0.item.id == selectedID }) {
            navigationState.clearSelection()
            resetLinkJourney()
            unrecordedEdit = false
            preferredCompactColumn = .sidebar
        }
        workspace?.contentDidSave(trigger: "trash changed")
    }

    func openNoteFromTrash(_ id: UUID) {
        showingTrash = false
        perform { [self] in try await selectNote(id) }
    }

    func prepareDeletion(rootID: UUID?) {
        perform { [self] in
            try await flushEditor()
            deletionSelection = try replica.deletionSelection(rootID: rootID)
        }
    }

    func deletionMessage(_ selection: NotebookDeletionSelection) -> String {
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

    func deletePermanently(_ selection: NotebookDeletionSelection) {
        deletionSelection = nil
        perform { [self] in
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
                resetLinkJourney()
                unrecordedEdit = false
                preferredCompactColumn = .sidebar
            }
            expandedIDs.subtract(selection.ids)
            workspace?.contentDidSave(trigger: "permanent deletion")
        }
    }

    // MARK: Revealing

    func reveal(_ id: UUID) {
        var next = replica.placements.first { $0.item.id == id }
        while let parentID = next?.parentID {
            expandedIDs.insert(parentID)
            next = replica.placements.first { $0.item.id == parentID }
        }
    }

    func revealSelection() {
        navigationState.isTreeExpanded = true
        for id in browserSelection.selectedIDs { reveal(id) }
    }

    func showInFiles(_ id: UUID) {
        search.isPresented = false
        navigationState.isTreeExpanded = true
        reveal(id)
        if isCompact { preferredCompactColumn = .sidebar }
        fileRevealRequest = NotebookFileReveal(id: id)
    }

    func revealLinkedNoteInFiles(_ id: UUID) {
        navigationState.isTreeExpanded = true
        reveal(id)
        #if os(macOS)
        // Keep deliberate batch selections intact. Otherwise the native Files
        // selection should track the note reached through links or history.
        // On iOS a sidebar List selection resets the note column's stack,
        // which would discard the link visits.
        if !selectingItems, browserSelection.count <= 1 {
            browserSelection.selectOnly(id)
        }
        #endif
        fileRevealRequest = NotebookFileReveal(id: id, highlights: false)
    }

    // MARK: Moving and sorting

    func beginMoving(_ ids: [UUID], fromTrash: Bool = false) {
        guard !busy, !ids.isEmpty else { return }
        let sources = effectiveSelectionRoots(ids)
        let parents = Set(sources.map(\.parentID))
        destination = parents.count == 1 ? sources.first?.parentID : nil
        movingNotebookID = replica.catalogSnapshot?.notebookID
        movingFromTrash = fromTrash
        movingIDs = ids
    }

    func commitMove(to parentID: UUID?) async throws {
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

    func canMoveSelection(into parentID: UUID?) -> Bool {
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

    func undoBrowserChange(redo: Bool) {
        guard let receipt = redo ? browserRedo : browserUndo else { return }
        perform { [self] in
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

    func sort(_ parentID: UUID?, by order: NotebookSortOrder) {
        perform { [self] in
            try await flushEditor()
            try await replica.sortChildren(parentID: parentID, by: order)
        }
    }
}
