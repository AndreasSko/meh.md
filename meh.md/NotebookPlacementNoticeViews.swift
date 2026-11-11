import NoteCore
import SwiftUI

/// The highlighter mark beside an item the catalog flagged. It opens what
/// happened and the choices that settle it: a popover on Mac and iPad, a
/// sheet on iPhone.
struct NotebookNoticeMark: View {
    let scene: NotebookSceneState
    let placement: NotebookPlacement
    let notice: NotebookPlacementNotice
    /// Set inside the Files list, which presents the details itself from
    /// the mark's frame in window coordinates.
    var onOpen: ((CGRect) -> Void)? = nil
    @State private var frame: CGRect = .zero
    @State private var showingDetails = false
    /// Kept here rather than in the popover, whose content can be rebuilt
    /// while it's open.
    @State private var picked: NotebookPlacementNotice.Choice.Value?

    var body: some View {
        Button {
            if let onOpen { onOpen(frame) } else { showingDetails = true }
        } label: {
            NotebookNoticeMarkLabel(notice: notice)
        }
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
        } action: { frame = $0 }
        .buttonStyle(.borderless)
        .fixedSize()
        .help(notice.title)
        .accessibilityLabel(notice.title)
        .accessibilityHint("Shows how to settle it")
        .accessibilityIdentifier("notebook-notice-" + placement.item.id.uuidString)
        .popover(isPresented: $showingDetails) {
            NotebookNoticePopover(
                scene: scene, itemID: placement.item.id, picked: $picked,
                dismiss: { showingDetails = false })
        }
    }
}

/// Which item's details the Files list shows, and where its mark is.
struct NotebookNoticeRequest: Identifiable {
    let id: UUID
    let rect: CGRect
    var picked: NotebookPlacementNotice.Choice.Value?
}

/// The details for an item as it is now. They close once its flag is
/// settled, also when another device settles it.
struct NotebookNoticePopover: View {
    let scene: NotebookSceneState
    let itemID: UUID
    @Binding var picked: NotebookPlacementNotice.Choice.Value?
    let dismiss: () -> Void
    @State private var sheetHeight: CGFloat = 320

    var body: some View {
        if let placement = scene.replica.placements.first(where: { $0.item.id == itemID }),
           let notice = NotebookPlacementNotice(placement) {
            NotebookNoticeDetails(
                scene: scene, placement: placement, notice: notice, picked: $picked,
                dismiss: dismiss)
            #if os(iOS)
            // As tall as its content when it becomes a sheet on iPhone.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                sheetHeight = $0
            }
            .presentationDetents([.height(sheetHeight)])
            #endif
        } else {
            Color.clear.frame(width: 1, height: 1).onAppear(perform: dismiss)
        }
    }
}

/// The mark's look: a quick, slightly tilted highlighter stroke, like the
/// one under folders.
struct NotebookNoticeMarkLabel: View {
    let notice: NotebookPlacementNotice
    @Environment(\.mehPalette) private var palette

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: notice.symbol)
            Text(notice.mark)
        }
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .foregroundStyle(MehStyle.onHighlighterColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background {
            RoundedRectangle(cornerRadius: 4)
                .fill(palette.highlighterColor.opacity(0.85))
                .rotationEffect(.degrees(-1.5))
        }
        .contentShape(Rectangle())
        .fixedSize()
    }
}

/// What happened to a flagged item, and one tap to settle it.
struct NotebookNoticeDetails: View {
    let scene: NotebookSceneState
    let placement: NotebookPlacement
    let notice: NotebookPlacementNotice
    @Binding var picked: NotebookPlacementNotice.Choice.Value?
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("•_• ?")
                .font(.title2.weight(.bold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(notice.title)
                .font(.headline)
            Text(notice.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !choices.isEmpty {
                VStack(spacing: 6) {
                    ForEach(choices, id: \.value) { choice in
                        choiceRow(choice)
                    }
                }
            }
            actions
        }
        .padding(20)
        #if os(macOS)
        .frame(width: 320)
        #endif
        .accessibilityIdentifier("notebook-notice-details")
    }

    private var choices: [NotebookPlacementNotice.Choice] {
        notice.choices(in: scene.replica.placements)
    }

    private var selection: NotebookPlacementNotice.Choice? {
        NotebookPlacementNotice.selection(picked, in: choices)
    }

    private func choiceRow(_ choice: NotebookPlacementNotice.Choice) -> some View {
        let selected = choice.value == selection?.value
        return Button {
            picked = choice.value
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? .primary : .secondary)
                if case .parent = choice.value {
                    NotebookFolderIcon(systemName: "folder")
                }
                Text(choice.label)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if choice.isShown {
                    Text("Shown now")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        selected ? Color.primary : Color.secondary.opacity(0.3),
                        lineWidth: selected ? 1.5 : 1)
            }
            .foregroundStyle(.primary)
        }
        // A plain button inside a List row, as this popover's content is,
        // doesn't receive clicks on macOS.
        .buttonStyle(.borderless)
        .disabled(!choice.isAvailable)
        .opacity(choice.isAvailable ? 1 : 0.5)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 8) {
            switch notice.kind {
            case .names:
                if let selection, case .name(let name) = selection.value {
                    primary("Keep \u{201C}\(selection.label)\u{201D}") {
                        scene.keepName(name, for: placement.item.id)
                    }
                }
            case .folders:
                if let selection, case .parent(let parentID) = selection.value {
                    primary(parentID == nil ? "Keep at Top Level" : "Keep in \(selection.label)") {
                        scene.keepParent(parentID, for: placement.item.id)
                    }
                }
                // Also the way out when every folder it was moved to is gone.
                secondary("Move To\u{2026}") {
                    scene.beginMoving([placement.item.id])
                }
            case .folderLoop, .folderGone:
                primary("Keep Here") {
                    scene.keepParent(placement.parentID, for: placement.item.id)
                }
                secondary("Move To\u{2026}") {
                    scene.beginMoving([placement.item.id])
                }
            case .sameName:
                primary("Rename\u{2026}") {
                    scene.beginRenaming(placement)
                }
            }
            Button("Decide Later", action: dismiss)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("notebook-notice-later")
        }
        .padding(.top, 4)
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            dismiss()
            action()
        } label: {
            Text(title)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(scene.busy)
        .accessibilityIdentifier("notebook-notice-primary")
    }

    private func secondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            dismiss()
            action()
        } label: {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(scene.busy)
    }
}

/// Where a note was also moved to, in that folder's list: one tap moves it
/// there for good.
struct NotebookGhostRow: View {
    let scene: NotebookSceneState
    let placement: NotebookPlacement
    let parentID: UUID?
    let depth: Int
    @Environment(\.mehPalette) private var palette

    private var rowHeight: CGFloat {
        #if os(macOS)
        28
        #else
        44
        #endif
    }

    private var leading: CGFloat {
        #if os(macOS)
        12
        #else
        26
        #endif
    }

    private var title: String {
        placement.item.kind == .note
            ? NotebookNoteName.title(from: placement.displayName) : placement.displayName
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: placement.item.kind == .folder ? "folder" : "doc.text")
                .foregroundStyle(.secondary)
            Text(title)
                .italic()
                .foregroundStyle(.primary.opacity(0.75))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Move Here") {
                scene.keepParent(parentID, for: placement.item.id)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(scene.busy)
            .accessibilityIdentifier("notebook-ghost-move-" + placement.item.id.uuidString)
        }
        .padding(.leading, CGFloat(depth) * 16 + leading)
        .padding(.trailing, 6)
        .frame(minHeight: rowHeight)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(palette.highlighterColor.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            palette.highlighterColor,
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Also moved here: \(title)")
        .accessibilityIdentifier("notebook-ghost-" + placement.item.id.uuidString)
    }
}

/// A Files row, or a ghost of an item that was also moved into a folder.
/// Ghosts aren't items, so they can't be selected or dragged.
enum NotebookSidebarEntry: Identifiable {
    case row(NotebookSidebarRow)
    case ghost(NotebookPlacement, parentID: UUID?, depth: Int)

    var id: String {
        switch self {
        case .row(let row): row.id.uuidString
        case .ghost(let placement, let parentID, _):
            "ghost-\(placement.item.id.uuidString)-\(parentID?.uuidString ?? "root")"
        }
    }

    static func entries(
        rows: [NotebookSidebarRow], placements: [NotebookPlacement], expandedIDs: Set<UUID>
    ) -> [NotebookSidebarEntry] {
        let ghosts = NotebookGhost.ghosts(
            rows: rows.map { ($0.id, $0.depth) }, placements: placements,
            expandedIDs: expandedIDs)
        guard !ghosts.isEmpty else { return rows.map(NotebookSidebarEntry.row) }
        let byIndex = Dictionary(grouping: ghosts, by: \.index)
        var result: [NotebookSidebarEntry] = []
        for index in 0...rows.count {
            for ghost in byIndex[index] ?? [] {
                result.append(.ghost(ghost.placement, parentID: ghost.parentID, depth: ghost.depth))
            }
            if index < rows.count { result.append(.row(rows[index])) }
        }
        return result
    }
}
