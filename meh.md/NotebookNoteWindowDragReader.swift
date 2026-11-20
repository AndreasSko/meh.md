#if os(iOS)
import MehWidgetData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Where each note row on screen sits in the list that holds the reader.
@MainActor
final class NotebookNoteWindowDragFrames {
    static let space = "notebook-note-window-drag"
    /// The token tells a row apart from the one that replaced it, so a
    /// leaving row doesn't remove its successor's frame.
    var notes: [UUID: (token: UUID, frame: CGRect)] = [:]
}

/// Marks a dragged note, so meh.md's own editor doesn't paste its link.
struct NotebookNoteWindowDrag {
    let noteID: UUID
}

private struct NotebookNoteWindowDragFrame: ViewModifier {
    let id: UUID
    let frames: NotebookNoteWindowDragFrames
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(NotebookNoteWindowDragFrames.space))
            } action: {
                frames.notes[id] = (token, $0)
            }
            .onDisappear {
                if frames.notes[id]?.token == token { frames.notes[id] = nil }
            }
    }
}

extension View {
    func notebookNoteWindowDragFrame(
        _ id: UUID, in frames: NotebookNoteWindowDragFrames
    ) -> some View {
        modifier(NotebookNoteWindowDragFrame(id: id, frames: frames))
    }
}

/// Drags a note out of a scroll view into its own window.
struct NotebookNoteWindowDragReader: UIViewRepresentable {
    let frames: NotebookNoteWindowDragFrames

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        context.coordinator.list = view
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        context.coordinator.frames = frames
    }

    static func dismantleUIView(_ view: ProbeView, coordinator: Coordinator) {
        coordinator.attach(to: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator(frames: frames) }

    final class ProbeView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            var ancestor = window == nil ? nil : superview
            while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
            coordinator?.attach(to: ancestor)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIDragInteractionDelegate {
        var frames: NotebookNoteWindowDragFrames
        private lazy var interaction = UIDragInteraction(delegate: self)
        private weak var host: UIView?
        /// Spans the list, so its coordinates are the frames' coordinates.
        weak var list: UIView?

        init(frames: NotebookNoteWindowDragFrames) { self.frames = frames }

        func attach(to view: UIView?) {
            guard host !== view else { return }
            host?.removeInteraction(interaction)
            host = view
            view?.addInteraction(interaction)
            interaction.isEnabled = true
        }

        private func note(at location: CGPoint, in view: UIView) -> UUID? {
            guard let list else { return nil }
            let point = view.convert(location, to: list)
            return frames.notes.first { $0.value.frame.contains(point) }?.key
        }

        func dragInteraction(
            _ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession
        ) -> [UIDragItem] {
            guard let view = interaction.view,
                  let id = note(at: session.location(in: view), in: view)
            else { return [] }
            // The note's link, not a user activity: the system opens a window
            // for the app that owns the URL scheme. An activity needs a team ID,
            // which simulator builds don't carry.
            let provider = NSItemProvider(object: MehWidgetLink.note(id).url as NSURL)
            let item = UIDragItem(itemProvider: provider)
            item.localObject = NotebookNoteWindowDrag(noteID: id)
            return [item]
        }

        func dragInteraction(
            _ interaction: UIDragInteraction, previewForLifting item: UIDragItem,
            session: UIDragSession
        ) -> UITargetedDragPreview? {
            guard let view = interaction.view, let list, let drag = item.localObject as? NotebookNoteWindowDrag,
                  let frame = frames.notes[drag.noteID]?.frame, let window = view.window,
                  // The reader draws nothing, so the row comes from the window.
                  let snapshot = window.resizableSnapshotView(
                      from: list.convert(frame, to: window), afterScreenUpdates: false,
                      withCapInsets: .zero)
            else { return nil }
            let parameters = UIDragPreviewParameters()
            parameters.visiblePath = UIBezierPath(
                roundedRect: snapshot.bounds, cornerRadius: 12)
            let center = view.convert(CGPoint(x: frame.midX, y: frame.midY), from: list)
            return UITargetedDragPreview(
                view: snapshot, parameters: parameters,
                target: UIDragPreviewTarget(container: view, center: center))
        }
    }
}
extension NotebookNoteWindowDrag {
    /// A note's drag carries its link. Dropped on the open note, it would
    /// paste that link.
    static func isNote(_ item: UIDragItem) -> Bool {
        item.localObject is NotebookNoteWindowDrag
            || item.itemProvider.hasItemConformingToTypeIdentifier(
                UTType.mehNotebookItem.identifier)
    }
}
#endif
