import Foundation
import NoteCore
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

private struct NotebookSidebarRow: Identifiable {
    let placement: NotebookPlacement
    let depth: Int
    var id: UUID { placement.item.id }
}

struct NotebookView: View {
    let replica: NotebookReplica
    var workspace: NotebookWorkspace? = nil
    @State private var selectedID: UUID?
    @State private var session: NoteSession?
    @State private var expandedIDs: Set<UUID> = []
    @State private var trashExpanded = false
    @State private var busy = false
    @State private var editorNavigation = MarkdownEditorNavigation()
    @State private var errorMessage: String?
    @State private var unrecordedEdit = false
    @State private var editingID: UUID?
    @State private var originalName = ""
    @State private var proposedName = ""
    @FocusState private var focusedNameID: UUID?
    @State private var movingItem: NotebookPlacement?
    @State private var destination: UUID?
    @State private var preferredCompactColumn = NavigationSplitViewColumn.sidebar

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    Section("Notebook") {
                        ForEach(activeRows) { row in sidebarRow(row) }
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

                        if trashExpanded {
                            ForEach(trashRows) { row in sidebarRow(row) }
                        }
                    }
                }
                .padding(10)
            }
            .contextMenu { creationActions(parentID: nil) }
            .navigationTitle("meh.md")
            .navigationSplitViewColumnWidth(min: 220, ideal: 280)
            .toolbar {
                ToolbarItem {
                    Menu {
                        creationActions(parentID: nil)
                    } label: {
                        Label("New", systemImage: "plus")
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("notebook-new-item")
                }
            }
        } detail: {
            Group {
                if let session, let selectedID {
                    NotebookNoteEditor(
                        session: session, navigation: editorNavigation,
                        isInTrash: selectedPlacement?.isInTrash == true,
                        hasUnrecordedEdit: $unrecordedEdit,
                        onPersist: { workspace?.contentDidSave() }
                    )
                    .id(selectedID)
                    .navigationTitle(selectedPlacement?.displayName ?? "Note")
                    .toolbar {
                        if let placement = selectedPlacement {
                            ToolbarItem {
                                Menu {
                                    actions(for: placement)
                                } label: {
                                    Label("Note Actions", systemImage: "ellipsis.circle")
                                }
                                .accessibilityIdentifier("notebook-note-actions")
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("Select a note", systemImage: "note.text")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let workspace { NotebookWorkspaceStatusView(workspace: workspace) }
        }
        .onChange(of: replica.catalogSnapshot) { _, _ in workspace?.contentDidSave() }
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
    private func actions(for placement: NotebookPlacement) -> some View {
        if !placement.isInTrash {
            creationActions(parentID: creationParent(for: placement))
            Divider()
        }
        Button("Rename…") { beginRenaming(placement) }
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
                let id = try await replica.createNote(name: "Untitled.md", parentID: parentID)
                try await selectNote(id, revealDetail: false)
                beginRenaming(id: id, name: "Untitled.md")
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

    private func submitInlineName() {
        perform { try await commitInlineNameIfNeeded() }
    }

    private func commitInlineNameIfNeeded() async throws {
        guard let id = editingID else { return }
        let placement = replica.placements.first { $0.item.id == id }
        let name =
            placement?.item.kind == .note
            ? NotebookDisplayName.noteName(proposedName) : proposedName
        try await replica.rename(id, to: name)
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

    private func flushEditor() async throws {
        try await commitInlineNameIfNeeded()
        // Unavailable notes have no editable buffer to flush. They must not
        // trap navigation while the user chooses whether to recover them.
        guard session?.isEditingEnabled == true else { return }
        guard editorNavigation.prepareToLeave?() != false, !unrecordedEdit else {
            throw NotebookNavigationError.unrecordedEdit
        }
        try await session?.flush()
    }

    private func selectNote(_ id: UUID, revealDetail: Bool = true) async throws {
        if id != selectedID {
            try await flushEditor()
            session = try await replica.openNote(id, allowingRecovery: true)
            selectedID = id
        } else if editingID != nil {
            try await flushEditor()
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
                }
            }
        }
    }
}

enum NotebookDisplayName {
    static func noteName(_ proposedName: String) -> String {
        if proposedName == "." || proposedName == ".."
            || proposedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return proposedName
        }
        let lowercased = proposedName.lowercased()
        if lowercased.hasSuffix(".md") || lowercased.hasSuffix(".markdown") {
            return proposedName
        }
        return proposedName + ".md"
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
