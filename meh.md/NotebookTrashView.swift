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

    @State private var expandedFolderIDs: Set<UUID> = []
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var movingID: UUID?
    @State private var destination: UUID?
    @State private var deletionSelection: NotebookDeletionSelection?

    var body: some View {
        Group {
            if trashRows.isEmpty {
                NotebookTrashEmptyState()
            } else {
                List(trashRows) { row in
                    NotebookTrashItemRow(
                        placement: row.placement,
                        depth: row.depth,
                        isExpanded: expandedFolderIDs.contains(row.id),
                        busy: busy,
                        toggleFolder: { toggleFolder(row.id) },
                        openNote: { onOpenNote(row.id) },
                        restore: { restore(row.placement) },
                        move: { beginMoving(row.placement) },
                        delete: { preparePermanentDeletion(rootID: row.id) }
                    )
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Trash")
        .accessibilityIdentifier("notebook-trash-view")
        .interactiveDismissDisabled(busy)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Empty Trash…", role: .destructive) {
                    preparePermanentDeletion(rootID: nil)
                }
                .disabled(busy || trashRows.isEmpty)
                .accessibilityIdentifier("notebook-empty-trash")
            }
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
            deletionSelection?.rootID == nil ? "Empty Trash?" : "Delete permanently?",
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
            deletionSelection = try replica.deletionSelection(rootID: rootID)
        }
    }

    private func permanentlyDelete(_ selection: NotebookDeletionSelection) {
        deletionSelection = nil
        perform {
            try await beforeMutation()
            try await replica.permanentlyDelete(selection)
            expandedFolderIDs.subtract(selection.ids)
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
    let toggleFolder: () -> Void
    let openNote: () -> Void
    let restore: () -> Void
    let move: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: placement.item.kind == .folder ? toggleFolder : openNote) {
                HStack(spacing: 8) {
                    if placement.item.kind == .folder {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                    }
                    Label(title, systemImage: placement.item.kind == .folder
                        ? "folder" : "note.text")
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .accessibilityIdentifier(itemIdentifier)
            .contextMenu {
                if placement.item.isTrashed { Button("Restore", action: restore) }
                Button("Move…", action: move)
                Divider()
                Button("Delete Permanently…", role: .destructive, action: delete)
            }
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
        .padding(.leading, CGFloat(depth) * 16)
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
