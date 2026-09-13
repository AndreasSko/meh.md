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
        .task(id: scenePhase) {
            guard scenePhase == .active, workspace.automaticSync,
                  workspace.usesSync else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                await workspace.refresh()
            }
        }
    }
}

struct NotebookWorkspaceStatusView: View {
    let workspace: NotebookWorkspace
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(workspace.label)
                Spacer(minLength: 8)
                if workspace.usesSync {
                    Text(syncStatusText).accessibilityIdentifier("note-sync-status")
                    Button("Sync Now") { Task { await workspace.refresh() } }
                        .disabled(workspace.isRefreshing)
                        .accessibilityIdentifier("sync-now")
                }
            }
            if let error = workspace.legacySyncError {
                Text("Older-note sync paused: \(error)")
            }
            if let action = workspace.recoveryAction {
                Text(action.details + " Restoring may lose newer changes.")
                Button(action.title) { Task { await workspace.recoverPendingIssue() } }
                    .disabled(workspace.isLoading || workspace.isRefreshing)
            }
            if let error = workspace.copyError {
                Text("Markdown copies paused: \(error)")
                    .accessibilityIdentifier("markdown-copy-status")
            } else if let url = workspace.copiesURL {
                Text("Markdown copies: \(url.path)")
                    .lineLimit(1).truncationMode(.middle)
                    .help(url.path)
                    .accessibilityIdentifier("markdown-copy-status")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(8).frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var syncStatusText: String {
        if let error = workspace.syncSetupError { return "Sync paused: \(error)" }
        if workspace.isRefreshing { return "Syncing…" }
        guard let sync = workspace.sync else { return "Ready to sync" }
        switch sync.status {
        case .idle: return "Ready to sync"
        case .syncing: return "Syncing…"
        case .pending: return "Changes waiting to sync"
        case .exchanged(let date):
            return "Last sync: \(date.formatted(date: .omitted, time: .standard))"
        case .failed(let message): return "Sync paused: \(message)"
        }
    }
}
