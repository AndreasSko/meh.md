import SwiftUI

/// A focus intent belongs to one note, including when its editor is mounting.
struct NotebookTitleFocusRequest: Equatable {
    let noteID: UUID
    let selectsAll: Bool
    let token = UUID()
}

/// Keep focus and selection in the title's own hosting tree.
struct NotebookTitleField: View {
    let noteID: UUID
    @Binding var text: String
    let font: Font
    let isEnabled: Bool
    let focusRequest: NotebookTitleFocusRequest?
    let onFocusHandled: (NotebookTitleFocusRequest) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
    @FocusState private var isFocused: Bool
    @State private var selection: TextSelection?
    @State private var isReady = false
    @State private var handledFocusToken: UUID?

    private struct FocusReadiness: Equatable {
        let request: NotebookTitleFocusRequest?
        let isEnabled: Bool
        let isReady: Bool
    }

    var body: some View {
        TextField("Note title", text: $text, selection: $selection, axis: .vertical)
            .textFieldStyle(.plain)
            .font(font)
            .lineLimit(1...4)
            .focused($isFocused)
            .disabled(!isEnabled)
            .submitLabel(.done)
            .onSubmit(onSubmit)
            .onKeyPress(.tab) {
                onSubmit()
                return .handled
            }
            .background {
                NotebookTitleReadiness { isReady = $0 }
                    .allowsHitTesting(false)
            }
            #if os(iOS)
            .background { NotebookTitleDropGuard().allowsHitTesting(false) }
            #endif
            .task(id: FocusReadiness(
                request: focusRequest, isEnabled: isEnabled, isReady: isReady
            )) {
                guard isEnabled, isReady,
                      let request = focusRequest, request.noteID == noteID,
                      request.token != handledFocusToken else { return }
                let wasFocused = isFocused
                isFocused = true
                if request.selectsAll {
                    selection = TextSelection(range: text.startIndex..<text.endIndex)
                }
                handledFocusToken = request.token
                if wasFocused { onFocusHandled(request) }
            }
            .onChange(of: isFocused) { _, focused in
                guard focused, let request = focusRequest,
                      request.noteID == noteID else { return }
                onFocusHandled(request)
            }
            .onDisappear { isFocused = false }
            .titleEscapeAction(onCancel)
            .accessibilityIdentifier("title-field")
    }
}

private extension View {
    @ViewBuilder
    func titleEscapeAction(_ action: @escaping () -> Void) -> some View {
        #if os(macOS)
        onExitCommand(perform: action)
        #else
        self
        #endif
    }
}

#if os(iOS)
/// Appearance alone can run before a compact navigation push has attached.
private struct NotebookTitleReadiness: UIViewRepresentable {
    let onReady: (Bool) -> Void

    func makeUIView(context: Context) -> NotebookTitleReadinessView {
        let view = NotebookTitleReadinessView()
        view.isUserInteractionEnabled = false
        view.onReady = onReady
        return view
    }

    func updateUIView(_ view: NotebookTitleReadinessView, context: Context) {
        view.onReady = onReady
        view.checkReadiness()
    }
}

private final class NotebookTitleReadinessView: UIView {
    var onReady: ((Bool) -> Void)?
    private var reportedReady = false
    private var waitingForTransition = false
    private var attachmentGeneration = 0

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachmentGeneration &+= 1
        waitingForTransition = false
        checkReadiness()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        checkReadiness()
    }

    func checkReadiness() {
        guard window != nil, bounds.width > 0, bounds.height > 0 else {
            reportReady(false)
            return
        }
        guard !reportedReady, !waitingForTransition else { return }
        if let transition = enclosingTransition {
            waitingForTransition = true
            let generation = attachmentGeneration
            let registered = transition.animate(alongsideTransition: nil) { [weak self] _ in
                guard let self, self.attachmentGeneration == generation else { return }
                self.waitingForTransition = false
                self.reportReady(
                    self.window != nil && self.bounds.width > 0 && self.bounds.height > 0
                )
            }
            if registered { return }
            waitingForTransition = false
        }
        reportReady(true)
    }

    private var enclosingTransition: (any UIViewControllerTransitionCoordinator)? {
        // The title host is embedded in a text view. Look through its native
        // ancestors as well as its own, separate hosting-controller chain.
        var ancestor = superview
        while let view = ancestor {
            var responder: UIResponder? = view
            while let current = responder {
                if let controller = current as? UIViewController,
                   let transition = controller.transitionCoordinator {
                    return transition
                }
                responder = current.next
            }
            ancestor = view.superview
        }
        return nil
    }

    private func reportReady(_ ready: Bool) {
        guard reportedReady != ready else { return }
        reportedReady = ready
        let generation = attachmentGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.attachmentGeneration == generation else { return }
            self.onReady?(ready)
        }
    }
}

/// A note dragged toward a new window carries its link. Dropped on the
/// title being edited, it would end up in the note's name, so the title
/// turns it down like the editor does.
private struct NotebookTitleDropGuard: UIViewRepresentable {
    func makeUIView(context: Context) -> NotebookTitleDropGuardView {
        let view = NotebookTitleDropGuardView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: NotebookTitleDropGuardView, context: Context) {}
}

private final class NotebookTitleDropGuardView: UIView, UITextDropDelegate {
    override init(frame: CGRect) {
        super.init(frame: frame)
        // SwiftUI can replace the field's text view without laying this view
        // out again. Once editing begins, the current one is in place.
        for name in [UITextView.textDidBeginEditingNotification,
                     UITextField.textDidBeginEditingNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(install), name: name, object: nil)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override func layoutSubviews() {
        super.layoutSubviews()
        install()
    }

    @objc private func install() {
        guard window != nil, let field = titleField() else { return }
        // Never take over a delegate someone else set.
        if field.textDropDelegate == nil { field.textDropDelegate = self }
    }

    /// SwiftUI draws the field beside this view. The title host sits inside
    /// the editor's text view, so a text view around this one is the editor.
    private func titleField() -> (UIView & UITextDroppable)? {
        let center = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil)
        var ancestor = superview
        for _ in 0..<4 {
            guard let root = ancestor else { return nil }
            if let field = droppable(in: root, containing: center) { return field }
            ancestor = root.superview
        }
        return nil
    }

    private func droppable(
        in view: UIView, containing point: CGPoint
    ) -> (UIView & UITextDroppable)? {
        for subview in view.subviews where !isDescendant(of: subview) {
            if let field = subview as? UIView & UITextDroppable,
               field.convert(field.bounds, to: nil).contains(point) {
                return field
            }
            if let field = droppable(in: subview, containing: point) { return field }
        }
        return nil
    }

    func textDroppableView(
        _ textDroppableView: UIView & UITextDroppable,
        proposalForDrop drop: UITextDropRequest
    ) -> UITextDropProposal {
        let items = drop.dropSession.localDragSession?.items ?? []
        return items.contains(where: NotebookNoteWindowDrag.isNote)
            ? UITextDropProposal(operation: .cancel) : drop.suggestedProposal
    }
}
#else
private struct NotebookTitleReadiness: NSViewRepresentable {
    let onReady: (Bool) -> Void

    func makeNSView(context: Context) -> NotebookTitleReadinessView {
        let view = NotebookTitleReadinessView()
        view.onReady = onReady
        return view
    }

    func updateNSView(_ view: NotebookTitleReadinessView, context: Context) {
        view.onReady = onReady
        view.checkReadiness()
    }
}

private final class NotebookTitleReadinessView: NSView {
    var onReady: ((Bool) -> Void)?
    private var reportedReady = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        checkReadiness()
    }

    override func layout() {
        super.layout()
        checkReadiness()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func checkReadiness() {
        let ready = window != nil && bounds.width > 0 && bounds.height > 0
        guard reportedReady != ready else { return }
        reportedReady = ready
        DispatchQueue.main.async { [weak self] in self?.onReady?(ready) }
    }
}
#endif
