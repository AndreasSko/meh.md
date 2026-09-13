import NoteCore
import SwiftUI

struct NotebookApplicationView: View {
    let workspace: NotebookWorkspace
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let replica = workspace.replica, replica.catalogSnapshot != nil {
                NotebookView(replica: replica, workspace: workspace)
            } else if let message = workspace.errorMessage {
                ContentUnavailableView {
                    Label("Notebook unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") { Task { await workspace.start() } }
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
        .task { await workspace.start() }
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            workspace.sceneActivityChanged(isActive: newPhase == .active)
        }
        .task(id: scenePhase) {
            // The loopback development service has no push channel. Only
            // that explicit test mode retains foreground polling.
            guard case .development = workspace.mode,
                  scenePhase == .active, workspace.automaticSync else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                await workspace.refresh(trigger: "local service foreground check")
            }
        }
    }
}
