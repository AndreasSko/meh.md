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
        if scene.showsSelectionControls && !search.isPresented { return "" }
        #if os(iOS)
        // The app name repeats the window identity and crowds a split sidebar.
        if !isCompact { return "" }
        #endif
        return "meh.md"
    }

    var body: some View {
            ZStack {
                Group {
                    if isCompact && scene.isLibraryEmpty {
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
            .searchable(text: Bindable(search).query, isPresented: Bindable(search).isPresented,
                        placement: .toolbar, prompt: "Search all notes")
            .searchFocused(focus.search)
            #if os(macOS)
            .scrollIndicators(.automatic)
            #endif
            .overlay(alignment: .bottom) {
                if !isCompact && !search.isPresented && !scene.showsSelectionControls
                    && !scene.browsingAllRecents {
                    NotebookSidebarControls(
                        busy: scene.busy,
                        showSettings: { scene.openSettings() },
                        showTrash: { scene.openTrash() }
                    )
                }
            }
            .navigationTitle(sidebarTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(scene.showsSelectionControls ? .inline : .large)
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
                                showingDetails: $scene.showingSyncDetails
                            )
                        }
                    }
                    if scene.showsSelectionControls && !search.isPresented {
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
        .accessibilityIdentifier("notebook-selection-done")
        .disabled(scene.busy)
    }

    @ViewBuilder
    private var browserUndoActions: some View {
        if scene.browserUndo?.action == .move {
            Button("Undo Move") { scene.undoBrowserChange(redo: false) }
                .accessibilityIdentifier("notebook-browser-undo")
        }
        if scene.browserRedo?.action == .move {
            Button("Redo Move") { scene.undoBrowserChange(redo: true) }
                .accessibilityIdentifier("notebook-browser-redo")
        }
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
                scene.beginSelectingItems()
            }
            .accessibilityIdentifier("notebook-select-items")
            NotebookSortMenu(scene: scene, parentID: nil, label: "Sort Files Once")
                .accessibilityIdentifier("notebook-sort-root")
            NotebookTemplateCreationButton(scene: scene)
            Button {
                scene.createItem(kind: .folder, parentID: nil)
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            Button { scene.requestImport() } label: {
                Label("Import Markdown…", systemImage: "square.and.arrow.down")
            }
            .accessibilityIdentifier("notebook-import-browser")
            Divider()
            browserUndoActions
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
                    scene.trashItems([id], crumplesOpenNote: false,
                                     onCompletion: completion)
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
                selectedNoteID: scene.selectedID,
                isExpanded: Bindable(scene).browsingAllRecents,
                onSelect: { id in
                    guard id != scene.selectedID else { return }
                    scene.perform { try await scene.selectNote(id) }
                },
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
        var menuActions: [UIMenuElement] = [
            UIAction(title: String(localized: "Rename…")) { _ in
                scene.beginRenaming(placement)
            },
            UIAction(title: String(localized: "Move…")) { _ in
                scene.beginMoving([id], fromTrash: false)
            },
            UIAction(title: String(localized: "Show in Files")) { _ in
                scene.showInFiles(id)
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
            scene.setRecentPinned(!pinned, for: id)
        })
        menuActions.append(UIAction(
            title: String(localized: "Hide from Recents"),
            image: UIImage(systemName: "eye.slash"),
            attributes: scene.busy ? .disabled : []
        ) { _ in
            scene.setRecentHidden(true, for: id)
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
            title: String(localized: "Move to Trash"),
            attributes: .destructive
        ) { _ in
            scene.changeTrash(placement, trashed: true)
        })
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
                                scene.trashItems([id], crumplesOpenNote: false,
                                                 onCompletion: completion)
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
        return ForEach(rows) { row in
            NotebookFileRow(scene: scene, row: row, afterEndID: afterEndID,
                            targetDepth: targetDepth, focusedNameID: focus.name)
                .tag(row.id)
                .id(row.id)
                .listRowSeparator(.hidden)
                // A custom clear background also hides the native selected fill.
                .listRowBackground(scene.browserSelection.contains(row.id) ? nil : Color.clear)
                .listRowInsets(sidebarSectionInsets)
        }
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
                    NotebookLibraryFooter(noteCount: scene.activeNoteCount)
                        .opacity(hidesCompactRows ? 0 : 1)
                        .accessibilityHidden(hidesCompactRows)
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
                    interaction: scene.browserDropInteraction()
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
                .allowsHitTesting(false)
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
            begin: scene.beginBrowserDrag
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
            if phase == .tracking || phase == .interacting {
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
            await Task.yield()
            #if os(iOS)
            // A new inline editor replaces the row's drag source. Allow
            // that layout to finish before revealing a virtualized row.
            if scene.editingID == request.id {
                try? await Task.sleep(for: .milliseconds(100))
            }
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
            scene.perform {
                try await scene.selectNote(id)
            }
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
                scene.trashItems([id], crumplesOpenNote: false)
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
    var focusedNameID: FocusState<UUID?>.Binding

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
                        Text(placement.item.kind == .note
                            ? NotebookNoteName.title(from: placement.displayName)
                            : placement.displayName)
                            .accessibilityIdentifier("notebook-sidebar-title-" + row.id.uuidString)
                    } icon: {
                        if placement.item.kind == .folder {
                            NotebookFolderIcon(
                                systemName: scene.replica.defaultNewNoteParentID == row.id
                                    ? "tray" : "folder"
                            )
                        } else {
                            Image(systemName: "note.text")
                        }
                    }
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        #if os(macOS)
                        .simultaneousGesture(TapGesture().onEnded {
                            guard placement.item.kind == .note,
                                  !scene.selectingItems, !scene.busy,
                                  NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty
                            else { return }
                            // List owns range/toggle selection. A plain click also
                            // opens the note, including an already selected row.
                            scene.browserSelection.selectOnly(row.id)
                            scene.activateSidebarRow(placement)
                        })
                        #endif
                        .accessibilityAddTraits(
                            scene.browserSelection.contains(row.id) ? .isSelected : []
                        )
                    if !placement.issues.isEmpty {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Recovered placement or metadata conflict")
                    }
                }
            }
            .padding(.leading, CGFloat(row.depth) * 16)
            .frame(minHeight: rowHeight)
            .contentShape(Rectangle())
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
                scene.highlightedFileID == row.id ? "Revealed in Files" : ""
            )
            .accessibilityIdentifier(
                (placement.item.kind == .note
                    ? "notebook-sidebar-note-" : "notebook-sidebar-folder-") + row.id.uuidString)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if !scene.selectingItems, scene.editingID == nil {
                    Button(role: .destructive) {
                        scene.trashItems([row.id], crumplesOpenNote: false)
                    } label: {
                        Label("Trash", systemImage: "trash")
                    }
                    .accessibilityIdentifier("notebook-swipe-trash")
                }
            }
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
        if allowsCreation, !placement.isInTrash {
            let parentID = scene.creationParent(for: placement)
            let position = scene.contextualCreationPosition(for: placement)
            Button("New Note") {
                scene.createItem(kind: .note, parentID: parentID, position: position)
            }
                .disabled(busy)
            NotebookTemplateCreationButton(scene: scene)
            Button("New Folder") {
                scene.createItem(kind: .folder, parentID: parentID, position: position)
            }
                .disabled(busy)
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
        if allowsRename { Button("Rename…") { scene.beginRenaming(placement) } }
        if !placement.isInTrash {
            Menu {
                let registered = replica.isTemplateSource(placement.item.id)
                let title: LocalizedStringKey = placement.item.kind == .folder
                    ? (registered ? "Stop Using as Template Folder" : "Use as Template Folder")
                    : (registered ? "Stop Using as Template" : "Use as Template")
                Button {
                    scene.setTemplateSource(placement.item.id, enabled: !registered)
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
                    scene.setSnippetSource(placement.item.id, enabled: !snippetRegistered)
                } label: {
                    Label(snippetTitle, systemImage: "text.badge.plus")
                }
                .disabled(busy)
                .accessibilityIdentifier("notebook-use-as-snippet-\(placement.item.id)")
            } label: {
                Label("Templates & Snippets", systemImage: "doc.on.doc")
            }
        }
        Button("Move…") {
            scene.beginMoving([placement.item.id], fromTrash: placement.isInTrash)
        }
        if !placement.isInTrash, placement.item.kind == .note {
            if allowsShowInFiles {
                Button("Show in Files") { scene.showInFiles(placement.item.id) }
                    .accessibilityIdentifier("notebook-show-in-files")
            }
            if !replica.isHiddenFromRecents(placement.item.id) {
                NotebookRecentPinButton(scene: scene, id: placement.item.id)
            }
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
        }
        if placement.isInTrash {
            if placement.item.isTrashed {
                Button("Restore") { scene.changeTrash(placement, trashed: false) }
            } else {
                Text("Restore the parent folder, or move this item out.")
            }
            Divider()
            Button("Delete Permanently…", role: .destructive) {
                scene.prepareDeletion(rootID: placement.item.id)
            }
            .disabled(busy)
        } else {
            if placement.item.kind == .folder {
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
                Divider()
            }
            Button("Move to Trash", role: .destructive) {
                scene.changeTrash(placement, trashed: true)
            }
            if placement.item.kind == .folder {
                Divider()
                NotebookSortMenu(
                    scene: scene,
                    parentID: placement.item.id,
                    label: "Sort Folder Once"
                )
            }
        }
    }
}

private struct NotebookSortMenu: View {
    let scene: NotebookSceneState
    let parentID: UUID?
    let label: LocalizedStringResource

    var body: some View {
        Menu {
            Button("Name, A–Z") { scene.sort(parentID, by: .nameAscending) }
            Button("Name, Z–A") { scene.sort(parentID, by: .nameDescending) }
            Divider()
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
        } label: {
            Label(label, systemImage: "arrow.up.arrow.down")
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
                Text(title)
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
            Label("New from Template…", systemImage: "doc.on.doc")
        }
        .disabled(scene.busy || scene.replica.templates.isEmpty)
        .accessibilityIdentifier("notebook-new-from-template")
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
