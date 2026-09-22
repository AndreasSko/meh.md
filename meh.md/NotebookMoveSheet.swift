import NoteCore
import SwiftUI

struct NotebookMoveSheet: View {
    let placements: [NotebookPlacement]
    let sourceIDs: [UUID]
    let isDestinationAllowed: (UUID?) -> Bool
    let onSubmit: (UUID?) async throws -> Void
    let onSuccess: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var path: [UUID]
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    init(
        placements: [NotebookPlacement], sourceIDs: [UUID],
        initialParentID: UUID?,
        isDestinationAllowed: @escaping (UUID?) -> Bool,
        onSubmit: @escaping (UUID?) async throws -> Void,
        onSuccess: @escaping () -> Void
    ) {
        self.placements = placements
        self.sourceIDs = sourceIDs
        self.isDestinationAllowed = isDestinationAllowed
        self.onSubmit = onSubmit
        self.onSuccess = onSuccess
        _path = State(
            initialValue: Self.initialPath(
                to: initialParentID,
                placements: placements,
                isDestinationAllowed: isDestinationAllowed
            )
        )
    }

    var body: some View {
        NavigationStack {
            NotebookMoveDestinationLevel(
                folders: childFolders(of: path.last),
                sourceSummary: sourceSummary,
                path: displayPath(to: path.last),
                canGoUp: !path.isEmpty,
                onOpenFolder: { folderID in
                    path.append(folderID)
                    errorMessage = nil
                },
                onGoUp: {
                    _ = path.popLast()
                    errorMessage = nil
                },
                isSubmitting: isSubmitting,
                errorMessage: errorMessage
            )
            .disabled(isSubmitting)
            .navigationTitle(sourceIDs.count == 1 ? "Move Item" : "Move Items")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                        .accessibilityIdentifier("notebook-cancel-move")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move Here", action: submit)
                        .disabled(isSubmitting || !isDestinationAllowed(path.last))
                        .accessibilityIdentifier("notebook-confirm-move")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, idealWidth: 440, minHeight: 360, idealHeight: 520)
        #endif
        .interactiveDismissDisabled(isSubmitting)
        .accessibilityIdentifier("notebook-move-sheet")
    }

    private var sourceSummary: String {
        guard sourceIDs.count == 1, let sourceID = sourceIDs.first,
              let placement = placements.first(where: { $0.item.id == sourceID })
        else { return "\(sourceIDs.count) items" }
        return placement.displayName
    }

    private func childFolders(of parentID: UUID?) -> [NotebookMoveFolder] {
        placements.compactMap { placement in
            guard placement.parentID == parentID,
                  placement.item.kind == .folder,
                  !placement.isInTrash,
                  isDestinationAllowed(placement.item.id)
            else { return nil }
            return NotebookMoveFolder(
                id: placement.item.id,
                name: placement.displayName
            )
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame
                ? $0.id.uuidString < $1.id.uuidString
                : order == .orderedAscending
        }
    }

    private func displayPath(to parentID: UUID?) -> String {
        let byID = Dictionary(uniqueKeysWithValues: placements.map {
            ($0.item.id, $0)
        })
        var names: [String] = []
        var nextID = parentID
        var visited = Set<UUID>()
        while let id = nextID, visited.insert(id).inserted,
              let placement = byID[id] {
            names.append(placement.displayName)
            nextID = placement.parentID
        }
        return (["Notebook"] + Array(names.reversed())).joined(separator: " / ")
    }

    private func submit() {
        guard !isSubmitting else { return }
        let destination = path.last
        guard isDestinationAllowed(destination) else { return }
        isSubmitting = true
        errorMessage = nil
        Task { @MainActor in
            do {
                try await onSubmit(destination)
                onSuccess()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSubmitting = false
            }
        }
    }

    private static func initialPath(
        to parentID: UUID?, placements: [NotebookPlacement],
        isDestinationAllowed: (UUID?) -> Bool
    ) -> [UUID] {
        guard let parentID else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: placements.map {
            ($0.item.id, $0)
        })
        var result: [UUID] = []
        var nextID: UUID? = parentID
        var visited = Set<UUID>()
        while let id = nextID {
            guard visited.insert(id).inserted,
                  let placement = byID[id],
                  placement.item.kind == .folder,
                  !placement.isInTrash,
                  isDestinationAllowed(id)
            else { return [] }
            result.append(id)
            nextID = placement.parentID
        }
        return Array(result.reversed())
    }
}

private struct NotebookMoveFolder: Identifiable {
    let id: UUID
    let name: String
}

private struct NotebookMoveDestinationLevel: View {
    let folders: [NotebookMoveFolder]
    let sourceSummary: String
    let path: String
    let canGoUp: Bool
    let onOpenFolder: (UUID) -> Void
    let onGoUp: () -> Void
    let isSubmitting: Bool
    let errorMessage: String?

    var body: some View {
        List {
            Section("Moving") {
                HStack {
                    Label(sourceSummary, systemImage: "arrow.right")
                        .accessibilityIdentifier("notebook-move-source")
                    if isSubmitting {
                        Spacer()
                        ProgressView()
                            .accessibilityLabel("Moving items")
                            .accessibilityIdentifier("notebook-move-progress")
                    }
                }
            }
            Section("Current location") {
                Label(path, systemImage: "folder")
                    .accessibilityIdentifier("notebook-move-path")
                if canGoUp {
                    Button(action: onGoUp) {
                        Label("Up one level", systemImage: "arrow.up")
                    }
                    .accessibilityIdentifier("notebook-move-up")
                }
            }
            Section("Folders") {
                if folders.isEmpty {
                    Text("No folders here")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(folders) { folder in
                        Button {
                            onOpenFolder(folder.id)
                        } label: {
                            HStack {
                                Label {
                                    Text(folder.name)
                                        .foregroundStyle(.primary)
                                } icon: {
                                    Image(systemName: "folder")
                                        .foregroundStyle(.tint)
                                }
                                Spacer()
                                Image(systemName: "chevron.forward")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                        }
                        .accessibilityIdentifier(
                            "notebook-move-folder-" + folder.id.uuidString
                        )
                    }
                }
            }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("notebook-move-error")
                }
            }
        }
    }
}
