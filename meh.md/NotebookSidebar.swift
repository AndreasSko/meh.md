import Foundation
import NoteCore
import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// The sidebar: the library browser or search results, and their toolbar.
struct NotebookSidebar: View {
    @Bindable var scene: NotebookSceneState
    let focus: NotebookSceneFocus
    /// The window's size class. Inside the split view the sidebar column
    /// reports compact even on iPad.
    let isCompact: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    private var search: NotebookSearchState { scene.search }

    private var syncToolbarPlacement: ToolbarItemPlacement {
        #if os(macOS)
        .navigation
        #else
        .topBarLeading
        #endif
    }

    private var sidebarTitle: String {
        if showsTrash { return "Trash" }
        #if os(iOS)
        // The app name repeats the window identity and crowds a split sidebar.
        if !isCompact { return "" }
        #endif
        return "meh.md"
    }

    /// The iPad sidebar is too narrow for Select All, the count, Done and
    /// the sidebar button in one row, and iOS would hide Done under More.
    private var countsInBottomBar: Bool {
        #if os(iOS)
        !isCompact
        #else
        false
        #endif
    }

    private var showsTrash: Bool { scene.showingTrash && scene.showsTrashInSidebar }

    var body: some View {
            ZStack {
                Group {
                    if showsTrash {
                        NotebookTrashView(
                            replica: scene.replica,
                            beforeMutation: scene.flushEditor,
                            onMutation: scene.trashDidChange,
                            onOpenNote: scene.openNoteFromTrash,
                            onClose: { scene.showingTrash = false },
                            openNoteID: scene.selectedID,
                            afterMutation: { scene.editorNavigation.resumeEditing?() }
                        )
                    } else if isCompact && scene.isLibraryEmpty {
                        NotebookEmptyLibraryView(scene: scene)
                            .disabled(scene.busy)
                    } else {
                        NotebookLibraryBrowser(scene: scene, focus: focus, isCompact: isCompact)
                    }
                }
                    .opacity(search.isPresented ? 0 : 1)
                    .allowsHitTesting(!search.isPresented)
                    .accessibilityHidden(search.isPresented)
                if search.isPresented {
                    NotebookSearchResults(
                        results: search.results, query: search.query,
                        isPreparing: search.isPreparing,
                        unavailableCount: search.unavailableCount, error: search.error,
                        selection: Bindable(search).selectedResultID,
                        open: { scene.openSearchResult($0, query: search.resultQuery) }
                    )
                }
            }
            .background(NotebookSidebarPalette.background.ignoresSafeArea())
            #if os(iOS)
            .overlay(alignment: .trailing) {
                if !isCompact { NotebookSidebarDivider() }
            }
            #endif
            // Search covers notes outside Trash, so it steps aside there.
            .modifier(NotebookSidebarSearch(search: search, focus: focus.search,
                                            isEnabled: !showsTrash))
            #if os(macOS)
            .scrollIndicators(.automatic)
            #endif
            .overlay(alignment: .bottom) {
                if isCompact { NotebookTrashUndoBar(scene: scene) }
            }
            .overlay(alignment: .bottom) {
                if !isCompact && !search.isPresented && !scene.showsSelectionControls
                    && !scene.browsingAllRecents && !showsTrash {
                    NotebookSidebarControls(
                        busy: scene.busy,
                        showSettings: { scene.openSettings() },
                        showTrash: { scene.openTrash() }
                    )
                    // Stay at the bottom under the keyboard instead of
                    // floating over the Files rows while typing.
                    .ignoresSafeArea(.keyboard, edges: .bottom)
                }
            }
            .navigationTitle(sidebarTitle)
            #if os(iOS)
            // The split sidebar has no title. A large mode there leaves an
            // empty title row once search ends, pushing the field down.
            .navigationBarTitleDisplayMode(isCompact ? .large : .inline)
            #endif
            #if os(iOS)
            // Frees room for Done next to Deselect All. Applied after the
            // column width, it hides that width and the sidebar grows to 320.
            .toolbar(removing: countsInBottomBar && scene.showsSelectionControls
                     ? .sidebarToggle : nil)
            #endif
            .navigationSplitViewColumnWidth(min: 220, ideal: 280)
            .toolbar {
                #if os(iOS)
                if !sidebarTitle.isEmpty {
                    ToolbarItem(placement: .largeTitle) { MehTitle() }
                }
                #endif
                if !scene.showingTrash {
                    if let workspace = scene.workspace, !scene.showsSelectionControls {
                        ToolbarItem(placement: syncToolbarPlacement) {
                            NotebookSyncButton(
                                workspace: workspace,
                                showingDetails: $scene.showingSyncDetails,
                                openSettings: { scene.openSettings(.syncBackups) }
                            )
                        }
                    }
                    if scene.showsSelectionControls && !search.isPresented {
                        ToolbarItem(placement: .cancellationAction) { selectAllButton }
                        if !countsInBottomBar {
                            ToolbarItem(placement: .principal) { selectionCount }
                        }
                        ToolbarItem(placement: .confirmationAction) { selectionDone }
                        #if os(iOS)
                        ToolbarItem(placement: .bottomBar) { moveSelectedButton }
                        ToolbarSpacer(.flexible, placement: .bottomBar)
                        if countsInBottomBar {
                            ToolbarItem(placement: .bottomBar) { selectionCount }
                            ToolbarSpacer(.flexible, placement: .bottomBar)
                        }
                        ToolbarItem(placement: .bottomBar) { trashSelectedButton }
                        #else
                        ToolbarItemGroup {
                            moveSelectedButton
                            trashSelectedButton
                        }
                        #endif
                    } else {
                        ToolbarItem(placement: .primaryAction) { applicationMenu }
                        if isCompact {
                            #if os(iOS)
                            DefaultToolbarItem(kind: .search, placement: .bottomBar)
                            if !search.isPresented {
                                ToolbarSpacer(.fixed, placement: .bottomBar)
                                ToolbarItem(placement: .bottomBar) {
                                    NotebookLibraryNewNote(scene: scene)
                                }
                                    .sharedBackgroundVisibility(.hidden)
                            }
                            #endif
                        } else {
                            ToolbarItem { NotebookLibraryNewNote(scene: scene) }
                                #if os(iOS)
                                .sharedBackgroundVisibility(.hidden)
                                #endif
                        }
                    }
                }
            }
    }

    private var moveSelectedButton: some View {
        Button {
            scene.beginMoving(scene.selectedBrowserIDs)
        } label: {
            Image(systemName: "arrow.forward.folder")
        }
        .accessibilityLabel("Move")
        .help("Move selected items")
        .accessibilityIdentifier("notebook-move-selected")
        .disabled(scene.busy || scene.browserSelection.isEmpty)
    }

    private var trashSelectedButton: some View {
        Button(role: .destructive) {
            scene.trashItems(scene.selectedBrowserIDs)
        } label: {
            Label("Trash", systemImage: "trash")
        }
        .labelStyle(.titleAndIcon)
        .accessibilityIdentifier("notebook-trash-selected")
        .disabled(scene.busy || scene.browserSelection.isEmpty)
    }

    private var selectAllButton: some View {
        let visible = Set(scene.visibleActiveRows.map(\.id))
        let allSelected = !visible.isEmpty
            && visible.isSubset(of: scene.browserSelection.selectedIDs)
        return Button(allSelected ? "Deselect All" : "Select All") {
            if allSelected { scene.browserSelection.clear() }
            else { scene.browserSelection.selectAll(Array(visible)) }
        }
        .accessibilityIdentifier("notebook-select-all")
        .disabled(scene.busy)
    }

    private var selectionCount: some View {
        Button {
            scene.revealSelection()
        } label: {
            Text("\(scene.browserSelection.count) selected")
                .font(.headline)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("notebook-selection-count")
        .accessibilityHint("Reveals selected items in collapsed folders")
        .help("Reveal selected items")
        .disabled(scene.busy || scene.browserSelection.isEmpty)
    }

    private var selectionDone: some View {
        Button("Done") {
            scene.endSelectingItems()
        }
        #if os(iOS)
        // Command-clicks on iPad don't move keyboard focus into the list,
        // so Escape can't rely on the browser's key handler there.
        .keyboardShortcut(.cancelAction)
        #endif
        .accessibilityIdentifier("notebook-selection-done")
        .disabled(scene.busy)
    }

    @ViewBuilder
    private var browserUndoActions: some View {
        if scene.browserUndo?.action == .move {
            Button("Undo Move", systemImage: "arrow.uturn.backward") {
                scene.undoBrowserChange(redo: false)
            }
                .accessibilityIdentifier("notebook-browser-undo")
        }
        if scene.browserRedo?.action == .move {
            Button("Redo Move", systemImage: "arrow.uturn.forward") {
                scene.undoBrowserChange(redo: true)
            }
                .accessibilityIdentifier("notebook-browser-redo")
        }
    }

    private var applicationMenu: some View {
        Menu {
            Button {
                scene.createItem(kind: .folder, parentID: nil)
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            NotebookTemplateCreationButton(scene: scene)
            Divider()
            Button("Select Items", systemImage: "checkmark.circle") {
                scene.beginSelectingItems()
            }
            .accessibilityIdentifier("notebook-select-items")
            NotebookSortMenu(scene: scene, parentID: nil)
                .accessibilityIdentifier("notebook-sort-root")
            Button { scene.requestImport() } label: {
                Label("Import Markdown…", systemImage: "square.and.arrow.down")
            }
            .accessibilityIdentifier("notebook-import-browser")
            Divider()
            browserUndoActions
            // Window management comes after the everyday notebook actions.
            if supportsMultipleWindows {
                Divider()
                Button("New Window", systemImage: "macwindow.badge.plus") {
                    openWindow(id: "notebook", value: NotebookWindowValue())
                }
            }
            if isCompact {
                Button { scene.openSettings() } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .accessibilityIdentifier("notebook-settings")
                Button { scene.openTrash() } label: {
                    Label("Trash", systemImage: "trash")
                }
                .accessibilityIdentifier("notebook-trash-toggle")
            }
        } label: {
            Label("Browser Actions", systemImage: "ellipsis")
        }
        .disabled(scene.busy)
        .accessibilityIdentifier("notebook-app-menu")
    }
}

/// Recents and Files.
private struct NotebookLibraryBrowser: View {
    let scene: NotebookSceneState
    let focus: NotebookSceneFocus
    let isCompact: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.mehPalette) private var palette
    @State private var notice: NotebookNoticeRequest?
    @State private var frame: CGRect = .zero
    @AppStorage(NotebookNavigationState.filePreviewsKey, store: NotebookEditorPreferences.store)
    private var showsFilePreviews = false

    private var showsCurrentNote: Bool { !isCompact }

    private var sidebarSectionInsets: EdgeInsets { NotebookFileRow.sectionInsets }

    private var recentSectionInsets: EdgeInsets {
        #if os(macOS)
        EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        #else
        sidebarSectionInsets
        #endif
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            #if os(iOS)
            NotebookRecentsExpansionHost(
                items: allRecentUIKitItems,
                compactCount: scene.recentPlacements.count,
                isExpanded: Bindable(scene).browsingAllRecents,
                rowContent: { id, index, count in
                    if let placement = scene.replica.placements.first(where: { $0.item.id == id }) {
                        recentRow(placement, index: index, count: count)
                    }
                },
                onTogglePin: { id in
                    scene.setRecentPinned(!scene.replica.isPinnedInRecents(id), for: id)
                },
                onTrash: { id, completion in
                    scene.trashItems([id], onCompletion: completion)
                },
                onHide: { id, completion in
                    scene.setRecentHidden(true, for: id, onCompletion: completion)
                },
                contextMenu: recentUIKitMenu,
                onVisibleIDs: { scene.visibleRecentPreviewIDs = $0 },
                browser: { hidesCompactRows in
                    libraryList(scrollProxy: scrollProxy, hidesCompactRows: hidesCompactRows)
                }
            )
            #else
            NotebookMacRecentsExpansionHost(
                items: scene.allRecentPlacements,
                compactCount: scene.navigationState.recentNoteIDs.count,
                selectedNoteID: scene.selectedID,
                isExpanded: Bindable(scene).browsingAllRecents,
                onSelect: { id in scene.openFromRecents(id) },
                onCollapse: collapseMacRecents,
                onVisibleIDs: { scene.visibleRecentPreviewIDs = $0 },
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
        // Presented from here, outside the List: inside a row on macOS, the
        // popover's buttons don't receive clicks. Rows are hosted apart on
        // macOS, so the mark's frame comes in window coordinates.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .popover(
            item: $notice,
            attachmentAnchor: .rect(.rect(notice?.rect ?? .zero))
        ) { request in
            NotebookNoticePopover(
                scene: scene, itemID: request.id,
                picked: Binding(get: { notice?.picked }, set: { notice?.picked = $0 }),
                dismiss: { notice = nil })
        }
        #if os(macOS)
        .onChange(of: scene.recentCommands.browseAllRequest) { _, _ in
            if scene.browsingAllRecents {
                collapseMacRecents()
            } else if scene.hasMoreRecents {
                scene.browsingAllRecents = true
            }
        }
        #endif
    }

    private func recentRow(
        _ placement: NotebookPlacement, index: Int, count: Int,
        showsCardBackground: Bool = true
    ) -> NotebookRecentNoteRow {
        NotebookRecentNoteRow(
            scene: scene, placement: placement, index: index, count: count,
            showsCardBackground: showsCardBackground, showsCurrentNote: showsCurrentNote,
            focusedRecentID: focus.recent
        )
    }

    #if os(iOS)
    private var allRecentUIKitItems: [NotebookRecentUIKitItem] {
        let placements = Dictionary(uniqueKeysWithValues:
            scene.replica.placements.map { ($0.item.id, $0) })
        return scene.replica.allRecentNotes.compactMap { recent in
            guard let placement = placements[recent.id] else { return nil }
            return NotebookRecentUIKitItem(
                id: recent.id,
                title: NotebookNoteName.title(from: placement.displayName),
                preview: scene.recentPreview(for: recent.id),
                isCurrent: showsCurrentNote && scene.selectedID == recent.id,
                isPinned: recent.isPinned,
                // The full projection already excludes unavailable notes.
                canPin: scene.replica.canPinInRecents
            )
        }
    }

    private func recentUIKitMenu(for id: UUID) -> UIMenu {
        let replica = scene.replica
        guard let placement = replica.placements.first(where: { $0.item.id == id })
        else { return UIMenu(children: []) }
        var menuActions: [UIMenuElement] = []
        if supportsMultipleWindows {
            menuActions.append(UIMenu(options: .displayInline, children: [
                UIAction(
                    title: String(localized: "Open in New Window"),
                    image: UIImage(systemName: "macwindow.badge.plus")
                ) { _ in
                    openWindow(id: "notebook", value: NotebookWindowValue(noteID: id))
                }
            ]))
        }
        let pinned = replica.isPinnedInRecents(id)
        menuActions.append(UIAction(
            title: pinned ? String(localized: "Unpin from Recents")
                : String(localized: "Pin in Recents"),
            image: UIImage(systemName: pinned ? "pin.slash" : "pin"),
            attributes: !pinned && !replica.canPinInRecents(id) ? .disabled : []
        ) { _ in
            scene.setRecentPinned(!pinned, for: id)
        })
        menuActions.append(UIAction(
            title: String(localized: "Rename…"), image: UIImage(systemName: "pencil")
        ) { _ in
            scene.beginRenaming(placement)
        })
        menuActions.append(UIAction(
            title: String(localized: "Move…"), image: UIImage(systemName: "folder")
        ) { _ in
            scene.beginMoving([id], fromTrash: false)
        })
        menuActions.append(UIAction(
            title: String(localized: "Show in Files"),
            image: UIImage(systemName: "list.bullet.indent")
        ) { _ in
            scene.showInFiles(id)
        })
        var reusableActions: [UIMenuElement] = []
        reusableActions.append(UIAction(
            title: replica.isTemplateSource(id)
                ? String(localized: "Stop Using as Template")
                : String(localized: "Use as Template"),
            image: UIImage(systemName: "doc.on.doc"),
            attributes: scene.busy ? .disabled : []
        ) { _ in
            scene.setTemplateSource(id, enabled: !replica.isTemplateSource(id))
        })
        reusableActions.append(UIAction(
            title: replica.isSnippetSource(id)
                ? String(localized: "Stop Using as Snippet")
                : String(localized: "Use as Snippet"),
            image: UIImage(systemName: "text.badge.plus"),
            attributes: scene.busy ? .disabled : []
        ) { _ in
            scene.setSnippetSource(id, enabled: !replica.isSnippetSource(id))
        })
        menuActions.append(UIMenu(
            title: String(localized: "Templates & Snippets"),
            image: UIImage(systemName: "doc.on.doc"),
            children: reusableActions
        ))
        menuActions.append(UIAction(
            title: String(localized: "Hide from Recents"),
            image: UIImage(systemName: "eye.slash"),
            attributes: scene.busy ? .disabled : []
        ) { _ in
            scene.setRecentHidden(true, for: id)
        })
        menuActions.append(UIMenu(options: .displayInline, children: [
            UIAction(
                title: String(localized: "Move to Trash"),
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { _ in
                scene.changeTrash(placement, trashed: true)
            }
        ]))
        return UIMenu(children: menuActions)
    }
    #endif

    #if os(macOS)
    private func collapseMacRecents() {
        scene.browsingAllRecents = false
        if scene.navigationState.isRecentsExpanded && scene.hasMoreRecents {
            focus.recentsMore.wrappedValue = true
        } else {
            focus.recentsHeader.wrappedValue = true
        }
    }
    #endif

    private func recentsSection(hidesCompactRows: Bool) -> some View {
        let navigationState = scene.navigationState
        let recentPlacements = scene.recentPlacements
        return Section {
            #if os(macOS)
            NotebookMacRecentsCompactHeader(
                isExpanded: navigationState.isRecentsExpanded
            ) { navigationState.isRecentsExpanded.toggle() }
            .focused(focus.recentsHeader)
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
                                scene.setRecentPinned(!scene.replica.isPinnedInRecents(id),
                                                      for: id)
                            },
                            onTrash: { id, completion in
                                scene.trashItems([id], onCompletion: completion)
                            },
                            onHide: { id, completion in
                                scene.setRecentHidden(true, for: id, onCompletion: completion)
                            },
                            contextMenu: recentUIKitMenu,
                            accessibilityHidden: hidesCompactRows
                        )
                        if scene.replica.allRecentNotes.count > recentPlacements.count {
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
                    let hasMoreRecents = scene.hasMoreRecents
                    ForEach(Array(recentPlacements.enumerated()), id: \.element.item.id) {
                        index, placement in
                        recentRow(placement, index: index + 1,
                                  count: recentPlacements.count + 1 + (hasMoreRecents ? 1 : 0))
                            .anchorPreference(key: NotebookMacRecentsAnchorKey.self,
                                              value: .bounds) { [$0] }
                    }
                    if hasMoreRecents {
                        Button {
                            scene.browsingAllRecents = true
                        } label: {
                            Label("More", systemImage: "chevron.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focused(focus.recentsMore)
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

    private var activeTree: some View {
        let rows = scene.visibleActiveRows
        let target = scene.browserDrag.target
        let targetDepth = rows.first { $0.id == target?.rowID }?.depth ?? 0
        let afterEndID = scene.browserAfterEndID(in: rows)
        return ForEach(NotebookSidebarEntry.entries(
            rows: rows, placements: scene.replica.placements, expandedIDs: scene.expandedIDs
        )) { entry in
            switch entry {
            case .row(let row):
                NotebookFileRow(scene: scene, row: row, afterEndID: afterEndID,
                                targetDepth: targetDepth, showsPreview: showsFilePreviews,
                                focusedNameID: focus.name,
                                openNotice: { markFrame in
                                    notice = NotebookNoticeRequest(
                                        id: row.id,
                                        rect: markFrame.offsetBy(dx: -frame.minX, dy: -frame.minY))
                                })
                    .tag(row.id)
                    .id(row.id)
                    .listRowSeparator(.hidden)
                    .modifier(NotebookFileRowBackground(
                        color: rowBackground(for: row.id),
                        insetHighlight: insetRowHighlight(for: row.id)
                    ))
                    .listRowInsets(sidebarSectionInsets)
            case .ghost(let placement, let parentID, let depth):
                NotebookGhostRow(scene: scene, placement: placement, parentID: parentID, depth: depth)
                    .selectionDisabled()
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(sidebarSectionInsets)
            }
        }
    }

    /// A custom background also hides the native selected fill.
    private func rowBackground(for id: UUID) -> Color? {
        switch scene.browserSelection.highlight(of: id, openNoteID: scene.selectedID) {
        case .selected: return nil
        // While picking items, gray would read as a selection the circle denies.
        case .open: return scene.selectingItems ? .clear : NotebookSidebarPalette.openNote
        case .none: return .clear
        }
    }

    /// The iPad sidebar paints every row, selected or not, as one rounded
    /// fill. A row that drops its custom background for the native fill
    /// would keep showing the first custom background it gets back.
    private func insetRowHighlight(for id: UUID) -> Color? {
        #if os(iOS)
        guard !isCompact else { return nil }
        switch scene.browserSelection.highlight(of: id, openNoteID: scene.selectedID) {
        // The sidebar's native selected fill is the tint.
        case .selected: return palette.accentColor ?? .accentColor
        case .open: return scene.selectingItems ? .clear : NotebookSidebarPalette.openNote
        case .none: return .clear
        }
        #else
        return nil
        #endif
    }

    @ViewBuilder
    private func browserRowActions(for placement: NotebookPlacement) -> some View {
        if scene.browserSelection.contains(placement.item.id), scene.browserSelection.count > 1 {
            Button("Move Selected…") {
                scene.beginMoving(scene.selectedBrowserIDs)
            }
            Button("Trash Selected", role: .destructive) {
                scene.trashItems(scene.selectedBrowserIDs)
            }
        } else {
            NotebookItemActions(scene: scene, placement: placement)
        }
    }

    private func libraryList(
        scrollProxy: ScrollViewProxy, hidesCompactRows: Bool
    ) -> some View {
        List(selection: Binding(
            get: { scene.browserSelection.selectedIDs },
            set: { scene.setNativeBrowserSelection($0) }
        )) {
            recentsSection(hidesCompactRows: hidesCompactRows)
            Section {
                if scene.navigationState.isTreeExpanded {
                    activeTree
                        .opacity(hidesCompactRows ? 0 : 1)
                        .accessibilityHidden(hidesCompactRows)
                    NotebookLibraryFooter(noteCount: scene.activeNoteCount) {
                        scene.browserDrag.faceFrame = $0
                    }
                        .opacity(hidesCompactRows ? 0 : 1)
                        .accessibilityHidden(hidesCompactRows)
                        .onDisappear { scene.browserDrag.faceFrame = .zero }
                        #if os(iOS)
                        // The empty-space tap only sees touches between
                        // rows, and the footer is a row. The face keeps its
                        // own tap.
                        .contentShape(Rectangle())
                        .onTapGesture { scene.clickBrowserEmptySpace() }
                        #endif
                        .contextMenu {
                            if scene.editingID == nil {
                                NotebookEmptySpaceActions(scene: scene)
                            }
                        }
                        // Row modifiers inside the wrappers above don't
                        // reach the List, which then draws a separator.
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .selectionDisabled()
                }
            } header: {
                NotebookSectionToggle(
                    title: "Files",
                    isExpanded: scene.navigationState.isTreeExpanded,
                    identifier: "notebook-tree-toggle"
                ) { scene.navigationState.isTreeExpanded.toggle() }
                .opacity(hidesCompactRows ? 0 : 1)
                .accessibilityHidden(hidesCompactRows)
                .textCase(nil)
                .listRowInsets(sidebarSectionInsets)
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .global)
                } action: { scene.browserDrag.filesHeaderFrame = $0 }
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(
                            scene.browserDrag.target?.position == .root ? 0.16 : 0
                        ))
                }
                #if os(iOS)
                .background(NotebookBrowserScrollReader(reference: scene.browserScrollView))
                .background(NotebookBrowserUIKitDropReader(
                    interaction: scene.browserDropInteraction(),
                    tapEmptySpace: scene.clickBrowserEmptySpace(at:)
                ))
                #else
                .background(NotebookBrowserAppKitScrollReader(state: scene.browserDrag))
                #endif
            }
            #if os(macOS)
            // Keep clearance in the list's actual content so AppKit can
            // scroll the last row above the floating controls.
            Color.clear
                .frame(height: 96)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .selectionDisabled()
                // The List offers no menu on a row without a tag, and on
                // the Mac this row is the empty space below the footer.
                .contentShape(Rectangle())
                .contextMenu {
                    if scene.editingID == nil {
                        NotebookEmptySpaceActions(scene: scene)
                    }
                }
                .accessibilityHidden(true)
            #endif
        }
        .listStyle(.plain)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            scene.browserDropViewportFrame = frame
        }
        #if os(macOS)
        .overlay(NotebookBrowserAppKitDragReader(
            state: scene.browserDrag,
            canBegin: {
                !scene.busy && scene.editingID == nil && !scene.search.isPresented
                    && scene.replica.catalogSnapshot?.notebookID != nil
            },
            sourceAt: { point in
                guard scene.browserDropViewportFrame.contains(point) else { return nil }
                return scene.visibleActiveRows.first { row in
                    scene.browserDrag.rowFrame(for: row.id)?.contains(point) == true
                }?.id
            },
            selectSource: { id in
                if !scene.browserSelection.contains(id) { scene.browserSelection.selectOnly(id) }
                focus.browser.wrappedValue = true
            },
            begin: scene.beginBrowserDrag,
            clickEmptySpace: scene.clickBrowserEmptySpace(at:)
        ))
        .overlay(NotebookBrowserAppKitDropSurface(interaction: scene.browserDropInteraction()))
        #endif
        #if os(iOS)
        // Keep a small buffer above the floating controls, including in
        // shorter windows, without leaving half the browser empty.
        .contentMargins(.bottom, max(96, scene.browserViewportHeight / 5),
                        for: .scrollContent)
        .listSectionSpacing(12)
        .listSectionMargins(.top, 8)
        .listSectionMargins(.bottom, 0)
        .onScrollGeometryChange(for: NotebookBrowserViewport.self) { geometry in
            NotebookBrowserViewport(offset: geometry.contentOffset.y,
                                    bottomInset: geometry.contentInsets.bottom,
                                    size: geometry.containerSize)
        } action: { _, viewport in
            scene.browserViewportChanged(to: viewport)
        }
        .onScrollPhaseChange { _, phase in
            // Includes scroll-to-top from the status bar, which never pans.
            // An offscreen list scrolling under an open note doesn't count.
            if phase != .idle, scene.preferredCompactColumn == .sidebar {
                scene.browserScrollBegan()
            }
        }
        #endif
        .scrollContentBackground(.hidden)
        .background(NotebookSidebarPalette.background)
        // The hard edge effect lays a white strip under the bottom bar,
        // which shows on paper once the list can scroll.
        .scrollEdgeEffectStyle(.soft, for: .all)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if scene.editingID == nil {
                if ids.count == 1, let id = ids.first,
                   let placement = scene.replica.placements.first(where: { $0.item.id == id }) {
                    browserRowActions(for: placement)
                } else if !ids.isEmpty {
                    Button("Move Selected…") {
                        scene.beginMoving(scene.selectedBrowserIDs)
                    }
                    Button("Trash Selected", role: .destructive) {
                        scene.trashItems(scene.selectedBrowserIDs)
                    }
                } else {
                    NotebookEmptySpaceActions(scene: scene)
                }
            }
        } primaryAction: { ids in
            guard ids.count == 1, let id = ids.first,
                  let placement = scene.replica.placements.first(where: { $0.item.id == id })
            else { return }
            scene.activateSidebarRow(placement)
        }
        .focused(focus.browser)
        #if os(iOS)
        .onDragSessionUpdated { session in
            switch session.phase {
            case .initial, .active: scene.browserDrag.isSessionActive = true
            case .ended, .dataTransferCompleted: scene.browserDrag.reset()
            default: break
            }
        }
        #endif
        .onKeyPress { press in handleKeyPress(press) }
        #if os(iOS)
        .onChange(of: isCompact) { _, compact in scene.compactChanged(to: compact) }
        #endif
        .onChange(of: scene.preferredCompactColumn) { _, column in
            scene.preferredCompactColumnChanged(to: column, isCompact: isCompact)
        }
        .task(id: scene.fileRevealRequest) {
            guard let request = scene.fileRevealRequest else { return }
            #if os(iOS)
            // The List drops a scroll to rows it inserts in the same update,
            // such as the children of folders the reveal just expanded.
            await NotebookNextFrame.wait()
            // A new inline editor replaces the row's drag source. Allow
            // that layout to finish before revealing a virtualized row.
            if scene.editingID == request.id {
                try? await Task.sleep(for: .milliseconds(100))
            }
            #else
            await Task.yield()
            #endif
            guard !Task.isCancelled else { return }
            withAnimation { scrollProxy.scrollTo(request.id, anchor: .center) }
            guard request.highlights else {
                scene.fileRevealRequest = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) {
                scene.highlightedFileID = request.id
            }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.4)) {
                scene.highlightedFileID = nil
            }
            scene.fileRevealRequest = nil
        }
        #if os(iOS)
        .environment(\.editMode, Binding(
            get: { scene.selectingItems ? .active : .inactive },
            set: { scene.selectingItems = $0.isEditing }
        ))
        #endif
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        #if os(iOS)
        scene.browserScrollView.discardClick()
        #endif
        guard focus.browser.wrappedValue, scene.editingID == nil, scene.detailEditingID == nil,
              !scene.search.isPresented, !scene.busy else { return .ignored }
        let selection = scene.browserSelection
        if press.modifiers.contains(.command), press.characters == "a" {
            scene.browserSelection.selectAll(scene.visibleActiveRows.map(\.id))
            return .handled
        }
        if press.modifiers.contains([.command, .shift]),
           press.characters.lowercased() == "m", !selection.isEmpty {
            scene.beginMoving(scene.selectedBrowserIDs)
            return .handled
        }
        if press.key == .delete, press.modifiers.contains(.command),
           !selection.isEmpty {
            scene.trashItems(scene.selectedBrowserIDs)
            return .handled
        }
        if press.key == .escape, scene.showsSelectionControls {
            scene.endSelectingItems()
            return .handled
        }
        if press.key == .return, selection.count == 1,
           let id = selection.selectedIDs.first,
           let placement = scene.replica.placements.first(where: { $0.item.id == id }) {
            scene.activateSidebarRow(placement)
            return .handled
        }
        return .ignored
    }
}

/// A note in Recents.
private struct NotebookRecentNoteRow: View {
    let scene: NotebookSceneState
    let placement: NotebookPlacement
    let index: Int
    let count: Int
    let showsCardBackground: Bool
    let showsCurrentNote: Bool
    var focusedRecentID: FocusState<UUID?>.Binding

    private var cardPosition: NotebookRecentCardPosition {
        if count == 1 { return .only }
        if index == 0 { return .first }
        return index == count - 1 ? .last : .middle
    }

    var body: some View {
        let id = placement.item.id
        let replica = scene.replica
        let isCurrent = showsCurrentNote && scene.selectedID == id
        let row = Button {
            scene.openFromRecents(id)
        } label: {
            NotebookRecentRow(
                title: NotebookNoteName.title(from: placement.displayName),
                preview: scene.recentPreview(for: id),
                isPinned: replica.isPinnedInRecents(id),
                isCurrent: isCurrent,
                showsDivider: index < count - 1
            )
        }
        .buttonStyle(.plain)
        .focused(focusedRecentID, equals: id)
        .accessibilityIdentifier("notebook-recent-" + id.uuidString)
        .accessibilityValue(
            [replica.isPinnedInRecents(id) ? String(localized: "Pinned") : nil,
             isCurrent ? String(localized: "Current note") : nil]
                .compactMap { $0 }.joined(separator: ", ")
        )
        .notebookRecentPinAccessibilityAction(
            isPinned: replica.isPinnedInRecents(id),
            isAvailable: replica.canPinInRecents(id)
        ) {
            scene.setRecentPinned(!replica.isPinnedInRecents(id), for: id)
        }
        .accessibilityAction(named: Text("Move to Trash")) {
            scene.trashItems([id])
        }
        .accessibilityAction(named: Text("Hide from Recents")) {
            scene.setRecentHidden(true, for: id)
        }
        .background(NotebookRecentCardBackground(
            position: cardPosition
        ).opacity(showsCardBackground ? 1 : 0))

        #if os(iOS)
        row
        #else
        row
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if replica.isPinnedInRecents(id) || replica.canPinInRecents(id) {
                NotebookRecentPinButton(scene: scene, id: id, swipeIcon: true)
                    .tint(replica.isPinnedInRecents(id) ? .gray : .orange)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                scene.trashItems([id])
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("Move to Trash")
            .accessibilityIdentifier("notebook-recent-swipe-trash")
            Button {
                scene.setRecentHidden(true, for: id)
            } label: {
                Image(systemName: "eye.slash")
            }
            .tint(.gray)
            .accessibilityLabel("Hide from Recents")
            .accessibilityIdentifier("notebook-recent-swipe-hide")
        }
        .contextMenu {
            NotebookItemActions(scene: scene, placement: placement, allowsCreation: false,
                                allowsShowInFiles: true)
        }
        #endif
    }
}

/// A note or folder in Files.
private struct NotebookFileRow: View {
    let scene: NotebookSceneState
    let row: NotebookSidebarRow
    let afterEndID: UUID?
    let targetDepth: Int
    /// A second line with the note's first words.
    let showsPreview: Bool
    var focusedNameID: FocusState<UUID?>.Binding
    let openNotice: (CGRect) -> Void

    static var sectionInsets: EdgeInsets {
        #if os(macOS)
        // AppKit already supplies the outer list margin. Keep room for the
        // disclosure control without adding the touch layout's extra inset.
        EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        #else
        EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20)
        #endif
    }

    private var rowHeight: CGFloat {
        #if os(macOS)
            28
        #else
            44
        #endif
    }

    private var disclosureWidth: CGFloat {
        #if os(macOS)
        12
        #else
        20
        #endif
    }

    private var disclosureSpacing: CGFloat {
        #if os(macOS)
        0
        #else
        6
        #endif
    }

    var body: some View {
        let drag = scene.browserDrag
        content
            .notebookDragSource(enabled: scene.editingID == nil) {
                scene.beginBrowserDrag(row.id)
            }
            .notebookBrowserRowGeometry(itemID: row.id, state: drag)
            .overlay(alignment: .top) {
                if drag.target?.position == .before,
                   drag.target?.rowID == row.id {
                    insertionLine(depth: row.depth)
                }
            }
            .overlay(alignment: .bottom) {
                if afterEndID == row.id {
                    insertionLine(depth: targetDepth)
                }
            }
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(
                        drag.target?.rowID == row.id
                            && drag.target?.position == .into ? 0.16 : 0
                    ))
            }
    }

    private func insertionLine(depth: Int) -> some View {
        Rectangle().fill(Color.accentColor).frame(height: 2)
            .padding(.leading, CGFloat(depth) * 16 + 20)
            .allowsHitTesting(false)
    }

    private func disclosureIcon(expanded: Bool) -> some View {
        Image(systemName: expanded ? "chevron.down" : "chevron.right")
            .font(.caption)
            .frame(width: 10)
            .foregroundStyle(Color.secondary)
    }

    private var nameField: some View {
        #if os(macOS)
        NotebookInlineNameField(text: Bindable(scene).proposedName, isEnabled: !scene.busy)
        #else
        TextField("Name", text: Bindable(scene).proposedName)
            .focused(focusedNameID, equals: row.id)
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if let placement = scene.replica.placements.first(where: { $0.item.id == row.id }) {
            let isExpanded = scene.expandedIDs.contains(row.id)
            HStack(spacing: disclosureSpacing) {
                if placement.item.kind == .folder {
                    #if os(macOS)
                    NotebookNativeDisclosureButton(
                        isExpanded: isExpanded,
                        label: placement.displayName,
                        identifier: "notebook-disclosure-" + row.id.uuidString,
                        action: { scene.toggleFolder(row.id) }
                    )
                    .frame(width: disclosureWidth, height: rowHeight)
                    #else
                    Button { scene.toggleFolder(row.id) } label: {
                        disclosureIcon(expanded: isExpanded)
                            .frame(minWidth: 20, minHeight: rowHeight)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(placement.displayName)
                    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                    .accessibilityIdentifier("notebook-disclosure-" + row.id.uuidString)
                    #endif
                } else {
                    Color.clear.frame(width: disclosureWidth, height: 1)
                }
                if scene.editingID == row.id {
                    nameField
                        .textFieldStyle(.plain)
                        .accessibilityIdentifier("notebook-inline-name")
                        .disabled(scene.busy)
                        .onSubmit { scene.submitInlineName() }
                        .notebookEscapeAction { scene.cancelInlineName() }
                        .notebookSelectNameOnFocus()
                } else {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(placement.item.kind == .note
                                ? NotebookNoteName.title(from: placement.displayName)
                                : placement.displayName)
                                .accessibilityIdentifier("notebook-sidebar-title-" + row.id.uuidString)
                            if showsPreview, placement.item.kind == .note {
                                // A blank line keeps the row's height while it loads.
                                Text(scene.filePreview(for: row.id) ?? " ")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier(
                                        "notebook-sidebar-preview-" + row.id.uuidString)
                            }
                        }
                    } icon: {
                        if placement.item.kind == .folder {
                            NotebookFolderIcon(
                                systemName: scene.replica.defaultNewNoteParentID == row.id
                                    ? "tray" : "folder"
                            )
                        } else {
                            Image(systemName: "doc.text")
                        }
                    }
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .accessibilityAddTraits(
                            scene.browserSelection.contains(row.id) ? .isSelected : []
                        )
                    if let notice = NotebookPlacementNotice(placement) {
                        // Keeps the room; the mark itself lies over the row.
                        NotebookNoticeMarkLabel(notice: notice).hidden()
                    }
                }
            }
            .padding(.leading, CGFloat(row.depth) * 16)
            .padding(.vertical, showsPreview && placement.item.kind == .note ? 4 : 0)
            .frame(minHeight: rowHeight)
            .contentShape(Rectangle())
            .onAppear {
                if placement.item.kind == .note { scene.fileRowAppeared(row.id) }
            }
            .onDisappear { scene.fileRowDisappeared(row.id) }
            #if os(macOS)
            // Covers the whole row, as the List selects it from anywhere.
            // On the label alone, a click near the row's edge only selected.
            .simultaneousGesture(TapGesture().onEnded {
                guard placement.item.kind == .note, scene.editingID != row.id,
                      !scene.selectingItems, !scene.busy,
                      NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty
                else { return }
                // List owns range/toggle selection. A plain click also
                // opens the note, including an already selected row.
                scene.browserSelection.selectOnly(row.id)
                scene.activateSidebarRow(placement)
            })
            #endif
            // Outside the row's click gesture, so clicking the mark or its
            // popover doesn't also open the note and redraw the row.
            .overlay(alignment: .trailing) {
                if scene.editingID != row.id, let notice = NotebookPlacementNotice(placement) {
                    NotebookNoticeMark(
                        scene: scene, placement: placement, notice: notice, onOpen: openNotice)
                }
            }
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(
                        scene.highlightedFileID == row.id ? 0.16 : 0
                    ))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor.opacity(
                        scene.highlightedFileID == row.id ? 0.65 : 0
                    ), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
            .accessibilityElement(children: .contain)
            .accessibilityValue(
                [scene.selectedID == row.id ? String(localized: "Current note") : nil,
                 scene.highlightedFileID == row.id
                    ? String(localized: "Revealed in Files") : nil]
                    .compactMap { $0 }.joined(separator: ", ")
            )
            .accessibilityIdentifier(
                (placement.item.kind == .note
                    ? "notebook-sidebar-note-" : "notebook-sidebar-folder-") + row.id.uuidString)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if !scene.selectingItems, scene.editingID == nil {
                    Button(role: .destructive) {
                        scene.trashItems([row.id])
                    } label: {
                        Label("Trash", systemImage: "trash")
                    }
                    .accessibilityIdentifier("notebook-swipe-trash")
                }
            }
            #if os(iOS)
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if !scene.showsSelectionControls, scene.editingID == nil,
                   scene.detailEditingID == nil {
                    Button {
                        // An open swipe can outlive a pointer multi-selection.
                        guard !scene.showsSelectionControls else { return }
                        scene.beginSelectingItems(startingWith: row.id)
                    } label: {
                        Image(systemName: "checkmark.circle")
                    }
                    .tint(.accentColor)
                    .accessibilityLabel("Select")
                    .accessibilityIdentifier("notebook-swipe-select")
                }
            }
            #endif
        }
    }
}

/// The actions for a note or folder, shared by Files, Recents, and the open
/// note's menu.
struct NotebookItemActions: View {
    let scene: NotebookSceneState
    let placement: NotebookPlacement
    var allowsCreation = true
    var allowsRename = true
    var allowsShowInFiles = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    var body: some View {
        let replica = scene.replica
        let busy = scene.busy
        let isFolder = placement.item.kind == .folder
        if placement.isInTrash {
            if allowsRename { renameButton }
            moveButton
            if placement.item.isTrashed {
                Button { scene.changeTrash(placement, trashed: false) } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
            } else {
                Text("Restore the parent folder, or move this item out.")
            }
            Divider()
            Button("Delete Permanently…", systemImage: "trash", role: .destructive) {
                scene.prepareDeletion(rootID: placement.item.id)
            }
            .disabled(busy)
        } else {
            // A folder's menu starts with what goes inside it.
            if isFolder, allowsCreation {
                creationButtons
                Divider()
            }
            if !isFolder, supportsMultipleWindows {
                Button("Open in New Window", systemImage: "macwindow.badge.plus") {
                    openWindow(
                        id: "notebook",
                        value: NotebookWindowValue(noteID: placement.item.id)
                    )
                }
                Divider()
            }
            if !isFolder, !replica.isHiddenFromRecents(placement.item.id) {
                NotebookRecentPinButton(scene: scene, id: placement.item.id)
            }
            if allowsRename { renameButton }
            moveButton
            if !isFolder, allowsShowInFiles {
                Button("Show in Files", systemImage: "list.bullet.indent") {
                    scene.showInFiles(placement.item.id)
                }
                .accessibilityIdentifier("notebook-show-in-files")
            }
            if isFolder {
                NotebookSortMenu(scene: scene, parentID: placement.item.id)
                let isDefault = replica.defaultNewNoteParentID == placement.item.id
                Button {
                    scene.setDefaultNewNoteParentID(isDefault ? nil : placement.item.id)
                } label: {
                    Label(
                        isDefault ? "Use Top Level for New Notes" : "Use for New Notes",
                        systemImage: isDefault ? "folder" : "tray"
                    )
                }
                .disabled(busy)
            }
            templatesAndSnippetsMenu
            if !isFolder {
                let hidden = replica.isHiddenFromRecents(placement.item.id)
                let visibilityTitle: LocalizedStringKey = hidden
                    ? "Show in Recents" : "Hide from Recents"
                Button {
                    scene.setRecentHidden(!hidden, for: placement.item.id)
                } label: {
                    Label(visibilityTitle,
                          systemImage: hidden ? "eye" : "eye.slash")
                }
                .disabled(busy)
                .accessibilityIdentifier("notebook-recents-visibility-" + placement.item.id.uuidString)
                // Creating beside a note keeps its spot in a hand-sorted folder.
                if allowsCreation {
                    Menu {
                        creationButtons
                    } label: {
                        Label("New", systemImage: "plus")
                    }
                    .accessibilityIdentifier("notebook-menu-new")
                }
            }
            Divider()
            Button("Move to Trash", systemImage: "trash", role: .destructive) {
                scene.changeTrash(placement, trashed: true)
            }
        }
    }

    @ViewBuilder private var creationButtons: some View {
        let parentID = scene.creationParent(for: placement)
        let position = scene.contextualCreationPosition(for: placement)
        Button("New Note", systemImage: "square.and.pencil") {
            scene.createItem(kind: .note, parentID: parentID, position: position)
        }
        .disabled(scene.busy)
        NotebookTemplateCreationButton(scene: scene)
        Button("New Folder", systemImage: "folder.badge.plus") {
            scene.createItem(kind: .folder, parentID: parentID, position: position)
        }
        .disabled(scene.busy)
    }

    private var renameButton: some View {
        Button("Rename…", systemImage: "pencil") { scene.beginRenaming(placement) }
    }

    private var moveButton: some View {
        Button("Move…", systemImage: "folder") {
            scene.beginMoving([placement.item.id], fromTrash: placement.isInTrash)
        }
    }

    private var templatesAndSnippetsMenu: some View {
        let replica = scene.replica
        return Menu {
            let registered = replica.isTemplateSource(placement.item.id)
            let title: LocalizedStringKey = placement.item.kind == .folder
                ? (registered ? "Stop Using as Template Folder" : "Use as Template Folder")
                : (registered ? "Stop Using as Template" : "Use as Template")
            Button {
                scene.setTemplateSource(placement.item.id, enabled: !registered)
            } label: {
                Label(title, systemImage: "doc.on.doc")
            }
            .disabled(scene.busy)
            .accessibilityIdentifier("notebook-use-as-template-\(placement.item.id)")
            let snippetRegistered = replica.isSnippetSource(placement.item.id)
            let snippetTitle: LocalizedStringKey = placement.item.kind == .folder
                ? (snippetRegistered ? "Stop Using as Snippet Folder" : "Use as Snippet Folder")
                : (snippetRegistered ? "Stop Using as Snippet" : "Use as Snippet")
            Button {
                scene.setSnippetSource(placement.item.id, enabled: !snippetRegistered)
            } label: {
                Label(snippetTitle, systemImage: "text.badge.plus")
            }
            .disabled(scene.busy)
            .accessibilityIdentifier("notebook-use-as-snippet-\(placement.item.id)")
        } label: {
            Label("Templates & Snippets", systemImage: "doc.on.doc")
        }
    }
}

/// Sorts a folder's items once; the manual order stays editable after.
private struct NotebookSortMenu: View {
    let scene: NotebookSceneState
    let parentID: UUID?

    var body: some View {
        Menu {
            Section("Sorts once. You can still drag to reorder.") {
                Button("Name, A–Z") { scene.sort(parentID, by: .nameAscending) }
                Button("Name, Z–A") { scene.sort(parentID, by: .nameDescending) }
            }
            Section {
                Button("Created, Newest First") {
                    scene.sort(parentID, by: .createdNewest)
                }
                Button("Created, Oldest First") {
                    scene.sort(parentID, by: .createdOldest)
                }
                Button("Modified, Newest First") {
                    scene.sort(parentID, by: .modifiedNewest)
                }
                Button("Modified, Oldest First") {
                    scene.sort(parentID, by: .modifiedOldest)
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .disabled(scene.busy)
    }
}

private struct NotebookRecentPinButton: View {
    let scene: NotebookSceneState
    let id: UUID
    var swipeIcon = false

    var body: some View {
        let pinned = scene.replica.isPinnedInRecents(id)
        let title: LocalizedStringKey = pinned
            ? "Unpin from Recents" : "Pin in Recents"
        Button {
            scene.setRecentPinned(!pinned, for: id)
        } label: {
            if swipeIcon {
                Image(systemName: pinned ? "pin.slash" : "pin.fill")
            } else {
                Label(title, systemImage: pinned ? "pin.slash" : "pin")
            }
        }
        .accessibilityLabel(Text(title))
        .disabled(!pinned && !scene.replica.canPinInRecents(id))
        .accessibilityIdentifier("notebook-recent-pin-" + id.uuidString)
    }
}

private struct NotebookTemplateCreationButton: View {
    let scene: NotebookSceneState

    var body: some View {
        Button(action: scene.showTemplates) {
            Label {
                Text("New from Template…")
                // Disabled without a hint, it looked broken.
                if scene.replica.templates.isEmpty {
                    Text("First use a note as a template")
                }
            } icon: {
                Image(systemName: "doc.on.doc")
            }
        }
        .disabled(scene.busy || scene.replica.templates.isEmpty)
        .accessibilityIdentifier("notebook-new-from-template")
    }
}

/// The menu for empty Files space, creating where the New Note button does.
private struct NotebookEmptySpaceActions: View {
    let scene: NotebookSceneState

    var body: some View {
        Button("New Note", systemImage: "square.and.pencil") { scene.createDefaultNote() }
            .disabled(scene.busy)
        NotebookTemplateCreationButton(scene: scene)
        Button("New Folder", systemImage: "folder.badge.plus") {
            scene.createItem(kind: .folder, parentID: nil)
        }
            .disabled(scene.busy)
    }
}

private struct NotebookSidebarSearch: ViewModifier {
    let search: NotebookSearchState
    let focus: FocusState<Bool>.Binding
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .searchable(text: Bindable(search).query,
                            isPresented: Bindable(search).isPresented,
                            placement: .toolbar, prompt: "Search all notes")
                .searchFocused(focus)
        } else {
            content
        }
    }
}

private struct NotebookFileRowBackground: ViewModifier {
    let color: Color?
    let insetHighlight: Color?

    func body(content: Content) -> some View {
        if let insetHighlight {
            content.listRowBackground(NotebookRowHighlight(color: insetHighlight))
        } else {
            content.listRowBackground(color)
        }
    }
}

struct NotebookLibraryNewNote: View {
    let scene: NotebookSceneState
    #if os(iOS)
        @Environment(\.mehPalette) private var palette
    #endif

    var body: some View {
        #if os(iOS)
        NotebookNewNoteButton(
            isEnabled: !scene.busy, highlighter: palette.highlighter.platformColor,
            hasTemplates: !scene.replica.templates.isEmpty,
            onNewNote: scene.createDefaultNote,
            onNewFromTemplate: scene.showTemplates,
            onNewFolder: { scene.createItem(kind: .folder, parentID: nil) }
        )
        .frame(width: 44, height: 44)
        #else
        Menu {
            Button("New Note") { scene.createDefaultNote() }
            NotebookTemplateCreationButton(scene: scene)
            Button {
                scene.createItem(kind: .folder, parentID: nil)
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
        } label: {
            Label("New Note", systemImage: "plus")
        } primaryAction: {
            scene.createDefaultNote()
        }
        .disabled(scene.busy)
        .accessibilityIdentifier("notebook-new-item")
        .accessibilityLabel("New Note")
        #endif
    }
}

#if os(iOS)
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

/// Resumes once the next frame is drawn, after pending view updates.
@MainActor
private final class NotebookNextFrame: NSObject {
    private var continuation: CheckedContinuation<Void, Never>?

    static func wait() async {
        let frame = NotebookNextFrame()
        await withCheckedContinuation { continuation in
            frame.continuation = continuation
            CADisplayLink(target: frame, selector: #selector(drawn))
                .add(to: .main, forMode: .common)
        }
    }

    @objc private func drawn(_ link: CADisplayLink) {
        link.invalidate()
        continuation?.resume()
        continuation = nil
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
