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
            if workspace.welcome.isPresented {
                NotebookWelcomeView(
                    usesSync: workspace.usesSync,
                    isReady: workspace.replica?.catalogSnapshot != nil,
                    isLoading: workspace.isLoading,
                    failureMessage: workspace.syncFailure.map {
                        String(localized: $0.message)
                    } ?? workspace.errorMessage,
                    canRetry: workspace.canRetrySync,
                    choose: workspace.welcome.choose,
                    skip: workspace.welcome.dismiss,
                    retry: { Task { await workspace.start(manualRetry: true) } }
                )
            } else if let replica = workspace.replica, replica.catalogSnapshot != nil {
                NotebookView(
                    replica: replica,
                    workspace: workspace,
                    incomingImports: incomingImports,
                    sceneID: sceneID,
                    preferredNoteID: preferredNoteID
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
                ProgressView("Opening notebook…")
            }
        }
        .onOpenURL {
            workspace.welcome.dismiss()
            incomingImports.receive($0)
        }
        #if os(iOS)
        .onChange(of: NotebookQuickActionRequests.shared.pendingActionCount,
                  initial: true) { _, count in
            if count > 0 { workspace.welcome.dismiss() }
        }
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
            workspace.welcome.prepare(enabled: workspace.shouldOfferWelcome)
            await workspace.start()
            #if os(iOS)
            NotebookBackupBackgroundScheduler.scheduleNext()
            #endif
        }
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            workspace.sceneActivityChanged(id: sceneID, isActive: newPhase == .active)
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
