import NoteCore
import SwiftUI

struct NotebookSharedImportView: View {
    let plan: NotebookImportPlan
    let replica: NotebookReplica
    let onImport: (UUID?) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path: [UUID] = []
    @State private var importing = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack(path: $path) {
            destinationLevel(nil)
                .navigationDestination(for: UUID.self) { id in
                    destinationLevel(id)
                }
        }
        #if os(macOS)
        .frame(minWidth: 360, idealWidth: 440, minHeight: 360, idealHeight: 520)
        #endif
        .interactiveDismissDisabled(importing)
    }

    private func destinationLevel(_ parentID: UUID?) -> some View {
        List {
            Section("Importing") {
                ForEach(roots) { entry in
                    Label(entry.name, systemImage: entry.kind == .folder ? "folder" : "doc.text")
                }
                if !plan.skippedPaths.isEmpty {
                    Text("\(plan.skippedPaths.count) items will be skipped. Only visible Markdown files and ordinary folders are imported.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Choose a Folder") {
                ForEach(childFolders(parentID), id: \.item.id) { folder in
                    NavigationLink(value: folder.item.id) {
                        Label(folder.displayName, systemImage: "folder")
                    }
                }
                if childFolders(parentID).isEmpty {
                    Text("Save here, or go back to choose another folder.")
                        .foregroundStyle(.secondary)
                }
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .disabled(importing)
        .navigationTitle(parentID.flatMap { id in
            replica.placements.first { $0.item.id == id }?.displayName
        } ?? "Notebook")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(importing)
            }
            ToolbarItem(placement: .confirmationAction) {
                if importing {
                    ProgressView().accessibilityLabel("Importing Markdown")
                } else {
                    Button("Save Here") { save(parentID) }
                        .disabled(!isValidDestination(parentID))
                        .accessibilityIdentifier("notebook-save-shared-import")
                }
            }
        }
        .accessibilityIdentifier("notebook-shared-import-destination")
    }

    private var roots: [SharedImportRoot] {
        plan.entries.filter { $0.parentID == nil }.map {
            SharedImportRoot(id: $0.id, name: $0.name, kind: $0.kind)
        }
    }

    private func childFolders(_ parentID: UUID?) -> [NotebookPlacement] {
        replica.orderedChildren(parentID: parentID).filter {
            $0.item.kind == .folder && !$0.isInTrash
        }
    }

    private func isValidDestination(_ id: UUID?) -> Bool {
        guard let id else { return true }
        return replica.placements.contains {
            $0.item.id == id && $0.item.kind == .folder && !$0.isInTrash
        }
    }

    private func save(_ parentID: UUID?) {
        guard !importing, isValidDestination(parentID) else { return }
        importing = true
        errorMessage = nil
        Task { @MainActor in
            do {
                try await onImport(parentID)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                importing = false
            }
        }
    }
}

private struct SharedImportRoot: Identifiable {
    let id: UUID
    let name: String
    let kind: NotebookItemKind
}
