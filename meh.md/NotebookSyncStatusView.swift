import NoteCore
import SwiftUI

struct NotebookWorkspaceStatusView: View {
    let workspace: NotebookWorkspace
    @State private var showingDetails = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let presentation = NotebookSyncPresentation(workspace: workspace, now: context.date)
            if presentation.summary != nil || workspace.copyError != nil
                || workspace.recoveryAction != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if let summary = presentation.summary {
                        Button { showingDetails = true } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Label(summary, systemImage: presentation.symbol)
                                        .accessibilityIdentifier("note-sync-status")
                                    Spacer(minLength: 8)
                                    Image(systemName: "info.circle")
                                }
                                if let fraction = presentation.fraction {
                                    ProgressView(value: fraction)
                                } else if workspace.isSyncing,
                                          presentation.retryDeadline == nil {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Show sync details")
                    }
                    if let error = workspace.copyError {
                        Text("Markdown copies paused: \(error)")
                            .accessibilityIdentifier("markdown-copy-status")
                    }
                    if let action = workspace.recoveryAction {
                        Text(action.details + " Restoring may lose newer changes.")
                        Button(action.title) { Task { await workspace.recoverPendingIssue() } }
                            .disabled(workspace.isLoading || workspace.isRefreshing)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(8).frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
        .popover(isPresented: $showingDetails) {
            NotebookSyncDetailsView(workspace: workspace)
        }
    }
}

struct NotebookSyncDetailsView: View {
    let workspace: NotebookWorkspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let presentation = NotebookSyncPresentation(workspace: workspace, now: context.date)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Sync").font(.headline)
                    Spacer()
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("notebook-sync-details-close")
                }
                Text(presentation.summary ?? lastSyncText)
                    .accessibilityIdentifier("note-sync-status")
                if presentation.summary != nil { Text(lastSyncText).font(.caption) }
                if let progress = workspace.sync?.progress, !workspace.checkingLegacySync {
                    if progress.totalNotes > 0 {
                        Text("Notes uploaded this pass: \(progress.completedNotes) of \(progress.totalNotes)")
                    }
                    if progress.receivedRecords > 0 {
                        Text("Changes received this pass: \(progress.receivedRecords)")
                    }
                    Text("Last activity: \(progress.lastProgressAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = workspace.syncSetupError { Text(error).font(.caption) }
                if case .failed(let error) = workspace.sync?.status {
                    Text(error).font(.caption)
                }
                if let error = workspace.legacySyncError {
                    Text("Older-note compatibility: \(error)").font(.caption)
                }
                Text("Progress counts saved revisions acknowledged by the sync service. Other devices receive them when they synchronize.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Sync Now") { Task { await workspace.refresh(manual: true) } }
                    .disabled(workspace.isRefreshing)
                    .accessibilityIdentifier("sync-now")
            }
            .padding(20)
            .frame(idealWidth: 340, maxWidth: 420)
        }
        .presentationDetents([.medium, .large])
    }

    private var lastSyncText: String {
        if let date = workspace.lastSuccessfulSync {
            return "Last sync: \(date.formatted(date: .omitted, time: .standard))"
        }
        return "No completed sync in this session"
    }
}

private struct NotebookSyncPresentation {
    let workspace: NotebookWorkspace
    let now: Date

    var retryDeadline: Date? {
        guard let deadline = workspace.syncRetryNotBefore, deadline > now else { return nil }
        return deadline
    }

    var summary: String? {
        guard workspace.usesSync else { return nil }
        if let deadline = retryDeadline {
            let seconds = max(1, Int(ceil(deadline.timeIntervalSince(now))))
            return "Sync paused · retry available in \(seconds)s"
        }
        if workspace.isSyncing {
            if !workspace.checkingLegacySync, let progress = workspace.sync?.progress {
                switch progress.phase {
                case .uploadingNotes:
                    return "Uploading notes · \(progress.completedNotes) of \(progress.totalNotes)"
                case .uploadingCatalog: return "Updating folder structure…"
                case .receiving where progress.receivedRecords > 0:
                    return "Receiving changes · \(progress.receivedRecords) received"
                default: break
                }
            }
            return workspace.showSyncCheck ? "Checking for changes…" : nil
        }
        if workspace.syncSetupError != nil { return "Sync paused · open for details" }
        if case .failed = workspace.sync?.status { return "Sync paused · open for details" }
        if workspace.legacySyncError != nil { return "Some changes could not sync · open for details" }
        if case .pending = workspace.sync?.status { return "Changes waiting to sync" }
        return nil
    }

    var fraction: Double? {
        guard workspace.isSyncing, !workspace.checkingLegacySync, retryDeadline == nil,
              let progress = workspace.sync?.progress, progress.phase == .uploadingNotes,
              progress.totalNotes > 0 else { return nil }
        return min(1, max(0, Double(progress.completedNotes) / Double(progress.totalNotes)))
    }

    var symbol: String {
        if retryDeadline != nil { return "pause.circle" }
        if !workspace.isSyncing, summary != nil { return "exclamationmark.icloud" }
        return "arrow.triangle.2.circlepath"
    }
}
