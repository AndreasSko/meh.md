import Foundation
import NoteCore
import SwiftUI

import UniformTypeIdentifiers

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

private struct EditorAttachmentID: Hashable {
    let noteID: UUID
    let isEditingEnabled: Bool
}

private struct NotebookSidebarRow: Identifiable {
    let placement: NotebookPlacement
    let depth: Int
    var id: UUID { placement.item.id }
}

struct NotebookView: View {
    let replica: NotebookReplica
    var workspace: NotebookWorkspace? = nil
    @State private var showingImport = false
    @State private var showingTextSize = false
    @AppStorage("editor.fontSize") private var editorFontSize = 17.0
    @AppStorage("editor.fontFamily") private var editorFontFamilyRaw =
        EditorFontFamily.system.rawValue
    @AppStorage("editor.mode") private var editorModeRaw =
        MarkdownEditorMode.livePreview.rawValue
    @State private var deletionSelection: NotebookDeletionSelection?
    @State private var navigationState: NotebookNavigationState
    @State private var restoredNavigation = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var busy = false
    @State private var editorNavigation = MarkdownEditorNavigation()
    @State private var errorMessage: String?
    @State private var unrecordedEdit = false
    @State private var editingID: UUID?
    @State private var originalName = ""
    @State private var proposedName = ""
    @FocusState private var focusedNameID: UUID?
    @State private var detailEditingID: UUID?
    @State private var detailOriginalName = ""
    @State private var detailProposedTitle = ""
    @FocusState private var focusedTitleID: UUID?
    @State private var movingItem: NotebookPlacement?
    @State private var destination: UUID?
    @State private var preferredCompactColumn = NavigationSplitViewColumn.sidebar
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    init(replica: NotebookReplica, workspace: NotebookWorkspace? = nil) {
        self.replica = replica
        self.workspace = workspace
        _navigationState = State(initialValue: NotebookNavigationState(replica: replica))
    }

    private var selectedID: UUID? { navigationState.selectedID }
    private var session: NoteSession? { navigationState.selectedSession }
    private var expandedIDs: Set<UUID> {
        get { navigationState.expandedFolderIDs }
        nonmutating set { navigationState.expandedFolderIDs = newValue }
    }
    private var trashExpanded: Bool {
        get { navigationState.isTrashExpanded }
        nonmutating set { navigationState.isTrashExpanded = newValue }
    }

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    recentsSection
                    Section {
                        Button {
                            navigationState.isTreeExpanded.toggle()
                        } label: {
                            HStack(spacing: 6) {
                                disclosureIcon(expanded: navigationState.isTreeExpanded)
                                Text("Notebook")
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("notebook-tree-toggle")
                        .accessibilityValue(navigationState.isTreeExpanded ? "Expanded" : "Collapsed")
                        if navigationState.isTreeExpanded {
                            ForEach(activeRows) { row in sidebarRow(row) }
                        }
                        Color.clear
                            .frame(height: 24)
                            .contentShape(Rectangle())
                            .onDrop(
                                of: [NotebookDragType.identifier],
                                delegate: NotebookDropDelegate {
                                    acceptDrop($0, to: nil)
                                }
                            )
                            .accessibilityHidden(true)
                    }
                    Section {
                        Button {
                            perform {
                                try await flushEditor()
                                trashExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                disclosureIcon(expanded: trashExpanded)
                                Label("Trash", systemImage: "trash")
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu { emptyTrashAction }

                        if trashExpanded {
                            ForEach(trashRows) { row in sidebarRow(row) }
                            if replica.placements.contains(where: \.isInTrash) {
                                emptyTrashAction
                                    .font(.caption)
                                    .padding(.leading, 24)
                            }
                        }
                    }
                }
                .padding(10)
            }
            .contextMenu { creationActions(parentID: nil) }
            .navigationTitle("meh.md")
            .navigationSplitViewColumnWidth(min: 220, ideal: 280)
            .toolbar {
                if let workspace, workspace.usesSync {
                    ToolbarItem {
                        NotebookSyncToolbarButton(workspace: workspace)
                    }
                }
                ToolbarItem {
                    Button { showingImport = true } label: {
                        Label("Import Markdown", systemImage: "square.and.arrow.down")
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("notebook-import")
                }
                ToolbarItem {
                    Button {
                        createItem(kind: .note, parentID: nil)
                    } label: {
                        Label("New Note", systemImage: "plus")
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("notebook-new-item")
                }
            }
        } detail: {
            Group {
                if let session, let selectedID {
                    VStack(spacing: 0) {
                        if let placement = selectedPlacement {
                            detailTitle(for: placement)
                            Divider()
                        }
                        NotebookNoteEditor(
                            session: session, navigation: editorNavigation,
                            isInTrash: selectedPlacement?.isInTrash == true,
                            hasUnrecordedEdit: $unrecordedEdit,
                            onPersist: {
                                workspace?.contentDidSave(trigger: "note persisted")
                            },
                            onLocalEdit: { navigationState.recordEdited(selectedID) },
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
                    .id(selectedID)
                    .navigationTitle("")
                    .task(id: EditorAttachmentID(
                        noteID: selectedID, isEditingEnabled: session.isEditingEnabled
                    )) {
                        guard session.isEditingEnabled else { return }
                        let incomingNavigation = editorNavigation
                        let state = navigationState
                        let position = state.position(for: selectedID).flatMap {
                            try? JSONDecoder().decode(MarkdownEditorPosition.self, from: $0)
                        }
                        incomingNavigation.whenAttached { [weak incomingNavigation, weak state] in
                            guard let incomingNavigation,
                                  state?.selectedID == selectedID else { return }
                            if let position {
                                incomingNavigation.restorePosition?(position)
                            }
                        }
                    }
                    .toolbar {
                        if let placement = selectedPlacement {
                            #if os(iOS)
                            if horizontalSizeClass == .compact {
                                if let workspace, workspace.usesSync {
                                    ToolbarItem {
                                        NotebookSyncToolbarButton(workspace: workspace)
                                    }
                                }
                                ToolbarItem {
                                    Button {
                                        createItem(kind: .note, parentID: nil)
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
                                        allowsRename: false
                                    )
                                } label: {
                                    Label("Note Actions", systemImage: "ellipsis.circle")
                                }
                                .accessibilityIdentifier("notebook-note-actions")
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
        .safeAreaInset(edge: .bottom) {
            if let workspace { NotebookWorkspaceStatusView(workspace: workspace) }
        }
        .onChange(of: replica.catalogSnapshot) { _, _ in
            workspace?.contentDidSave(trigger: "catalog snapshot changed")
            navigationState.refreshAvailability()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { rememberEditorPosition() }
        }
        .onDisappear { rememberEditorPosition() }
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
                get: { movingItem != nil }, set: { if !$0 { movingItem = nil } }
            )
        ) { moveSheet }
        .sheet(isPresented: $showingImport) {
            NotebookImportView(replica: replica, onImport: importMarkdown)
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
            await navigationState.restoreLastSelection()
            if selectedID != nil { preferredCompactColumn = .detail }
            busy = false
        }
        .task(id: navigationState.recentNoteIDs) {
            await navigationState.loadRecentSessions()
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
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if detailEditingID == placement.item.id {
                TextField(
                    "Note title",
                    text: Binding(
                        get: { detailProposedTitle },
                        set: { value in
                            if value.contains(where: { $0.isNewline }) {
                                detailProposedTitle = value.filter { !$0.isNewline }
                                submitDetailTitle()
                            } else {
                                detailProposedTitle = value
                            }
                        }
                    ),
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .lineLimit(1...4)
                .focused($focusedTitleID, equals: placement.item.id)
                .disabled(busy)
                .submitLabel(.done)
                .onSubmit { submitDetailTitle() }
                .onChange(of: busy, initial: true) { _, isBusy in
                    if !isBusy { focusedTitleID = placement.item.id }
                }
                .notebookEscapeAction { cancelDetailTitle() }
                .accessibilityIdentifier("title-field")
            } else {
                Button {
                    beginDetailRenaming(placement)
                } label: {
                    Text(NotebookNoteName.title(from: placement.displayName))
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .accessibilityIdentifier("note-title")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    private var recentsSection: some View {
        Section {
            Button {
                navigationState.isRecentsExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    disclosureIcon(expanded: navigationState.isRecentsExpanded)
                    Text("Recents")
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("notebook-recents-toggle")
            .accessibilityValue(navigationState.isRecentsExpanded ? "Expanded" : "Collapsed")
            if navigationState.isRecentsExpanded {
                ForEach(navigationState.recentNoteIDs, id: \.self) { id in
                    if let placement = replica.placements.first(where: { $0.item.id == id }) {
                        Button {
                            perform {
                                try await selectNote(id)
                                reveal(id)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(NotebookNoteName.title(from: placement.displayName))
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(recentPreview(for: id))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(
                            selectedID == id ? Color.accentColor.opacity(0.14) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .accessibilityIdentifier("notebook-recent-" + id.uuidString)
                        .contextMenu { actions(for: placement, allowsCreation: false) }
                    }
                }
                if navigationState.recentNoteIDs.isEmpty {
                    Text("Notes you edit or rename appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                }
            }
        }
    }

    private func recentPreview(for id: UUID) -> String {
        guard let recent = navigationState.recentSessions[id] else { return "Preview unavailable" }
        guard recent.isEditingEnabled else { return "Note unavailable" }
        let preview = recent.text.prefix(160)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return preview.isEmpty ? "Empty note" : preview
    }

    private var activeRows: [NotebookSidebarRow] {
        flattenedRows(inTrash: false)
    }

    private var trashRows: [NotebookSidebarRow] {
        flattenedRows(inTrash: true, initialDepth: 1)
    }

    private func flattenedRows(
        inTrash: Bool,
        parentID: UUID? = nil,
        initialDepth: Int = 0
    ) -> [NotebookSidebarRow] {
        var result: [NotebookSidebarRow] = []
        for placement in sorted(
            replica.placements.filter {
                $0.isInTrash == inTrash && $0.parentID == parentID
            })
        {
            result.append(NotebookSidebarRow(placement: placement, depth: initialDepth))
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

    private func sorted(_ items: [NotebookPlacement]) -> [NotebookPlacement] {
        items.sorted {
            if $0.item.kind != $1.item.kind { return $0.item.kind == .folder }
            let order = $0.displayName.localizedStandardCompare($1.displayName)
            return order == .orderedSame
                ? $0.item.id.uuidString < $1.item.id.uuidString : order == .orderedAscending
        }
    }

    @ViewBuilder
    private func sidebarRow(_ row: NotebookSidebarRow) -> some View {
        let placement = row.placement
        HStack(spacing: 6) {
            if placement.item.kind == .folder {
                Button {
                    perform {
                        try await flushEditor()
                        toggleFolder(placement.item.id)
                    }
                } label: {
                    disclosureIcon(expanded: expandedIDs.contains(placement.item.id))
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 10, height: 1)
            }

            Image(systemName: placement.item.kind == .folder ? "folder" : "note.text")
            if editingID == placement.item.id {
                TextField("Name", text: $proposedName)
                    .textFieldStyle(.plain)
                    .focused($focusedNameID, equals: placement.item.id)
                    .disabled(busy)
                    .onSubmit { submitInlineName() }
                    .notebookEscapeAction { cancelInlineName() }
                    .notebookSelectNameOnFocus()
            } else {
                Text(placement.displayName).lineLimit(1)
                if !placement.issues.isEmpty {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Recovered placement or metadata conflict")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(row.depth) * 16)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minHeight: sidebarRowHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            guard editingID != placement.item.id else { return }
            perform {
                if placement.item.kind == .folder {
                    try await flushEditor()
                    toggleFolder(placement.item.id)
                } else {
                    try await selectNote(placement.item.id)
                }
            }
        }
        .background(
            selectedID == placement.item.id || editingID == placement.item.id
                ? Color.accentColor.opacity(0.14) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contextMenu { actions(for: placement) }
        .onDrag { dragProvider(for: placement.item.id) }
        .onDrop(
            of: [NotebookDragType.identifier],
            delegate: NotebookDropDelegate {
                guard placement.item.kind == .folder else { return false }
                return acceptDrop($0, to: placement.item.id)
            }
        )
    }

    private func disclosureIcon(expanded: Bool) -> some View {
        Image(systemName: expanded ? "chevron.down" : "chevron.right")
            .font(.caption)
            .frame(width: 10)
            .foregroundStyle(.secondary)
    }

    private func toggleFolder(_ id: UUID) {
        if expandedIDs.contains(id) {
            expandedIDs.remove(id)
        } else {
            expandedIDs.insert(id)
        }
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
        allowsRename: Bool = true
    ) -> some View {
        if allowsCreation, !placement.isInTrash {
            creationActions(parentID: creationParent(for: placement))
            Divider()
        }
        if allowsRename { Button("Rename…") { beginRenaming(placement) } }
        Button("Move…") {
            destination = placement.item.parentID
            movingItem = placement
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
            Button("Move to Trash", role: .destructive) {
                changeTrash(placement, trashed: true)
            }
        }
    }

    private func creationParent(for placement: NotebookPlacement) -> UUID? {
        placement.item.kind == .folder ? placement.item.id : placement.item.parentID
    }

    private var moveSheet: some View {
        NavigationStack {
            Form {
                Picker("Destination", selection: $destination) {
                    Text("Notebook root").tag(nil as UUID?)
                    ForEach(
                        sorted(
                            replica.placements.filter {
                                $0.item.kind == .folder && !$0.isInTrash
                                    && $0.item.id != movingItem?.item.id
                            }), id: \.item.id
                    ) { placement in
                        Text(folderPath(placement)).tag(placement.item.id as UUID?)
                    }
                }
            }
            .navigationTitle("Move \(movingItem?.displayName ?? "Item")")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { movingItem = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") {
                        guard let item = movingItem else { return }
                        let target = destination
                        movingItem = nil
                        move(item.item.id, to: target)
                    }
                }
            }
        }
        .frame(minWidth: 300, minHeight: 220)
    }

    private func folderPath(_ placement: NotebookPlacement) -> String {
        if let parent = replica.placements.first(where: { $0.item.id == placement.parentID }) {
            return folderPath(parent) + " / " + placement.displayName
        }
        return placement.displayName
    }

    private func createItem(kind: NotebookItemKind, parentID: UUID?) {
        perform {
            try await flushEditor()
            if let parentID { expandedIDs.insert(parentID) }
            switch kind {
            case .note:
                let siblingNames = replica.placements.compactMap { placement in
                    placement.parentID == parentID && !placement.isInTrash
                        ? placement.item.name : nil
                }
                let name = NotebookNoteName.defaultFilename(
                    existingNames: siblingNames
                )
                let id = try await replica.createNote(name: name, parentID: parentID)
                try await selectNote(id)
                detailEditingID = id
                detailOriginalName = name
                detailProposedTitle = NotebookNoteName.title(from: name)
            case .folder:
                let id = try await replica.createFolder(
                    name: "Untitled Folder", parentID: parentID)
                beginRenaming(id: id, name: "Untitled Folder")
            }
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
            if focusBody {
                editorNavigation.resumeEditing?()
                editorNavigation.focusEditor?()
            }
        }
    }

    private func commitDetailTitleIfNeeded() async throws {
        guard let id = detailEditingID else { return }
        let filename = NotebookNoteName.filename(
            for: detailProposedTitle,
            preservingExtensionFrom: detailOriginalName
        )
        let changed = replica.placements.first { $0.item.id == id }?.item.name != filename
        try await replica.rename(id, to: filename)
        if changed { navigationState.recordRenamed(id) }
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
        try await replica.rename(id, to: name)
        if placement?.item.kind == .note, placement?.item.name != name {
            navigationState.recordRenamed(id)
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
        perform {
            try await flushEditor()
            try await replica.setTrashed(placement.item.id, trashed)
            if trashed { trashExpanded = true }
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
        if next?.isInTrash == true { trashExpanded = true }
        while let parentID = next?.parentID {
            expandedIDs.insert(parentID)
            next = replica.placements.first { $0.item.id == parentID }
        }
    }

    private func dragPayload(for id: UUID) -> String {
        "meh-notebook-item:\(replica.catalogSnapshot?.notebookID.uuidString ?? ""):\(id.uuidString)"
    }

    private func draggedID(from value: String) -> UUID? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard let notebookID = replica.catalogSnapshot?.notebookID.uuidString else {
            return nil
        }
        guard parts.count == 3,
            parts[0] == "meh-notebook-item",
            String(parts[1]) == notebookID,
            let id = UUID(uuidString: String(parts[2])),
            replica.placements.contains(where: { $0.item.id == id })
        else {
            return nil
        }
        return id
    }

    private func dragProvider(for id: UUID) -> NSItemProvider {
        let value = dragPayload(for: id)
        let provider = NSItemProvider(object: value as NSString)
        provider.suggestedName = value
        return provider
    }

    private func acceptDrop(_ providers: [NSItemProvider], to parentID: UUID?) -> Bool {
        guard !busy, providers.count == 1,
            let provider = providers.first,
            provider.hasItemConformingToTypeIdentifier(NotebookDragType.identifier)
        else {
            return false
        }
        if let value = provider.suggestedName, let id = draggedID(from: value) {
            move(id, to: parentID)
            return true
        }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let value = object as? String else { return }
            Task { @MainActor in
                guard let id = draggedID(from: value) else { return }
                move(id, to: parentID)
            }
        }
        return true
    }

    private func move(_ id: UUID, to parentID: UUID?) {
        perform {
            try await flushEditor()
            try await replica.move(id, to: parentID)
            if let parentID { expandedIDs.insert(parentID) }
            reveal(id)
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

    private func rememberEditorPosition() {
        guard let selectedID,
              let position = editorNavigation.capturePosition?(),
              let data = try? JSONEncoder().encode(position) else { return }
        navigationState.setPosition(data, for: selectedID)
    }

    private func selectNote(_ id: UUID, revealDetail: Bool = true) async throws {
        if id != selectedID {
            try await flushEditor()
            let openedSession = try await replica.openNote(id, allowingRecovery: true)
            if navigationState.installSelection(id, session: openedSession, recordActivity: true) {
                editorNavigation.invalidate()
                editorNavigation = MarkdownEditorNavigation()
            }
        } else {
            if editingID != nil || detailEditingID != nil { try await flushEditor() }
            navigationState.recordOpened(id)
        }
        if revealDetail { preferredCompactColumn = .detail }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer {
                editorNavigation.resumeEditing?()
                busy = false
            }
            do {
                try await operation()
            } catch {
                errorMessage = error.localizedDescription
                if let editingID {
                    Task { @MainActor in focusedNameID = editingID }
                } else if let detailEditingID {
                    Task { @MainActor in focusedTitleID = detailEditingID }
                }
            }
        }
    }
}

private enum NotebookDragType {
    static let identifier = UTType.utf8PlainText.identifier
}

private struct NotebookDropDelegate: DropDelegate {
    let accept: ([NSItemProvider]) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        return info.hasItemsConforming(to: [NotebookDragType.identifier])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        return accept(info.itemProviders(for: [NotebookDragType.identifier]))
    }
}

private enum NotebookNavigationError: LocalizedError {
    case unrecordedEdit
    var errorDescription: String? {
        "Finish composing your text and resolve any edit error before leaving this note."
    }
}

extension View {
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
