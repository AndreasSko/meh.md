import Foundation
import NoteCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A folder shown as a place: on iPhone a screen in Files, beside Files the
/// big side of the window.
struct NotebookFolderRoute: Hashable {
    let id: UUID
}

struct NotebookFolderPage: View {
    let scene: NotebookSceneState
    let folderID: UUID
    /// A screen in iPhone's Files rather than the big side beside Files.
    let isCompact: Bool
    @State private var selection: Set<UUID> = []
    @State private var isSelecting = false

    private var folder: NotebookPlacement? {
        scene.replica.placements.first { $0.item.id == folderID }
    }

    private var children: [NotebookPlacement] {
        scene.replica.orderedChildren(parentID: folderID)
    }

    private var view: NotebookFolderView { scene.navigationState.folderView(folderID) }

    var body: some View {
        Group {
            if let folder {
                content(folder)
            } else {
                MehStyle.paperColor
            }
        }
        .background(MehStyle.paperColor.ignoresSafeArea())
        // Beside Files the page shows its own large title.
        .navigationTitle(isCompact ? folder?.displayName ?? "" : "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, Binding(
            get: { isSelecting ? .active : .inactive },
            set: { isSelecting = $0.isEditing }
        ))
        #endif
        .toolbar { toolbar }
        .onChange(of: children.map(\.item.id)) { _, ids in
            selection.formIntersection(ids)
        }
        .onChange(of: folderID) { _, _ in endSelecting() }
        .accessibilityIdentifier("notebook-folder-page")
    }

    @ViewBuilder
    private func content(_ folder: NotebookPlacement) -> some View {
        if view == .cards {
            NotebookFolderCards(
                scene: scene, folderID: folderID, isCompact: isCompact, children: children,
                header: header(folder), selection: $selection, isSelecting: isSelecting,
                open: open
            )
        } else {
            NotebookFolderList(
                scene: scene, folderID: folderID, isCompact: isCompact, children: children,
                header: header(folder), selection: $selection, isSelecting: isSelecting,
                open: open
            )
        }
    }

    private func header(_ folder: NotebookPlacement) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            NotebookPathLine(
                scene: scene, folderIDs: scene.folderChain(to: folder.parentID),
                isCompact: isCompact
            )
            Text(folder.displayName)
                .font(.largeTitle.weight(.bold))
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("notebook-folder-page-title")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // A Mac list row would otherwise read its parts as one element.
        .accessibilityElement(children: .contain)
    }

    private func open(_ placement: NotebookPlacement) {
        guard !scene.busy, scene.editingID != placement.item.id else { return }
        let id = placement.item.id
        let isFolder = placement.item.kind == .folder
        if isFolder, scene.editingID == nil {
            scene.openFolderPage(id, fromPage: true)
            return
        }
        // As in Files, a pending name is saved first; if that fails, its
        // field stays.
        scene.perform { [scene] in
            try await scene.commitInlineNameIfNeeded()
            if !isFolder { try await scene.selectNote(id) }
        } onSuccess: { [scene] in
            if isFolder { scene.openFolderPage(id, fromPage: true) }
        }
    }

    private func endSelecting() {
        isSelecting = false
        selection = []
    }

    private var selectedIDs: [UUID] {
        children.map(\.item.id).filter(selection.contains)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: endSelecting)
                    .accessibilityIdentifier("notebook-folder-page-done")
            }
            if !isCompact { ToolbarItem { closeButton } }
            #if os(iOS)
            ToolbarItem(placement: .bottomBar) { moveButton }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Text("\(selection.count) selected").font(.headline)
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) { trashButton }
            #else
            ToolbarItemGroup {
                moveButton
                trashButton
            }
            #endif
        } else {
            ToolbarItem {
                Picker("View", selection: Binding(
                    get: { view },
                    set: { scene.navigationState.setFolderView($0, for: folderID) }
                )) {
                    Label("List", systemImage: "list.bullet")
                        .accessibilityLabel("List")
                        .tag(NotebookFolderView.list)
                    Label("Cards", systemImage: "square.grid.2x2")
                        .accessibilityLabel("Cards")
                        .tag(NotebookFolderView.cards)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityIdentifier("notebook-folder-view")
            }
            // The switch brings its own track; a shared glass capsule around
            // it would draw a second one.
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed)
            ToolbarItem { actionsMenu }
            if !isCompact { ToolbarItem { closeButton } }
            #if os(iOS)
            if isCompact {
                // The page shows its title, as a note does; the bar keeps it
                // only for the Back menu.
                ToolbarItem(placement: .principal) {
                    Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) { NotebookLibraryNewNote(scene: scene) }
                    .sharedBackgroundVisibility(.hidden)
            } else if scene.columnVisibility == .detailOnly {
                ToolbarItem { NotebookLibraryNewNote(scene: scene) }
                    .sharedBackgroundVisibility(.hidden)
            }
            #endif
        }
    }

    private var closeButton: some View {
        Button {
            scene.closeFolderPage()
        } label: {
            Label("Close", systemImage: "xmark")
        }
        .keyboardShortcut(.cancelAction)
        .help("Close the folder and return to the note")
        .accessibilityIdentifier("notebook-folder-page-close")
    }

    private var actionsMenu: some View {
        Menu {
            Button("New Note", systemImage: "square.and.pencil") {
                scene.createItem(kind: .note, parentID: folderID)
            }
            Button("New Folder", systemImage: "folder.badge.plus") {
                scene.createItem(kind: .folder, parentID: folderID)
            }
            NotebookTemplateCreationButton(scene: scene)
            Divider()
            Button("Select", systemImage: "checkmark.circle") {
                selection = []
                isSelecting = true
            }
            .disabled(children.isEmpty)
            .accessibilityIdentifier("notebook-folder-page-select")
            NotebookSortMenu(scene: scene, parentID: folderID)
        } label: {
            Label("Folder Actions", systemImage: "ellipsis")
        }
        .disabled(scene.busy)
        .accessibilityIdentifier("notebook-folder-page-actions")
    }

    private var moveButton: some View {
        Button {
            scene.beginMoving(selectedIDs)
            endSelecting()
        } label: {
            Label("Move…", systemImage: "arrow.forward.folder")
        }
        .disabled(scene.busy || selection.isEmpty)
        .accessibilityIdentifier("notebook-folder-page-move")
    }

    private var trashButton: some View {
        Button(role: .destructive) {
            scene.trashItems(selectedIDs)
            endSelecting()
        } label: {
            Label("Trash", systemImage: "trash")
        }
        .labelStyle(.titleAndIcon)
        .disabled(scene.busy || selection.isEmpty)
        .accessibilityIdentifier("notebook-folder-page-trash")
    }
}

/// "Top Level › Projects › Lisbon trip" above a folder's or note's title.
/// Each part opens that folder's page. Beside Files, the sidebar already is
/// Top Level, so the path starts at the first folder there.
struct NotebookPathLine: View {
    let scene: NotebookSceneState
    let folderIDs: [UUID]
    let isCompact: Bool

    var body: some View {
        let names = Dictionary(uniqueKeysWithValues: scene.replica.placements
            .filter { folderIDs.contains($0.item.id) }
            .map { ($0.item.id, $0.displayName) })
        let parts: [(id: UUID?, name: String)] = (isCompact ? [(nil, String(localized: "Top Level"))] : [])
            + folderIDs.map { (Optional($0), names[$0] ?? "") }
        if !parts.isEmpty {
            ViewThatFits(in: .horizontal) {
                line(parts)
                line(Array(parts.suffix(2)), hiding: Array(parts.dropLast(2)))
                line(Array(parts.suffix(1)), hiding: Array(parts.dropLast(1)))
            }
            .font(.subheadline)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Folder path")
            .accessibilityIdentifier("notebook-path-line")
        }
    }

    /// A path too long for the line shows its end; "…" lists the folders it
    /// hides, Top Level included.
    private func line(
        _ parts: [(id: UUID?, name: String)], hiding hidden: [(id: UUID?, name: String)] = []
    ) -> some View {
        HStack(spacing: 4) {
            if !hidden.isEmpty {
                Menu {
                    ForEach(Array(hidden.enumerated().reversed()), id: \.offset) { _, part in
                        Button(part.name) { open(part) }
                    }
                } label: {
                    Text("…").foregroundStyle(.secondary)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(scene.busy)
                .accessibilityLabel("Folders above")
                .accessibilityIdentifier("notebook-path-more")
                separator
            }
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 { separator }
                Button(part.name) { open(part) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .disabled(scene.busy)
                .accessibilityIdentifier("notebook-path-" + (part.id?.uuidString ?? "top-level"))
            }
        }
    }

    private func open(_ part: (id: UUID?, name: String)) {
        if let id = part.id { scene.openFolderPage(id) } else { scene.openTopLevel() }
    }

    private var separator: some View {
        Image(systemName: "chevron.forward")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

/// A folder's notes and folders as rows, notes with their first words.
private struct NotebookFolderList<Header: View>: View {
    let scene: NotebookSceneState
    let folderID: UUID
    let isCompact: Bool
    let children: [NotebookPlacement]
    let header: Header
    @Binding var selection: Set<UUID>
    let isSelecting: Bool
    let open: (NotebookPlacement) -> Void

    var body: some View {
        List(selection: $selection) {
            header
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .selectionDisabled()
                .padding(.bottom, 8)
            if children.isEmpty {
                NotebookFolderEmpty()
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .selectionDisabled()
            } else {
                ForEach(children, id: \.item.id) { placement in
                    NotebookFolderRow(scene: scene, placement: placement, isCompact: isCompact)
                        #if os(macOS)
                        // As in Files, a plain click opens; ⌘ and ⇧ select.
                        .simultaneousGesture(TapGesture().onEnded {
                            guard !isSelecting, !NotebookFolderList.isSelectingClick else { return }
                            selection = [placement.item.id]
                            open(placement)
                        })
                        #endif
                        .notebookDragSource(enabled: scene.editingID == nil) {
                            scene.beginBrowserDrag(placement.item.id, selection: Array(selection))
                        }
                        .tag(placement.item.id)
                        .listRowSeparator(.hidden)
                        .listRowBackground(rowBackground(placement.item.id))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if !isSelecting, scene.editingID == nil {
                                Button(role: .destructive) {
                                    scene.trashItems([placement.item.id])
                                } label: {
                                    Label("Trash", systemImage: "trash")
                                }
                            }
                        }
                }
                NotebookLibraryFooter(noteCount: noteCount) { _ in }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .selectionDisabled()
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.horizontal, isCompact ? 8 : 24, for: .scrollContent)
        #if os(macOS)
        // As in Files, AppKit tracks the drag; the header is the first row.
        .overlay(NotebookPageDragReader(
            scene: scene, selection: $selection,
            source: { row in
                children.indices.contains(row - 1) ? children[row - 1].item.id : nil
            }))
        #endif
        .contextMenu(forSelectionType: UUID.self) { ids in
            if scene.editingID == nil, !isSelecting {
                if ids.count == 1, let id = ids.first,
                   let placement = children.first(where: { $0.item.id == id }) {
                    NotebookItemActions(scene: scene, placement: placement)
                } else if !ids.isEmpty {
                    Button("Move Selected…") { scene.beginMoving(Array(ids)) }
                    Button("Trash Selected", role: .destructive) {
                        scene.trashItems(Array(ids))
                    }
                }
            }
        } primaryAction: { ids in
            guard !isSelecting, !NotebookFolderList.isSelectingClick,
                  ids.count == 1, let id = ids.first,
                  let placement = children.first(where: { $0.item.id == id }) else { return }
            selection = []
            open(placement)
        }
        #if os(iOS)
        // A plain tap opens the row; only Select keeps rows selected.
        .onChange(of: selection) { _, ids in
            if !isSelecting, !ids.isEmpty { selection = [] }
        }
        #endif
    }

    private var noteCount: Int {
        children.count { $0.item.kind == .note }
    }

    /// A ⌘- or ⇧-click, which selects rows rather than opening one. The
    /// click's own flags count, not only keys held down right now.
    private static var isSelectingClick: Bool {
        #if os(macOS)
        let flags = (NSApp.currentEvent?.modifierFlags ?? []).union(NSEvent.modifierFlags)
        return !flags.intersection([.command, .shift]).isEmpty
        #else
        false
        #endif
    }

    private func rowBackground(_ id: UUID) -> Color {
        id == scene.selectedID && !isSelecting && isCompact == false
            ? NotebookSidebarPalette.openNote : .clear
    }
}

private struct NotebookFolderRow: View {
    let scene: NotebookSceneState
    let placement: NotebookPlacement
    let isCompact: Bool

    var body: some View {
        let id = placement.item.id
        let isFolder = placement.item.kind == .folder
        HStack(spacing: 12) {
            Group {
                if isFolder {
                    NotebookFolderIcon(
                        systemName: scene.replica.defaultNewNoteParentID == id ? "tray" : "folder")
                } else {
                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                }
            }
            .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                NotebookFolderItemName(scene: scene, placement: placement, isCompact: isCompact)
                if !isFolder {
                    Text(scene.filePreview(for: id) ?? " ")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("notebook-folder-page-preview-" + id.uuidString)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isFolder {
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, isFolder ? 6 : 4)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .onAppear { if !isFolder { scene.pageRowAppeared(id) } }
        .onDisappear { scene.pageRowDisappeared(id) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(
            (isFolder ? "notebook-folder-page-folder-" : "notebook-folder-page-note-")
                + id.uuidString)
    }
}

/// A note's or folder's name, or the name field while it is renamed. Beside
/// Files the sidebar shows that field, so the page keeps the name.
private struct NotebookFolderItemName: View {
    let scene: NotebookSceneState
    let placement: NotebookPlacement
    let isCompact: Bool
    var font: Font = .body.weight(.medium)
    @FocusState private var focused: Bool

    var body: some View {
        if isCompact, scene.editingID == placement.item.id {
            TextField("Name", text: Bindable(scene).proposedName)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { scene.submitInlineName() }
                .onAppear { focused = true }
                .accessibilityIdentifier("notebook-folder-page-name")
        } else {
            Text(placement.item.kind == .note
                ? NotebookNoteName.title(from: placement.displayName) : placement.displayName)
                .font(font)
                .lineLimit(1)
        }
    }
}

/// A folder's notes as small sheets of paper that show their first lines,
/// with its folders as tiles on top.
private struct NotebookFolderCards<Header: View>: View {
    @State private var frames = NotebookCardFrames()
    let scene: NotebookSceneState
    let folderID: UUID
    let isCompact: Bool
    let children: [NotebookPlacement]
    let header: Header
    @Binding var selection: Set<UUID>
    let isSelecting: Bool
    let open: (NotebookPlacement) -> Void

    var body: some View {
        let folders = children.filter { $0.item.kind == .folder }
        let notes = children.filter { $0.item.kind == .note }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if children.isEmpty {
                    NotebookFolderEmpty()
                }
                if !folders.isEmpty {
                    NotebookFlowLayout(spacing: 8) {
                        ForEach(folders, id: \.item.id) { folder in
                            NotebookFolderTile(
                                scene: scene, placement: folder, isCompact: isCompact,
                                isSelected: selection.contains(folder.item.id),
                                isSelecting: isSelecting
                            ) {
                                if isSelecting {
                                    if !selection.insert(folder.item.id).inserted {
                                        selection.remove(folder.item.id)
                                    }
                                } else {
                                    open(folder)
                                }
                            }
                            .notebookDragSource(enabled: scene.editingID == nil) {
                                scene.beginBrowserDrag(folder.item.id, selection: Array(selection))
                            }
                            .notebookCardFrame(folder.item.id, in: frames)
                        }
                    }
                }
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: isCompact ? 150 : 190), spacing: 14)],
                    spacing: 14
                ) {
                    ForEach(notes, id: \.item.id) { note in
                        NotebookNoteCard(
                            scene: scene, placement: note, isCompact: isCompact,
                            isSelected: selection.contains(note.item.id),
                            isSelecting: isSelecting,
                            isOpen: !isCompact && note.item.id == scene.selectedID
                        ) {
                            if isSelecting {
                                if !selection.insert(note.item.id).inserted {
                                    selection.remove(note.item.id)
                                }
                            } else {
                                open(note)
                            }
                        }
                        .notebookDragSource(enabled: scene.editingID == nil) {
                            scene.beginBrowserDrag(note.item.id, selection: Array(selection))
                        }
                        .notebookCardFrame(note.item.id, in: frames)
                        .contextMenu {
                            if !isSelecting {
                                NotebookItemActions(scene: scene, placement: note)
                            }
                        }
                    }
                }
                if !notes.isEmpty {
                    NotebookLibraryFooter(noteCount: notes.count) { _ in }
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, isCompact ? 20 : 32)
            .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
        #if os(macOS)
        .overlay(NotebookPageDragReader(
            scene: scene, selection: $selection,
            source: { _ in nil },
            sourceAtPoint: { point in frames.items.first { $0.value.contains(point) }?.key }))
        #endif
    }
}

/// Where each card and folder tile is in the window, for Mac drags.
private final class NotebookCardFrames {
    var items: [UUID: CGRect] = [:]
}

private struct NotebookFolderTile: View {
    let scene: NotebookSceneState
    let placement: NotebookPlacement
    let isCompact: Bool
    let isSelected: Bool
    let isSelecting: Bool
    let action: () -> Void

    var body: some View {
        let id = placement.item.id
        NotebookPageButton(
            isRenaming: isCompact && scene.editingID == id, action: action
        ) {
            HStack(spacing: 8) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                }
                NotebookFolderIcon(
                    systemName: scene.replica.defaultNewNoteParentID == id ? "tray" : "folder")
                NotebookFolderItemName(
                    scene: scene, placement: placement, isCompact: isCompact, font: .body)
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(.background.secondary, in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0)
            }
        }
        .contextMenu {
            if !isSelecting { NotebookItemActions(scene: scene, placement: placement) }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // Off while renamed; it would replace the name field's own.
        .accessibilityIdentifier(
            "notebook-folder-page-folder-" + id.uuidString,
            isEnabled: !(isCompact && scene.editingID == id))
    }
}

/// A note as a small sheet of paper with its first lines.
private struct NotebookNoteCard: View {
    let scene: NotebookSceneState
    let placement: NotebookPlacement
    let isCompact: Bool
    let isSelected: Bool
    let isSelecting: Bool
    let isOpen: Bool
    let action: () -> Void
    @State private var preview: NotebookNotePreview?

    var body: some View {
        let id = placement.item.id
        NotebookPageButton(
            isRenaming: isCompact && scene.editingID == id, action: action
        ) {
            VStack(alignment: .leading, spacing: 6) {
                NotebookFolderItemName(
                    scene: scene, placement: placement, isCompact: isCompact,
                    font: .subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.trailing, isSelecting ? 22 : 0)
                    .layoutPriority(1)
                NotebookCardText(markdown: preview?.text ?? "")
                    .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity,
                           alignment: .topLeading)
                    .clipped()
                    .mask(LinearGradient(
                        stops: [.init(color: .black, location: 0.7),
                                .init(color: .clear, location: 1)],
                        startPoint: .top, endPoint: .bottom))
                if let date = preview?.modifiedAt {
                    Text(date, format: .dateTime.month(.abbreviated).day())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .layoutPriority(1)
                }
            }
            .padding(12)
            .frame(height: 190, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NotebookSidebarPalette.recents, in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        isSelected ? Color.accentColor
                            : isOpen ? Color.secondary.opacity(0.6) : Color.primary.opacity(0.08),
                        lineWidth: isSelected ? 2.5 : 1)
            }
            .overlay(alignment: .topTrailing) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        .padding(8)
                }
            }
            .contentShape(.rect(cornerRadius: 14))
        }
        .task(id: NotebookCardSource(id, in: scene.replica.searchRevision)) {
            // A first load is immediate; refreshes wait until edits pause.
            if preview != nil {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
            preview = try? await scene.replica.notePreview(for: id, characterLimit: 600)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // Off while renamed; it would replace the name field's own.
        .accessibilityIdentifier(
            "notebook-folder-page-card-" + id.uuidString,
            isEnabled: !(isCompact && scene.editingID == id))
    }
}

/// The first lines of a note as they look in it: headings, list items and
/// tasks, without the Markdown signs.
private struct NotebookCardText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                switch line {
                case .heading(let text):
                    Text(text).font(.caption.weight(.semibold))
                case .task(let text, let done):
                    Label {
                        Text(text)
                    } icon: {
                        Image(systemName: done ? "checkmark.square.fill" : "square")
                    }
                    .labelStyle(NotebookCardLineLabelStyle())
                case .item(let text):
                    Label { Text(text) } icon: { Text("•") }
                        .labelStyle(NotebookCardLineLabelStyle())
                case .text(let text):
                    Text(text)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(3)
    }

    private enum Line {
        case heading(String)
        case task(String, done: Bool)
        case item(String)
        case text(String)
    }

    private var lines: [Line] {
        var result: [Line] = []
        var inFence = false
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle(); continue }
            if line.isEmpty || line.allSatisfy({ "-*_=|: ".contains($0) }) { continue }
            func plain(_ text: Substring) -> String {
                MarkdownExcerpt.plain(String(text)).text
            }
            if inFence {
                result.append(.text(line))
            } else if line.hasPrefix("#") {
                result.append(.heading(plain(line.drop { $0 == "#" || $0 == " " })))
            } else if let task = ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "* [x] "]
                .first(where: line.hasPrefix) {
                result.append(.task(plain(line.dropFirst(task.count)),
                                    done: task.contains("x") || task.contains("X")))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                result.append(.item(plain(line.dropFirst(2))))
            } else {
                result.append(.text(plain(Substring(line))))
            }
            if result.count == 9 { break }
        }
        return result
    }
}

private struct NotebookCardLineLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            configuration.icon
            configuration.title
        }
    }
}

private struct NotebookFolderEmpty: View {
    var body: some View {
        VStack(spacing: 8) {
            MehFace(mood: .neutral)
            Text("Nothing in here.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .accessibilityIdentifier("notebook-folder-page-empty")
    }
}

/// Places its views in rows, starting a new row when one is full.
private struct NotebookFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: bounds.minY + row.y),
                    proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
                x += min(size.width, bounds.width) + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let itemWidth = min(size.width, width)
            if !row.indices.isEmpty, row.width + spacing + itemWidth > width {
                rows.append(row)
                row = Row(y: row.y + row.height + spacing)
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + itemWidth
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// What a card's text was read from: an open note changes with its editor,
/// including edits sync applies to it, and a stored one with note bodies.
private enum NotebookCardSource: Equatable {
    case editor(Data)
    case stored(UInt64)

    init(_ id: UUID, in revision: NotebookSearchRevision) {
        self = revision.openNotes.first { $0.id == id }
            .map { .editor($0.revision) } ?? .stored(revision.bodyGeneration)
    }
}

private extension View {
    @ViewBuilder
    func notebookCardFrame(_ id: UUID, in frames: NotebookCardFrames) -> some View {
        #if os(macOS)
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            frames.items[id] = $0
        }
        .onDisappear { frames.items[id] = nil }
        #else
        self
        #endif
    }
}

#if os(macOS)
/// Drags a page's rows or cards onto a folder in Files, like Files' own
/// rows: a selected item takes the page's other selected items along.
private struct NotebookPageDragReader: View {
    let scene: NotebookSceneState
    @Binding var selection: Set<UUID>
    let source: (Int) -> UUID?
    var sourceAtPoint: ((CGPoint) -> UUID?)?

    var body: some View {
        NotebookBrowserAppKitDragReader(
            state: scene.browserDrag,
            canBegin: { !scene.busy && scene.editingID == nil && !scene.search.isPresented },
            sourceAt: { sourceAtPoint?($0) },
            selectSource: { id in
                if !selection.contains(id) { selection = [id] }
            },
            begin: { scene.beginBrowserDrag($0, selection: Array(selection)) },
            clickEmptySpace: { _ in },
            tracksOwnScrollView: true,
            sourceAtRow: sourceAtPoint == nil ? source : nil
        )
    }
}
#endif

/// A card or tile's tap. On the Mac a Button would track the mouse itself,
/// and the drag onto a folder in Files would never start. While it is
/// renamed, the name field stands on its own.
private struct NotebookPageButton<Label: View>: View {
    var isRenaming = false
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        if isRenaming {
            label
        } else {
            button
        }
    }

    @ViewBuilder
    private var button: some View {
        #if os(macOS)
        label
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            // Like a button, reachable with Tab when keyboard navigation
            // is on, and Space or Return opens it.
            .focusable(interactions: .activate)
            .onKeyPress(keys: [.space, .return]) { _ in
                action()
                return .handled
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, action)
        #else
        Button(action: action) { label }
            .buttonStyle(.plain)
        #endif
    }
}
