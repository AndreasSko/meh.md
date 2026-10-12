#if CHATGPT_POC && os(iOS)
import AssistantCore
import Observation
import SafariServices
import SwiftUI
import UIKit

extension UUID {
    static let assistantUnavailableNotebook = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!
}

struct AssistantBrowserView: UIViewControllerRepresentable {
    let url: URL
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let browser = SFSafariViewController(url: url)
        browser.delegate = context.coordinator
        browser.dismissButtonStyle = .cancel
        return browser
    }

    func updateUIViewController(
        _ browser: SFSafariViewController, context: Context
    ) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCancel: onCancel) }

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onCancel: () -> Void
        init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onCancel()
        }
    }
}

struct AssistantBrowserModifier: ViewModifier {
    @Bindable var assistant: AssistantController
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { assistant.authorizationURL != nil },
                set: { showing in
                    if !showing, assistant.authorizationURL != nil {
                        assistant.cancelSignIn()
                    }
                }
            )) {
                if let url = assistant.authorizationURL {
                    AssistantBrowserView(url: url, onCancel: assistant.cancelSignIn)
                        .ignoresSafeArea()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { assistant.cancelSignIn() }
            }
    }
}

struct AssistantNotebookModifier: ViewModifier {
    @Bindable var assistant: AssistantController
    let isAvailable: Bool
    let notebookID: UUID
    let scopeGeneration: Int
    let tools: AssistantToolContext
    let prepareForChat: () -> Bool
    let resumeEditor: () -> Void
    let openNote: (AssistantNoteReference) -> Void
    @State private var showingChat = false
    @State private var keyboardVisibility = AssistantKeyboardVisibility.shared
    @State private var keyboardWindowID: ObjectIdentifier?
    @State private var pendingNoteReference: AssistantNoteReference?
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .background {
                AssistantKeyboardVisibilityProbe { window in
                    keyboardWindowID = keyboardVisibility.register(window)
                }
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            }
            .overlay(alignment: chatButtonAlignment) {
                if assistant.account != nil, !assistant.isConnecting,
                   isAvailable,
                   !keyboardVisibility.isVisible(in: keyboardWindowID) {
                    Button("AI Chat", systemImage: "sparkles") {
                        guard prepareForChat() else { return }
                        Task { @MainActor in
                            guard notebookID != .assistantUnavailableNotebook else { return }
                            await assistant.bindNotebook(notebookID, tools: tools)
                            showingChat = assistant.isNotebookBound
                        }
                    }
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .accessibilityIdentifier("assistant-open-chat")
                    .padding(16)
                }
            }
            .sheet(isPresented: $showingChat, onDismiss: chatDidDismiss) {
                AssistantChatView(
                    assistant: assistant,
                    openNote: { pendingNoteReference = $0; showingChat = false }
                )
            }
            .task { await assistant.restore() }
            .onChange(of: assistant.account) { _, account in
                pendingNoteReference = nil
                if account == nil, showingChat {
                    showingChat = false
                    assistant.unbindNotebook(notebookID)
                }
            }
            .onChange(of: notebookID) { oldID, newID in
                pendingNoteReference = nil
                if showingChat {
                    assistant.stop()
                    assistant.unbindNotebook(oldID)
                    showingChat = false
                }
            }
            .onChange(of: scopeGeneration) { _, _ in
                pendingNoteReference = nil
                if showingChat {
                    assistant.stop()
                    assistant.unbindNotebook(notebookID)
                    showingChat = false
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { assistant.stop() }
            }
    }

    private var chatButtonAlignment: Alignment {
        UIDevice.current.userInterfaceIdiom == .phone ? .bottomLeading : .bottom
    }

    private func chatDidDismiss() {
        resumeEditor()
        let reference = pendingNoteReference
        pendingNoteReference = nil
        guard let reference, reference.notebookID == notebookID else { return }
        openNote(reference)
    }
}

@MainActor
@Observable
private final class AssistantKeyboardVisibility {
    static let shared = AssistantKeyboardVisibility()

    private(set) var visibleWindowIDs = Set<ObjectIdentifier>()

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var windows: [ObjectIdentifier: WeakWindow] = [:]
    @ObservationIgnored private var keyboardScreenFrame: CGRect?

    private init() {
        let center = NotificationCenter.default
        for name in [
            UIResponder.keyboardWillShowNotification,
            UIResponder.keyboardDidShowNotification,
            UIResponder.keyboardDidChangeFrameNotification,
        ] {
            observers.append(center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] notification in
                let frame = notification.userInfo?[
                    UIResponder.keyboardFrameEndUserInfoKey
                ] as? CGRect
                MainActor.assumeIsolated {
                    self?.updateKeyboardFrame(frame: frame)
                }
            })
        }
        observers.append(center.addObserver(
            forName: UIResponder.keyboardDidHideNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.keyboardScreenFrame = nil
                self?.visibleWindowIDs.removeAll()
            }
        })
    }

    func register(_ window: UIWindow?) -> ObjectIdentifier? {
        guard let window else { return nil }
        let id = ObjectIdentifier(window)
        windows[id] = WeakWindow(window)
        updateVisibility(for: id)
        return id
    }

    func isVisible(in windowID: ObjectIdentifier?) -> Bool {
        guard let windowID else { return false }
        return visibleWindowIDs.contains(windowID)
    }

    private func updateKeyboardFrame(frame: CGRect?) {
        guard let frame else { return }
        keyboardScreenFrame = frame
        for id in Array(windows.keys) {
            updateVisibility(for: id)
        }
    }

    private func updateVisibility(for id: ObjectIdentifier) {
        guard let window = windows[id]?.value else {
            windows[id] = nil
            visibleWindowIDs.remove(id)
            return
        }
        guard let keyboardScreenFrame else {
            visibleWindowIDs.remove(id)
            return
        }
        let frame = window.convert(
            keyboardScreenFrame, from: window.screen.coordinateSpace
        )
        if frame.intersects(window.bounds), !frame.intersection(window.bounds).isEmpty {
            visibleWindowIDs.insert(id)
        } else {
            visibleWindowIDs.remove(id)
        }
    }
}

private final class WeakWindow {
    weak var value: UIWindow?

    init(_ value: UIWindow) {
        self.value = value
    }
}

private struct AssistantKeyboardVisibilityProbe: UIViewRepresentable {
    let onWindowChange: (UIWindow?) -> Void

    func makeUIView(context: Context) -> KeyboardWindowProbeView {
        let view = KeyboardWindowProbeView()
        view.onWindowChange = onWindowChange
        return view
    }

    func updateUIView(_ view: KeyboardWindowProbeView, context: Context) {
        view.onWindowChange = onWindowChange
    }
}

private final class KeyboardWindowProbeView: UIView {
    var onWindowChange: ((UIWindow?) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onWindowChange?(self.window)
        }
    }
}
#endif
