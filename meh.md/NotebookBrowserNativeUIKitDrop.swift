#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The collection view owns the destination while SwiftUI keeps its rows,
/// selection, menus, and drag source. One delegate handles the whole tree.
struct NotebookBrowserUIKitDropReader: UIViewRepresentable {
    let interaction: NotebookBrowserDropInteraction

    func makeCoordinator() -> Coordinator {
        Coordinator(interaction: interaction)
    }

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.isUserInteractionEnabled = false
        view.onHierarchyChange = { [weak coordinator = context.coordinator] view in
            coordinator?.attach(from: view)
        }
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        context.coordinator.interaction = interaction
        context.coordinator.attach(from: view)
        view.setNeedsLayout()
    }

    static func dismantleUIView(_ view: ReaderView, coordinator: Coordinator) {
        view.onHierarchyChange = nil
        coordinator.detach()
    }

    final class ReaderView: UIView {
        var onHierarchyChange: ((UIView) -> Void)?

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            onHierarchyChange?(self)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onHierarchyChange?(self)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            onHierarchyChange?(self)
        }
    }

    final class Coordinator: NSObject, UICollectionViewDropDelegate {
        var interaction: NotebookBrowserDropInteraction
        private weak var collectionView: UICollectionView?
        private weak var originalDelegate: (any UICollectionViewDropDelegate)?
        private var acceptedToken: UUID?

        init(interaction: NotebookBrowserDropInteraction) {
            self.interaction = interaction
        }

        func attach(from view: UIView) {
            var ancestor = view.superview
            while let current = ancestor, !(current is UICollectionView) {
                ancestor = current.superview
            }
            guard let enclosing = ancestor as? UICollectionView else { return }
            if collectionView !== enclosing {
                detach()
                collectionView = enclosing
            }
            if enclosing.dropDelegate !== self {
                originalDelegate = enclosing.dropDelegate
                enclosing.dropDelegate = self
            }
        }

        func detach() {
            if let collectionView, collectionView.dropDelegate === self {
                collectionView.dropDelegate = originalDelegate
            }
            collectionView = nil
            originalDelegate = nil
            interaction.state.hover(nil, expand: interaction.expand)
        }

        private func canHandle(_ session: any UIDropSession) -> Bool {
            session.localDragSession != nil
                && interaction.state.drag != nil
                && !session.items.isEmpty
                && session.items.allSatisfy {
                    $0.itemProvider.hasItemConformingToTypeIdentifier(
                        UTType.mehNotebookItem.identifier
                    )
                }
        }

        private func location(_ session: any UIDropSession) -> CGPoint? {
            guard let window = collectionView?.window else { return nil }
            return session.location(in: window)
        }

        func collectionView(
            _ collectionView: UICollectionView, canHandle session: any UIDropSession
        ) -> Bool {
            canHandle(session)
        }

        func collectionView(
            _ collectionView: UICollectionView,
            dropSessionDidUpdate session: any UIDropSession,
            withDestinationIndexPath destinationIndexPath: IndexPath?
        ) -> UICollectionViewDropProposal {
            let target = canHandle(session) ? location(session).flatMap(interaction.resolve) : nil
            interaction.state.hover(target, expand: interaction.expand)
            return UICollectionViewDropProposal(
                operation: target == nil ? .forbidden : .move, intent: .unspecified
            )
        }

        func collectionView(
            _ collectionView: UICollectionView,
            performDropWith coordinator: any UICollectionViewDropCoordinator
        ) {
            guard canHandle(coordinator.session), let drag = interaction.state.drag,
                  let point = location(coordinator.session),
                  let target = interaction.resolve(point),
                  let window = collectionView.window else {
                return
            }
            guard acceptedToken != drag.token else { return }
            acceptedToken = drag.token

            let state = interaction.state
            let providers = coordinator.session.items.map(\.itemProvider)
            let accepted = AcceptedDrop(
                drag: drag, target: target, state: state,
                providerCount: providers.count, commit: interaction.commit
            )
            state.reset()
            let previewPoint = target.rowID.flatMap { state.rowFrames[$0]?.center }
                ?? point
            for item in coordinator.items {
                coordinator.drop(
                    item.dragItem,
                    to: UIDragPreviewTarget(container: window, center: previewPoint)
                )
            }
            // List can lift one native item per selected row. Each provider
            // must carry this gesture's token; the captured roots move once.
            for provider in providers {
                provider.loadDataRepresentation(
                    forTypeIdentifier: UTType.mehNotebookItem.identifier
                ) { data, _ in
                    Task { @MainActor in
                        accepted.complete(data: data)
                    }
                }
            }
        }

        func collectionView(
            _ collectionView: UICollectionView,
            dropSessionDidExit session: any UIDropSession
        ) {
            // Exiting one destination is not the end of the source session.
            // Keep its token so the user can drag back into the collection.
            interaction.state.hover(nil, expand: interaction.expand)
        }

        func collectionView(
            _ collectionView: UICollectionView,
            dropSessionDidEnd session: any UIDropSession
        ) {
            interaction.state.hover(nil, expand: interaction.expand)
        }
    }

    /// An accepted gesture outlives the header that installed its destination.
    /// SwiftUI can dismantle that header when reset removes its drag styling.
    /// The model checks the captured notebook and source placement atomically.
    @MainActor
    private final class AcceptedDrop {
        let drag: NotebookBrowserDrag
        let target: NotebookBrowserDropTarget
        let state: NotebookBrowserDragState
        let commit: (NotebookBrowserDrag, NotebookBrowserDropTarget) -> Void
        private var completed = false
        private var remainingProviders: Int
        private var providersMatch = true

        init(
            drag: NotebookBrowserDrag, target: NotebookBrowserDropTarget,
            state: NotebookBrowserDragState,
            providerCount: Int,
            commit: @escaping (NotebookBrowserDrag, NotebookBrowserDropTarget) -> Void
        ) {
            self.drag = drag
            self.target = target
            self.state = state
            remainingProviders = providerCount
            self.commit = commit
        }

        func complete(data: Data?) {
            guard !completed else { return }
            providersMatch = providersMatch && data.flatMap {
                String(data: $0, encoding: .utf8)
            } == drag.token.uuidString
            remainingProviders -= 1
            guard remainingProviders == 0 else { return }
            completed = true
            guard providersMatch, state.latestToken == drag.token, state.drag == nil else {
                return
            }
            commit(drag, target)
        }
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
#endif
