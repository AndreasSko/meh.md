import MehWidgetData
import NoteCore
import SwiftUI

struct NotebookApplicationView: View {
    let workspace: NotebookWorkspace
    let preferredNoteID: UUID?
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("notebook.sceneID") private var sceneIDString = UUID().uuidString
    @State private var fallbackSceneID = UUID()
    @State private var incomingImports = NotebookIncomingImportRequests()

    private var sceneID: UUID {
        UUID(uuidString: sceneIDString) ?? fallbackSceneID
    }

    var body: some View {
        Group {
            if let replica = workspace.replica, replica.catalogSnapshot != nil {
                NotebookView(
                    replica: replica,
                    workspace: workspace,
                    incomingImports: incomingImports,
                    sceneID: sceneID,
                    preferredNoteID: preferredNoteID ?? workspace.welcomeNoteID
                )
                    .id(ObjectIdentifier(replica))
            } else if let message = workspace.errorMessage {
                ContentUnavailableView {
                    Label("Notebook unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    if let failure = workspace.syncFailure {
                        Text(failure.message)
                        if let hint = failure.actionHint { Text(hint) }
                    } else {
                        Text(message)
                    }
                } actions: {
                    Button("Retry") {
                        Task { await workspace.start(manualRetry: true) }
                    }
                    .disabled(!workspace.canRetrySync)
                    if let action = workspace.recoveryAction {
                        Text(action.details + " Restoring may lose newer changes.")
                        Button(action.title) {
                            Task { await workspace.recoverPendingIssue() }
                        }
                    }
                    if workspace.isLoading { ProgressView("Restoring…") }
                }
                .disabled(workspace.isLoading)
            } else {
                NotebookOpeningView()
            }
        }
        // Continue the launch screen's paper while the notebook opens.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MehStyle.paperColor.ignoresSafeArea())
        #if os(macOS)
        // The Mac toolbar shows the window's own background above the detail
        // column; keep it paper instead of a white strip.
        .containerBackground(MehStyle.paperColor, for: .window)
        #endif
        .onOpenURL { url in
            if let link = MehWidgetLink(url: url) {
                NotebookQuickActionRequests.shared.receive(link, in: sceneID)
            } else {
                incomingImports.receive(url)
            }
        }
        #if os(macOS)
        // Widget links go to an open window instead of opening a new one.
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        #endif
        .mehAppearance()
        #if os(iOS)
        .overlay(alignment: .top) { NotebookStatusBarStrip() }
        #endif
        .overlay {
            if incomingImports.readingCount > 0 {
                ProgressView("Reading Markdown…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .alert("Couldn’t Read Shared Files", isPresented: Binding(
            get: { incomingImports.errorMessage != nil },
            set: { if !$0 { incomingImports.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(incomingImports.errorMessage ?? "")
        }
        .task {
            if UUID(uuidString: sceneIDString) == nil {
                sceneIDString = fallbackSceneID.uuidString
            }
            await workspace.start()
            #if os(iOS)
            NotebookBackupBackgroundScheduler.scheduleNext()
            #endif
        }
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            let phase: NotebookWorkspace.SceneActivityPhase
            switch newPhase {
            case .active: phase = .active
            case .inactive: phase = .inactive
            case .background: phase = .background
            @unknown default: phase = .inactive
            }
            workspace.sceneActivityChanged(id: sceneID, phase: phase)
            if newPhase == .active {
                Task {
                    await workspace.runDueBackup()
                    #if os(iOS)
                    NotebookBackupBackgroundScheduler.scheduleNext()
                    #endif
                }
            }
        }
        .onDisappear {
            workspace.sceneDidClose(id: sceneID)
        }
        .task(id: scenePhase) {
            // The loopback development service has no push channel. Only
            // that explicit test mode retains foreground polling.
            guard case .development = workspace.mode,
                  scenePhase == .active, workspace.automaticSync else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                workspace.requestAutomaticRefresh(trigger: "local service foreground check")
            }
        }
    }
}

/// Picks up where the launch screen leaves off: the face stays in the same
/// spot and starts blinking, with the progress underneath.
private struct NotebookOpeningView: View {
    var body: some View {
        MehFace(mood: .neutral)
            .overlay(alignment: .bottom) {
                ProgressView("Opening notebook…")
                    .fixedSize()
                    .alignmentGuide(.bottom) { $0[.top] - 20 }
            }
            // The launch image is centered on the whole screen, not the
            // safe area.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
    }
}

#if os(iOS)
/// On iPad, a paper-tinted blur behind the status bar keeps the clock
/// readable over scrolled content. It fades out within the status bar,
/// so the buttons below stay sharp.
private struct NotebookStatusBarStrip: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if sizeClass == .regular {
            Color.clear.frame(height: 0)
                .background {
                    // Paper tint instead of the material's grey.
                    Rectangle().fill(.ultraThinMaterial)
                        .overlay(MehStyle.paperColor.opacity(0.7))
                        .mask(LinearGradient(
                            stops: [.init(color: .black, location: 0.5),
                                    .init(color: .clear, location: 1)],
                            startPoint: .top, endPoint: .bottom
                        ))
                        .ignoresSafeArea(edges: .top)
                }
                .allowsHitTesting(false)
        }
    }
}
#endif
