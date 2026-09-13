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
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if oldPhase != .active, newPhase == .active, workspace.automaticSync {
                Task { await workspace.refresh() }
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active, workspace.automaticSync else { return }
            // Initial activation and saved edits already request exchanges.
            // Quiet foreground checks discover changes from other devices.
            // Engine-driven background delivery remains a separate stage.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                await workspace.refresh()
            }
        }
    }
}
