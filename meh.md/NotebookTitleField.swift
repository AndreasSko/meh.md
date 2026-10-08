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
            .task(id: FocusReadiness(
                request: focusRequest, isEnabled: isEnabled, isReady: isReady
            )) {
                guard isEnabled, isReady,
                      let request = focusRequest, request.noteID == noteID,
                      request.token != handledFocusToken else { return }
#if DEBUG && os(iOS)
                if ProcessInfo.processInfo.environment["MEH_NATIVE_INPUT_DIAGNOSTICS"] == "1" {
                    NSLog("[MEHNativeInput] title.focusIntent focused=%@ selectsAll=%@ documentUTF16=%ld",
                          String(isFocused), String(request.selectsAll), text.utf16.count)
                }
#endif
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

#if DEBUG
    private func updateInputDiagnostics() {
        NotificationCenter.default.removeObserver(self)
        guard window != nil,
              ProcessInfo.processInfo.environment["MEH_NATIVE_INPUT_DIAGNOSTICS"] == "1"
        else { return }
        for name in [UITextField.textDidBeginEditingNotification,
                     UITextField.textDidChangeNotification, UITextField.textDidEndEditingNotification,
                     UITextView.textDidBeginEditingNotification,
                     UITextView.textDidChangeNotification, UITextView.textDidEndEditingNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(traceInput(_:)),
                                                   name: name, object: nil)
        }
    }

    @objc private func traceInput(_ notification: Notification) {
        guard let view = notification.object as? UIView, view.window === window,
              let input = view as? UITextInput else { return }
        func responder(in view: UIView) -> UIView? {
            if view.isFirstResponder { return view }
            for child in view.subviews {
                if let active = responder(in: child) { return active }
            }
            return nil
        }
        let active = window.flatMap { responder(in: $0) }
        func offsets(_ range: UITextRange?) -> String {
            guard let range else { return "none" }
            return "\(input.offset(from: input.beginningOfDocument, to: range.start)):"
                + "\(input.offset(from: range.start, to: range.end))"
        }
        NSLog("[MEHNativeInput] title.%@ field=%@ responder=%@ focused=%@ selection=%@ marked=%@ documentUTF16=%ld",
              notification.name.rawValue, String(describing: type(of: view)),
              active.map { String(describing: type(of: $0)) } ?? "none",
              String(view.isFirstResponder), offsets(input.selectedTextRange),
              offsets(input.markedTextRange),
              input.offset(from: input.beginningOfDocument, to: input.endOfDocument))
    }

    deinit { NotificationCenter.default.removeObserver(self) }
#endif

    override func didMoveToWindow() {
        super.didMoveToWindow()
#if DEBUG
        updateInputDiagnostics()
#endif
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
