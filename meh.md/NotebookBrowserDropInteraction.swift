import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

extension UTType {
    static let mehNotebookItem = UTType(exportedAs: "de.andreas-sk.meh-md.browser-item")
}

@MainActor @Observable
final class NotebookBrowserDragState {
    var drag: NotebookBrowserDrag?
    var target: NotebookBrowserDropTarget?
    @ObservationIgnored var rowFrames: [UUID: CGRect] = [:]
    @ObservationIgnored var filesHeaderFrame: CGRect = .zero
    #if os(macOS)
    @ObservationIgnored weak var scrollView: NSScrollView?
    @ObservationIgnored weak var dropSurface: NSView?
    @ObservationIgnored private var rowAnchors: [UUID: WeakRowAnchor] = [:]

    private final class WeakRowAnchor {
        weak var view: NSView?

        init(_ view: NSView) { self.view = view }
    }

    func registerRowAnchor(_ view: NSView, for itemID: UUID) {
        rowAnchors[itemID] = WeakRowAnchor(view)
    }

    func unregisterRowAnchor(_ view: NSView, for itemID: UUID) {
        guard rowAnchors[itemID]?.view === view else { return }
        rowAnchors.removeValue(forKey: itemID)
    }
    #endif
    @ObservationIgnored private var provider: NSItemProvider?
    @ObservationIgnored private(set) var latestToken: UUID?
    @ObservationIgnored var isSessionActive = false
    @ObservationIgnored private var springTask: Task<Void, Never>?

    func rowFrame(for itemID: UUID) -> CGRect? {
        #if os(macOS)
        guard let anchor = rowAnchors[itemID]?.view else {
            rowAnchors.removeValue(forKey: itemID)
            return nil
        }
        guard let window = dropSurface?.window, anchor.window === window,
              anchor.superview != nil, !anchor.isHiddenOrHasHiddenAncestor,
              !anchor.bounds.isEmpty, let content = window.contentView else { return nil }
        // List can move its hosting cells without laying out their SwiftUI
        // contents. Resolve from the current AppKit hierarchy on every hover.
        let frame = anchor.convert(anchor.bounds, to: content)
        guard !frame.isEmpty else { return nil }
        return CGRect(x: frame.minX,
                      y: content.isFlipped ? frame.minY : content.bounds.height - frame.maxY,
                      width: frame.width, height: frame.height)
        #else
        return rowFrames[itemID]
        #endif
    }

    func begin(_ drag: NotebookBrowserDrag) -> NSItemProvider {
        if let current = self.drag, current.notebookID == drag.notebookID,
           current.sources == drag.sources, let provider { return provider }
        // A different source cannot inherit or replace an active gesture.
        if isSessionActive, self.drag != nil { return NSItemProvider() }
        reset()
        self.drag = drag
        latestToken = drag.token
        let provider = NSItemProvider()
        provider.suggestedName = drag.token.uuidString
        let data = Data(drag.token.uuidString.utf8)
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.mehNotebookItem.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
        self.provider = provider
        return provider
    }

    func hover(_ target: NotebookBrowserDropTarget?, expand: @escaping (UUID?) -> Void) {
        guard self.target != target else { return }
        springTask?.cancel()
        self.target = target
        guard let target, target.position == .into || target.position == .root else { return }
        let token = drag?.token
        springTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, let self, self.drag?.token == token,
                  self.target == target else { return }
            expand(target.rowID)
        }
    }

    func reset() {
        springTask?.cancel()
        springTask = nil
        target = nil
        drag = nil
        provider = nil
        isSessionActive = false
    }
}

/// One destination resolves both insertion edges and folder centers. It never
/// changes the catalog while the pointer is moving through the hierarchy.
struct NotebookBrowserDropInteraction {
    let state: NotebookBrowserDragState
    let resolve: (CGPoint) -> NotebookBrowserDropTarget?
    let expand: (UUID?) -> Void
    let commit: (NotebookBrowserDrag, NotebookBrowserDropTarget) -> Void
}

/// Native macOS cells can move independently of their SwiftUI contents. UIKit
/// keeps the row's last observed frame so a recycled row restores its cache.
private struct NotebookBrowserRowGeometry: ViewModifier {
    let itemID: UUID
    let state: NotebookBrowserDragState
    @State private var lastFrame: CGRect = .zero

    func body(content: Content) -> some View {
        #if os(macOS)
        content.background(NotebookBrowserAppKitRowAnchor(itemID: itemID, state: state))
        #else
        content
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: { frame in
                lastFrame = frame
                state.rowFrames[itemID] = frame
            }
            .onAppear {
                if !lastFrame.isEmpty { state.rowFrames[itemID] = lastFrame }
            }
            .onDisappear {
                state.rowFrames.removeValue(forKey: itemID)
            }
        #endif
    }
}

extension View {
    func notebookBrowserRowGeometry(
        itemID: UUID, state: NotebookBrowserDragState
    ) -> some View {
        modifier(NotebookBrowserRowGeometry(itemID: itemID, state: state))
    }

    @ViewBuilder
    func notebookDragSource(
        enabled: Bool, provider: @escaping () -> NSItemProvider
    ) -> some View {
        #if os(macOS)
        // AppKit owns source tracking. Keep native row identity stable when
        // inline naming changes whether a drag is allowed.
        self
        #else
        if enabled {
            onDrag(provider)
                .dragConfiguration(DragConfiguration(
                    operationsWithinApp: .init(allowMove: true),
                    operationsOutsideApp: .init(allowCopy: false)
                ))
        } else { self }
        #endif
    }
}
