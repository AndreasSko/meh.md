import NoteCore
import SwiftUI

/// A short note about Trash with one way back, at the bottom of the page.
struct NotebookTrashBar: View {
    let message: LocalizedStringKey
    let actionTitle: LocalizedStringKey?
    let isEnabled: Bool
    let action: () -> Void
    @Environment(\.mehPalette) private var palette

    var body: some View {
        HStack(spacing: 12) {
            Label(message, systemImage: "trash")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.glassProminent)
                    .tint(palette.highlighterColor)
                    .foregroundStyle(MehStyle.onHighlighterColor)
                    .disabled(!isEnabled)
                    .accessibilityIdentifier("notebook-trash-bar-action")
            }
        }
        .padding(.leading, 16).padding(.trailing, actionTitle == nil ? 16 : 6)
        .padding(.vertical, 6)
        .frame(minHeight: 44)
        .frame(maxWidth: 360)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notebook-trash-bar")
    }
}

/// Offers Undo for a few seconds after the open note went to Trash. The
/// toast inverts the page's colors, so it reads as a message rather than
/// another glass control like the search bar.
struct NotebookTrashUndoBar: View {
    let scene: NotebookSceneState
    @Environment(\.mehPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    #if os(macOS)
    private static let fill = Color(nsColor: MehStyle.dynamic(
        light: (0.14, 0.14, 0.14, 1), dark: (0.93, 0.93, 0.92, 1)))
    private static let text = Color(nsColor: MehStyle.dynamic(
        light: (1, 1, 1, 1), dark: (0.11, 0.11, 0.12, 1)))
    #else
    private static let fill = Color(uiColor: MehStyle.dynamic(
        light: (0.14, 0.14, 0.14, 1), dark: (0.93, 0.93, 0.92, 1)))
    private static let text = Color(uiColor: MehStyle.dynamic(
        light: (1, 1, 1, 1), dark: (0.11, 0.11, 0.12, 1)))
    #endif

    var body: some View {
        ZStack {
            if let trashed = scene.undoableTrashedNote {
                HStack(spacing: 12) {
                    message(for: trashed.noteID)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button("Undo", action: scene.undoTrashingOpenNote)
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .tint(palette.highlighterColor)
                        .foregroundStyle(MehStyle.onHighlighterColor)
                        .disabled(scene.busy)
                        .accessibilityIdentifier("notebook-trash-bar-action")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Self.text)
                .padding(.leading, 18).padding(.trailing, 7)
                .frame(minHeight: 44)
                .frame(maxWidth: 360)
                .background(Self.fill, in: .capsule)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .gesture(DragGesture(minimumDistance: 10).onEnded { drag in
                    if drag.translation.height > 0 { scene.trashedOpenNote = nil }
                })
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("notebook-trash-bar")
                .transition(reduceMotion ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeInOut : .bouncy,
                   value: scene.undoableTrashedNote?.id)
    }

    /// Names the note, so it's clear which one Undo brings back.
    private func message(for noteID: UUID) -> Text {
        guard let placement = scene.replica.placements.first(where: { $0.item.id == noteID })
        else { return Text("Moved to Trash") }
        let title = NotebookNoteName.title(from: placement.displayName)
        return Text("“\(title)” moved to Trash")
    }
}
