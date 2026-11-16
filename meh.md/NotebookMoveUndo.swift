import NoteCore
import SwiftUI

/// Offers the last move to the window's undo, so ⌘Z, the Mac's Edit menu
/// and shaking the device undo it, as in Files and Finder. The scene keeps
/// the change; this only mirrors it.
@MainActor
final class NotebookMoveUndo {
    struct Offer: Equatable {
        var undo: NotebookBrowserUndo?
        var redo: NotebookBrowserUndo?

        init(undo: NotebookBrowserUndo? = nil, redo: NotebookBrowserUndo? = nil) {
            self.undo = undo?.action == .move ? undo : nil
            self.redo = redo?.action == .move ? redo : nil
        }
    }

    private static let actionName = String(localized: "Move")

    private weak var scene: NotebookSceneState?
    private(set) weak var manager: UndoManager?
    #if os(iOS)
    /// Shaking and ⌘Z ask the first responder. After a drag nothing is
    /// first responder, so this takes the role then.
    weak var responder: NotebookUndoResponder?
    #endif
    /// What the manager holds for this scene while nothing runs.
    private var offered = Offer()
    /// The direction the manager is running. Its opposite is already
    /// registered, so the scene's change when it ends needs no rebuild.
    private var running: Bool?
    /// The opposite direction, asked for before the running change ended.
    /// It runs right after, so the manager never offers a dead action.
    private var queued = false

    func attach(_ manager: UndoManager?, scene: NotebookSceneState) {
        self.scene = scene
        guard manager !== self.manager else { return }
        self.manager?.removeAllActions(withTarget: self)
        self.manager = manager
        running = nil
        rebuild(Offer(undo: scene.browserUndo, redo: scene.browserRedo))
    }

    func update(_ current: Offer) {
        if let redo = running {
            running = nil
            let finished = redo ? current.redo == nil && current.undo != nil
                : current.undo == nil && current.redo != nil
            let next = queued
            queued = false
            if finished {
                offered = current
                if next { start(redo: !redo, afterRunning: true) }
                return
            }
        }
        guard current != offered else { return }
        rebuild(current)
    }

    func detach() {
        manager?.removeAllActions(withTarget: self)
        manager = nil
        running = nil
        queued = false
        offered = Offer()
    }

    /// Undo Move and Redo Move in ⋯ go through the manager while it offers
    /// the same change, so it keeps the opposite for ⌘Z and shaking.
    func perform(redo: Bool) {
        if running == nil, offers(redo), let manager,
           redo ? manager.canRedo : manager.canUndo,
           (redo ? manager.redoActionName : manager.undoActionName) == Self.actionName {
            if redo { manager.redo() } else { manager.undo() }
        } else {
            scene?.undoBrowserChange(redo: redo)
        }
    }

    /// A redo can only be registered while undoing, so a rebuilt manager
    /// offers Undo Move alone; ⋯ still offers Redo Move.
    private func rebuild(_ current: Offer) {
        manager?.removeAllActions(withTarget: self)
        offered = Offer(undo: current.undo)
        if current.undo != nil {
            register(redo: false)
            #if os(iOS)
            responder?.claimIfFree()
            #endif
        }
    }

    private func register(redo: Bool) {
        guard let manager else { return }
        manager.registerUndo(withTarget: self) { $0.run(redo: redo) }
        manager.setActionName(Self.actionName)
    }

    private func offers(_ redo: Bool) -> Bool {
        guard let scene, let change = redo ? offered.redo : offered.undo else { return false }
        return change == (redo ? scene.browserRedo : scene.browserUndo)
    }

    /// Runs inside the manager's undo or redo. The manager has already
    /// dropped this action, so anything that keeps the change from
    /// starting rebuilds it once the manager has returned.
    private func run(redo: Bool) {
        // Registered while the manager runs, so it lands on the opposite
        // stack.
        if let active = running {
            guard active != redo, !queued else { return }
            register(redo: !redo)
            queued = true
            return
        }
        guard let scene, !scene.busy, offers(redo) else {
            scheduleRebuild()
            return
        }
        register(redo: !redo)
        start(redo: redo, afterRunning: false)
    }

    private func start(redo: Bool, afterRunning: Bool) {
        running = redo
        offered = Offer()
        guard afterRunning else { change(redo: redo); return }
        // A queued change waits until the scene has finished the one before.
        Task { @MainActor [weak self] in self?.change(redo: redo) }
    }

    private func change(redo: Bool) {
        scene?.undoBrowserChange(redo: redo) { [weak self] succeeded in
            guard !succeeded, let self else { return }
            running = nil
            queued = false
            scheduleRebuild()
        }
    }

    private func scheduleRebuild() {
        Task { @MainActor [weak self] in
            guard let self, running == nil, let scene else { return }
            rebuild(Offer(undo: scene.browserUndo, redo: scene.browserRedo))
        }
    }
}

#if os(iOS)
final class NotebookUndoResponder: UIView {
    weak var mirror: NotebookMoveUndo?

    override var canBecomeFirstResponder: Bool { true }

    override var undoManager: UndoManager? { mirror?.manager ?? super.undoManager }

    /// Never takes the role from a text field or the editor.
    func claimIfFree() {
        guard window != nil, NotebookFirstResponder.current == nil else { return }
        becomeFirstResponder()
    }

    @objc func undo(_ sender: Any?) { undoManager?.undo() }

    @objc func redo(_ sender: Any?) { undoManager?.redo() }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(undo(_:)): undoManager?.canUndo == true
        case #selector(redo(_:)): undoManager?.canRedo == true
        default: super.canPerformAction(action, withSender: sender)
        }
    }
}

private struct NotebookUndoResponderView: UIViewRepresentable {
    let mirror: NotebookMoveUndo

    func makeUIView(context: Context) -> NotebookUndoResponder {
        let view = NotebookUndoResponder()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: NotebookUndoResponder, context: Context) {
        view.mirror = mirror
        mirror.responder = view
    }
}

/// UIKit has no public way to ask for the first responder; an action sent
/// to nil reaches it.
@MainActor
private enum NotebookFirstResponder {
    private static weak var found: UIResponder?

    static var current: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(
            #selector(UIResponder.notebookReportFirstResponder), to: nil, from: nil, for: nil)
        return found
    }

    fileprivate static func report(_ responder: UIResponder) { found = responder }
}

extension UIResponder {
    @objc fileprivate func notebookReportFirstResponder() {
        NotebookFirstResponder.report(self)
    }
}
#endif

/// Connects the scene's moves to its window's undo manager.
struct NotebookMoveUndoMirror: ViewModifier {
    let scene: NotebookSceneState
    @Environment(\.undoManager) private var undoManager

    private var mirror: NotebookMoveUndo { scene.moveUndo }

    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .background(NotebookUndoResponderView(mirror: mirror).accessibilityHidden(true))
            #endif
            .onAppear { mirror.attach(undoManager, scene: scene) }
            .onChange(of: undoManager) { _, manager in
                mirror.attach(manager, scene: scene)
            }
            .onChange(of: NotebookMoveUndo.Offer(
                undo: scene.browserUndo, redo: scene.browserRedo)
            ) { _, offer in
                mirror.update(offer)
            }
            .onDisappear { mirror.detach() }
    }
}
