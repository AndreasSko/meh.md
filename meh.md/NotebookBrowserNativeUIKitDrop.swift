#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Finds a row's current frame from its cell, which UIKit can move without
/// laying out the row's SwiftUI contents.
struct NotebookBrowserUIKitRowAnchor: UIViewRepresentable {
    let itemID: UUID
    let state: NotebookBrowserDragState

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.configure(itemID: itemID, state: state)
        return view
    }

    func updateUIView(_ view: AnchorView, context: Context) {
        view.configure(itemID: itemID, state: state)
    }

    static func dismantleUIView(_ view: AnchorView, coordinator: ()) {
        view.disconnect()
    }

    final class AnchorView: UIView {
        private weak var state: NotebookBrowserDragState?
        private var itemID: UUID?

        func configure(itemID: UUID, state: NotebookBrowserDragState) {
            if self.itemID != itemID || self.state !== state { disconnect() }
            self.itemID = itemID
            self.state = state
            connect()
        }

        func disconnect() {
            if let itemID { state?.unregisterRowAnchor(self, for: itemID) }
            itemID = nil
            state = nil
        }

        private func connect() {
            guard let itemID else { return }
            if window != nil {
                state?.registerRowAnchor(self, for: itemID)
            } else {
                state?.unregisterRowAnchor(self, for: itemID)
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            connect()
        }
    }
}

/// The collection view owns the destination while SwiftUI keeps its rows,
/// selection, menus, and drag source. One delegate handles the whole tree.
/// It also reports taps, since SwiftUI rows don't cover the empty space.
struct NotebookBrowserUIKitDropReader: UIViewRepresentable {
    let interaction: NotebookBrowserDropInteraction
    let tapEmptySpace: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(interaction: interaction, tapEmptySpace: tapEmptySpace)
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
        context.coordinator.tapEmptySpace = tapEmptySpace
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

    final class Coordinator: NSObject, UICollectionViewDropDelegate,
                             UIGestureRecognizerDelegate {
        var interaction: NotebookBrowserDropInteraction
        var tapEmptySpace: (CGPoint) -> Void
        private weak var collectionView: UICollectionView?
        private weak var originalDelegate: (any UICollectionViewDropDelegate)?
        private var acceptedToken: UUID?
        private lazy var tap: UITapGestureRecognizer = {
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            return tap
        }()

        init(interaction: NotebookBrowserDropInteraction,
             tapEmptySpace: @escaping (CGPoint) -> Void) {
            self.interaction = interaction
            self.tapEmptySpace = tapEmptySpace
        }

        @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let window = collectionView?.window else { return }
            tapEmptySpace(recognizer.location(in: window))
        }

        /// Only touches on the bare collection view count. Rows, the footer
        /// and revealed swipe actions are subviews; a swiped row slides its
        /// whole cell aside, so its Trash button lies outside every cell.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
        ) -> Bool {
            touch.view === collectionView
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }

        func attach(from view: UIView) {
            var ancestor = view.superview
            while let current = ancestor, !(current is UICollectionView) {
                ancestor = current.superview
            }
            guard let enclosing = ancestor as? UICollectionView else { return }
            if collectionView !== enclosing {
                detach()
                collectionView = enclosing
                enclosing.addGestureRecognizer(tap)
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
            collectionView?.removeGestureRecognizer(tap)
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
            let previewPoint = target.rowID.flatMap { state.rowFrame(for: $0)?.center }
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
