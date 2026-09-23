import NoteCore
import SwiftUI

private struct NotebookTrashRow: Identifiable {
    let placement: NotebookPlacement
    let depth: Int

    var id: UUID { placement.item.id }
}

struct NotebookTrashView: View {
    let replica: NotebookReplica
    let beforeMutation: () async throws -> Void
    let onMutation: () -> Void
    let onOpenNote: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var expandedFolderIDs: Set<UUID> = []
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var movingID: UUID?
    @State private var destination: UUID?
    @State private var deletionSelection: NotebookDeletionSelection?
    @State private var deletingAll = false
    @State private var selectingItems = false
    @State private var selectedIDs: Set<UUID> = []

    var body: some View {
        Group {
            if trashRows.isEmpty {
                NotebookTrashEmptyState()
            } else {
                List(trashRows, selection: nativeSelection) { row in
                    NotebookTrashItemRow(
                        placement: row.placement,
                        depth: row.depth,
                        isExpanded: expandedFolderIDs.contains(row.id),
                        busy: busy,
                        selecting: usesNativeSelection,
                        toggleFolder: { toggleFolder(row.id) },
                        openNote: { onOpenNote(row.id) },
                        restore: { restore(row.placement) },
                        move: { beginMoving(row.placement) },
                        delete: { preparePermanentDeletion(rootID: row.id) }
                    )
                    .tag(row.id)
                }
                .listStyle(.inset)
                .disabled(busy)
                #if os(iOS)
                .environment(\.editMode, Binding(
                    get: { selectingItems ? .active : .inactive },
                    set: { selectingItems = $0.isEditing }
                ))
                #else
                .contextMenu(forSelectionType: UUID.self) { ids in
                    Button("Restore") { restoreItems(Array(ids)) }
                        .disabled(busy || ids.isEmpty)
                    Button("Delete Permanently…", role: .destructive) {
                        prepareDeletion(ids: Array(ids))
                    }
                    .disabled(busy || ids.isEmpty)
                } primaryAction: { ids in
                    guard !busy, ids.count == 1, let id = ids.first,
                          let item = replica.placements.first(where: { $0.item.id == id })
                    else { return }
                    if item.item.kind == .folder { toggleFolder(id) }
                    else { onOpenNote(id) }
                }
                #endif
            }
        }
        .navigationTitle("Trash")
        .accessibilityIdentifier("notebook-trash-view")
        .interactiveDismissDisabled(busy)
        .onChange(of: replica.catalogSnapshot) { _, _ in
            selectedIDs.formIntersection(trashRows.map(\.id))
            if trashRows.isEmpty { selectingItems = false }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    if selectingItems {
                        selectingItems = false
                        selectedIDs.removeAll()
                    } else {
                        dismiss()
                    }
                }
                .disabled(busy)
                .accessibilityIdentifier(selectingItems
                    ? "notebook-trash-done-selection" : "notebook-trash-close")
            }
            ToolbarItem(placement: .cancellationAction) {
                if selectingItems {
                    selectAllButton
                } else {
                    Button("Empty Trash…", role: .destructive) {
                        preparePermanentDeletion(rootID: nil)
                    }
                    .disabled(busy || trashRows.isEmpty)
                    .accessibilityIdentifier("notebook-empty-trash")
                }
            }
            #if os(iOS)
            if !selectingItems {
                ToolbarItem(placement: .primaryAction) {
                    Button("Select") { selectingItems = true }
                        .disabled(busy || trashRows.isEmpty)
                        .accessibilityIdentifier("notebook-trash-select")
                }
            }
            if selectingItems {
                ToolbarItemGroup(placement: .bottomBar) {
                    restoreButton
                    Spacer()
                    deleteButton
                }
                ToolbarItem(placement: .status) { selectionCount }
                    .sharedBackgroundVisibility(.hidden)
            }
            #else
            ToolbarItemGroup(placement: .automatic) {
                restoreButton
                deleteButton
            }
            ToolbarItem(placement: .status) { selectionCount }
                .sharedBackgroundVisibility(.hidden)
            #endif
        }
        .sheet(
            isPresented: Binding(
                get: { movingID != nil },
                set: { if !$0 { movingID = nil } }
            )
        ) {
            NotebookTrashMoveView(
                destinations: moveDestinations,
                destination: $destination,
                busy: busy,
                cancel: { movingID = nil },
                move: confirmMove
            )
        }
        .alert(
            "Couldn’t complete the action",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            deletingAll ? "Empty Trash?" : "Delete permanently?",
            isPresented: Binding(
                get: { deletionSelection != nil },
                set: { if !$0 { deletionSelection = nil } }
            ),
            titleVisibility: .visible,
            presenting: deletionSelection
        ) { selection in
            Button("Delete Permanently", role: .destructive) {
                permanentlyDelete(selection)
            }
            Button("Cancel", role: .cancel) { deletionSelection = nil }
        } message: { selection in
            Text(deletionMessage(selection))
        }
    }

    private var usesNativeSelection: Bool {
        #if os(macOS)
        true
        #else
        selectingItems
        #endif
    }

    private var nativeSelection: Binding<Set<UUID>>? {
        usesNativeSelection ? $selectedIDs : nil
    }

    private var selectAllButton: some View {
        Button("Select All") {
            selectedIDs = Set(trashRows.map(\.id))
        }
        .disabled(busy || trashRows.isEmpty)
        .accessibilityIdentifier("notebook-trash-select-all")
    }

    private var selectionCount: some View {
        Text("\(selectedIDs.count) Selected")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("notebook-trash-selection-count")
    }

    private var restoreButton: some View {
        Button("Restore") { restoreItems(Array(selectedIDs)) }
            .disabled(busy || selectedIDs.isEmpty)
            .accessibilityIdentifier("notebook-trash-restore-selected")
    }

    private var deleteButton: some View {
        Button("Delete", role: .destructive) { prepareSelectedDeletion() }
            .tint(.red)
            .disabled(busy || selectedIDs.isEmpty)
            .accessibilityIdentifier("notebook-trash-delete-selected")
    }

    private func restoreItems(_ selection: [UUID]) {
        let ids = selection.sorted { $0.uuidString < $1.uuidString }
        perform {
            try await beforeMutation()
            try await replica.restoreItems(ids)
            selectedIDs.subtract(ids)
            onMutation()
        }
    }

    private func prepareSelectedDeletion() {
        prepareDeletion(ids: Array(selectedIDs))
    }

    private func prepareDeletion(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        perform {
            try await beforeMutation()
            deletingAll = false
            deletionSelection = try replica.deletionSelection(rootIDs: ids)
        }
    }

    private var trashRows: [NotebookTrashRow] {
        flattenedRows(parentID: nil, depth: 0)
    }

    private func flattenedRows(parentID: UUID?, depth: Int) -> [NotebookTrashRow] {
        replica.orderedChildren(parentID: parentID, inTrash: true).flatMap { placement in
            var rows = [NotebookTrashRow(placement: placement, depth: depth)]
            if placement.item.kind == .folder,
               expandedFolderIDs.contains(placement.item.id) {
                rows += flattenedRows(parentID: placement.item.id, depth: depth + 1)
            }
            return rows
        }
    }

    private var moveDestinations: [NotebookTrashDestination] {
        let folders = replica.placements.filter {
            $0.item.kind == .folder && !$0.isInTrash
        }
        return folders.map {
            NotebookTrashDestination(id: $0.item.id, path: folderPath($0))
        }.sorted {
            let order = $0.path.localizedStandardCompare($1.path)
            return order == .orderedSame
                ? $0.id.uuidString < $1.id.uuidString
                : order == .orderedAscending
        }
    }

    private func folderPath(_ placement: NotebookPlacement) -> String {
        guard let parent = replica.placements.first(where: {
            $0.item.id == placement.parentID
        }) else { return placement.displayName }
        return folderPath(parent) + " / " + placement.displayName
    }

    private func toggleFolder(_ id: UUID) {
        if expandedFolderIDs.contains(id) {
            expandedFolderIDs.remove(id)
            selectedIDs.formIntersection(trashRows.map(\.id))
        } else {
            expandedFolderIDs.insert(id)
        }
    }

    private func restore(_ placement: NotebookPlacement) {
        guard placement.item.isTrashed else { return }
        perform {
            try await beforeMutation()
            try await replica.setTrashed(placement.item.id, false)
            onMutation()
        }
    }

    private func beginMoving(_ placement: NotebookPlacement) {
        destination = nil
        movingID = placement.item.id
    }

    private func confirmMove() {
        guard let id = movingID,
              let placement = replica.placements.first(where: { $0.item.id == id }),
              placement.isInTrash else {
            movingID = nil
            return
        }
        let target = destination
        movingID = nil
        perform {
            try await beforeMutation()
            try await replica.move(id, to: target)
            if placement.item.isTrashed {
                try await replica.setTrashed(id, false)
            }
            onMutation()
        }
    }

    private func preparePermanentDeletion(rootID: UUID?) {
        perform {
            try await beforeMutation()
            deletingAll = rootID == nil
            deletionSelection = try replica.deletionSelection(rootID: rootID)
        }
    }

    private func permanentlyDelete(_ selection: NotebookDeletionSelection) {
        deletionSelection = nil
        perform {
            try await beforeMutation()
            try await replica.permanentlyDelete(selection)
            expandedFolderIDs.subtract(selection.ids)
            selectedIDs.subtract(selection.ids)
            onMutation()
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

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                try await operation()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct NotebookTrashItemRow: View {
    let placement: NotebookPlacement
    let depth: Int
    let isExpanded: Bool
    let busy: Bool
    let selecting: Bool
    let toggleFolder: () -> Void
    let openNote: () -> Void
    let restore: () -> Void
    let move: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if selecting {
                    rowLabel
                } else {
                    Button(action: placement.item.kind == .folder ? toggleFolder : openNote) {
                        rowLabel
                    }
                    .buttonStyle(.plain)
                }
            }
            .disabled(busy)
            .accessibilityIdentifier(itemIdentifier)
            .contextMenu {
                if !selecting {
                    if placement.item.isTrashed { Button("Restore", action: restore) }
                    Button("Move…", action: move)
                    Divider()
                    Button("Delete Permanently…", role: .destructive, action: delete)
                }
            }
            if selecting {
                if placement.item.kind == .folder {
                    Button(action: toggleFolder) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "Collapse folder" : "Expand folder")
                    .disabled(busy)
                }
            }
            if showsActions {
                Menu {
                    if placement.item.isTrashed {
                        Button("Restore", action: restore)
                            .accessibilityIdentifier(
                                "notebook-trash-restore-" + placement.item.id.uuidString
                            )
                    } else {
                        Text("Restore the parent folder, or move this item out.")
                    }
                    Button("Move…", action: move)
                    Divider()
                    Button("Delete Permanently…", role: .destructive, action: delete)
                } label: {
                    Label("Trash Actions", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .accessibilityIdentifier("notebook-trash-actions-" + placement.item.id.uuidString)
                .disabled(busy)
            }
        }
        .padding(.leading, CGFloat(depth) * 16)
    }

    private var showsActions: Bool {
        #if os(macOS)
        true
        #else
        !selecting
        #endif
    }

    private var rowLabel: some View {
        HStack(spacing: 8) {
            if !selecting, placement.item.kind == .folder {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
            }
            Label(title, systemImage: placement.item.kind == .folder ? "folder" : "note.text")
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private var title: String {
        placement.item.kind == .note
            ? NotebookNoteName.title(from: placement.displayName)
            : placement.displayName
    }

    private var itemIdentifier: String {
        (placement.item.kind == .note
            ? "notebook-sidebar-note-" : "notebook-sidebar-folder-")
            + placement.item.id.uuidString
    }
}

private struct NotebookTrashEmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "trash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Trash is empty")
                .font(.headline)
            Text("Items you move to Trash appear here until you restore or delete them.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("notebook-trash-empty")
    }
}

private struct NotebookTrashDestination: Identifiable {
    let id: UUID
    let path: String
}

private struct NotebookTrashMoveView: View {
    let destinations: [NotebookTrashDestination]
    @Binding var destination: UUID?
    let busy: Bool
    let cancel: () -> Void
    let move: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Picker("Destination", selection: $destination) {
                    Text("Notebook root").tag(nil as UUID?)
                    ForEach(destinations) { destination in
                        Text(destination.path).tag(destination.id as UUID?)
                    }
                }
                .accessibilityIdentifier("notebook-move-destination")
            }
            .navigationTitle("Move Item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move", action: move)
                        .disabled(busy)
                        .accessibilityIdentifier("notebook-confirm-move")
                }
            }
        }
        .frame(minWidth: 300, minHeight: 220)
        .interactiveDismissDisabled(busy)
    }
}
