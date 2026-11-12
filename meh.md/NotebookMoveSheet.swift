import NoteCore
import SwiftUI

struct NotebookMoveSheet: View {
    let placements: [NotebookPlacement]
    let sourceIDs: [UUID]
    /// The folder new notes go to, shown with the same tray icon as in Files.
    let newNoteFolderID: UUID?
    let isDestinationAllowed: (UUID?) -> Bool
    /// True when moving there would change nothing, as `commitMove` decides.
    let isCurrentLocation: (UUID?) -> Bool
    let onSubmit: (UUID?) async throws -> Void
    let onSuccess: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var path: [UUID]
    @State private var query = ""
    @State private var isSearching = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    private let startPath: [UUID]
    private let recentFolders: [NotebookFolderShortcut]
    private let allowedFolderIDs: Set<UUID>

    init(
        placements: [NotebookPlacement], sourceIDs: [UUID],
        initialParentID: UUID?, newNoteFolderID: UUID? = nil,
        recentFolderIDs: [UUID] = [],
        isDestinationAllowed: @escaping (UUID?) -> Bool,
        isCurrentLocation: @escaping (UUID?) -> Bool = { _ in false },
        onSubmit: @escaping (UUID?) async throws -> Void,
        onSuccess: @escaping () -> Void
    ) {
        self.placements = placements
        self.sourceIDs = sourceIDs
        self.newNoteFolderID = newNoteFolderID
        self.isDestinationAllowed = isDestinationAllowed
        self.isCurrentLocation = isCurrentLocation
        self.onSubmit = onSubmit
        self.onSuccess = onSuccess
        let allowed = Set(placements.lazy.filter {
            $0.item.kind == .folder && !$0.isInTrash
        }.map(\.item.id).filter { isDestinationAllowed($0) })
        allowedFolderIDs = allowed
        recentFolders = NotebookFolderSearch.shortcuts(
            for: recentFolderIDs, in: placements, isAllowed: allowed.contains)
        let start = Self.path(
            to: initialParentID,
            placements: placements,
            isDestinationAllowed: isDestinationAllowed
        )
        startPath = start
        _path = State(initialValue: start)
    }

    var body: some View {
        NavigationStack {
            Group {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    NotebookMoveDestinationLevel(
                        folders: childFolders(of: path.last),
                        recentFolders: path == startPath ? recentFolders : [],
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
                        onOpenShortcut: open,
                        isSubmitting: isSubmitting,
                        errorMessage: errorMessage
                    )
                } else {
                    NotebookMoveSearchResults(
                        folders: NotebookFolderSearch.matches(
                            query, in: placements, isAllowed: allowedFolderIDs.contains),
                        query: query,
                        onOpen: open
                    )
                }
            }
            .searchable(text: $query, isPresented: $isSearching, prompt: "Find a folder")
            .disabled(isSubmitting)
            .navigationTitle(sourceIDs.count == 1 ? "Move Item" : "Move Items")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                        .accessibilityIdentifier("notebook-cancel-move")
                }
                ToolbarItem(placement: .confirmationAction) {
                    // While searching, the sheet hides where Move Here
                    // would go, so pick a result first.
                    Button("Move Here", action: submit)
                        .disabled(isSubmitting || !isDestinationAllowed(path.last)
                            || isCurrentLocation(path.last)
                            || !query.trimmingCharacters(in: .whitespaces).isEmpty)
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
        return placement.item.kind == .note
            ? NotebookNoteName.title(from: placement.displayName) : placement.displayName
    }

    /// Shows a folder picked from search or Recent. Move Here still confirms.
    private func open(_ folderID: UUID) {
        path = Self.path(to: folderID, placements: placements,
                         isDestinationAllowed: isDestinationAllowed)
        query = ""
        isSearching = false
        errorMessage = nil
    }

    /// Folders in the same order as Files.
    private func childFolders(of parentID: UUID?) -> [NotebookMoveFolder] {
        NotebookOrdering.orderedChildren(placements, parentID: parentID, inTrash: false).compactMap { placement in
            guard placement.item.kind == .folder,
                  allowedFolderIDs.contains(placement.item.id)
            else { return nil }
            return NotebookMoveFolder(
                id: placement.item.id,
                name: placement.displayName,
                systemImage: placement.item.id == newNoteFolderID ? "tray" : "folder"
            )
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
        return (["Top Level"] + Array(names.reversed())).joined(separator: " / ")
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

    private static func path(
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
    let systemImage: String
}

private struct NotebookMoveDestinationLevel: View {
    let folders: [NotebookMoveFolder]
    let recentFolders: [NotebookFolderShortcut]
    let sourceSummary: String
    let path: String
    let canGoUp: Bool
    let onOpenFolder: (UUID) -> Void
    let onGoUp: () -> Void
    let onOpenShortcut: (UUID) -> Void
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
            if !recentFolders.isEmpty {
                Section("Recent") {
                    ForEach(recentFolders) { folder in
                        NotebookFolderShortcutButton(folder: folder) {
                            onOpenShortcut(folder.id)
                        }
                        .accessibilityIdentifier(
                            "notebook-move-recent-" + folder.id.uuidString)
                    }
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
                                    Image(systemName: folder.systemImage)
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

/// Folders whose name or path matches the search.
private struct NotebookMoveSearchResults: View {
    let folders: [NotebookFolderShortcut]
    let query: String
    let onOpen: (UUID) -> Void

    var body: some View {
        if folders.isEmpty {
            ContentUnavailableView {
                Label {
                    Text("No folder matches “\(query)”")
                } icon: {
                    MehFace(mood: .puzzled)
                }
            }
            .accessibilityIdentifier("notebook-move-search-empty")
        } else {
            List {
                Section("Folders") {
                    ForEach(folders) { folder in
                        NotebookFolderShortcutButton(folder: folder) { onOpen(folder.id) }
                            .accessibilityIdentifier(
                                "notebook-move-search-result-" + folder.id.uuidString)
                    }
                }
            }
        }
    }
}

/// A folder with the path above it, which opens that folder in the sheet.
private struct NotebookFolderShortcutButton: View {
    let folder: NotebookFolderShortcut
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folder.name)
                            .foregroundStyle(.primary)
                        Text((["Top Level"] + folder.ancestors).joined(separator: " / "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
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
    }
}
