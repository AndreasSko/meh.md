#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A passive row anchor supplies live geometry after native cell reuse,
/// reordering, or scrolling without depending on a SwiftUI layout callback.
struct NotebookBrowserAppKitRowAnchor: NSViewRepresentable {
    let itemID: UUID
    let state: NotebookBrowserDragState

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.setAccessibilityElement(false)
        view.setAccessibilityHidden(true)
        view.configure(itemID: itemID, state: state)
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.configure(itemID: itemID, state: state)
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        view.disconnect()
    }

    final class AnchorView: NSView {
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
            if window != nil, superview != nil {
                state?.registerRowAnchor(self, for: itemID)
            } else {
                state?.unregisterRowAnchor(self, for: itemID)
            }
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            connect()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            connect()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct NotebookBrowserAppKitScrollReader: NSViewRepresentable {
    let state: NotebookBrowserDragState

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.state = state
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.state = state
        view.connect()
    }

    final class ReaderView: NSView {
        weak var state: NotebookBrowserDragState?

        override func viewDidMoveToSuperview() { connect() }
        override func viewDidMoveToWindow() { connect() }
        override func layout() {
            super.layout()
            connect()
        }

        func connect() {
            if let scrollView = enclosingScrollView { state?.scrollView = scrollView }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// A single native destination over the SwiftUI list. Normal mouse events
/// continue to reach the list; AppKit routes an active local drag here.
struct NotebookBrowserAppKitDropSurface: NSViewRepresentable {
    let interaction: NotebookBrowserDropInteraction

    func makeNSView(context: Context) -> DropSurface {
        let view = DropSurface()
        view.interaction = interaction
        interaction.state.dropSurface = view
        view.registerForDraggedTypes([
            NSPasteboard.PasteboardType(UTType.mehNotebookItem.identifier)
        ])
        return view
    }

    func updateNSView(_ view: DropSurface, context: Context) {
        if view.interaction?.state !== interaction.state,
           view.interaction?.state.dropSurface === view {
            view.interaction?.state.dropSurface = nil
        }
        view.interaction = interaction
        interaction.state.dropSurface = view
    }

    static func dismantleNSView(_ view: DropSurface, coordinator: ()) {
        if view.interaction?.state.dropSurface === view {
            view.interaction?.state.dropSurface = nil
            view.interaction?.state.reset()
        }
        view.unregisterDraggedTypes()
    }

    final class DropSurface: NSView {
        var interaction: NotebookBrowserDropInteraction?
        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard interaction?.state.isSessionActive == true else { return nil }
            return super.hitTest(point)
        }

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            return draggingUpdated(sender)
        }

        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            guard let interaction, interaction.state.drag != nil,
                  sender.draggingPasteboard.types?.contains(
                    NSPasteboard.PasteboardType(UTType.mehNotebookItem.identifier)
                  ) == true else { return [] }
            let point = convert(sender.draggingLocation, from: nil)
            let target = globalLocation(sender).flatMap(interaction.resolve)
            interaction.state.hover(target, expand: interaction.expand)
            scroll(at: point)
            return target == nil ? [] : .move
        }

        override func wantsPeriodicDraggingUpdates() -> Bool { true }

        private func globalLocation(_ sender: any NSDraggingInfo) -> CGPoint? {
            guard let content = window?.contentView else { return nil }
            let point = content.convert(sender.draggingLocation, from: nil)
            return CGPoint(x: point.x, y: content.isFlipped
                           ? point.y : content.bounds.height - point.y)
        }

        private func scroll(at point: CGPoint) {
            guard bounds.contains(point),
                  let scrollView = interaction?.state.scrollView,
                  scrollView.documentView != nil else { return }
            let edge: CGFloat = 36
            let direction: CGFloat
            if point.y < edge { direction = -1 + point.y / edge }
            else if point.y > bounds.height - edge {
                direction = 1 - (bounds.height - point.y) / edge
            } else { return }
            let clip = scrollView.contentView
            // AppKit owns the limits, including toolbar and content insets.
            // A zero top clamp can move a short list underneath its header.
            var proposed = clip.bounds
            proposed.origin.y += direction * 24
            let next = clip.constrainBoundsRect(proposed).origin
            guard next != clip.bounds.origin else { return }
            clip.scroll(to: next)
            scrollView.reflectScrolledClipView(clip)
        }

        override func draggingExited(_ sender: (any NSDraggingInfo)?) {
            guard let interaction else { return }
            interaction.state.hover(nil, expand: interaction.expand)
        }

        override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            draggingUpdated(sender) == .move
        }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            guard let interaction, let drag = interaction.state.drag,
                  let point = globalLocation(sender),
                  let target = interaction.resolve(point),
                  let data = sender.draggingPasteboard.data(forType:
                    NSPasteboard.PasteboardType(UTType.mehNotebookItem.identifier)),
                  String(data: data, encoding: .utf8) == drag.token.uuidString
            else { return false }
            interaction.state.reset()
            interaction.commit(drag, target)
            return true
        }

        override func draggingEnded(_ sender: any NSDraggingInfo) {
            interaction?.state.reset()
        }
    }
}
#endif
