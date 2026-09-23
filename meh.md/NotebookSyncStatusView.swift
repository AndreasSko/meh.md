import NoteCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct NotebookSyncButton: View {
    let workspace: NotebookWorkspace
    @State private var showingDetails = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let presentation = NotebookSyncPresentation(workspace: workspace, now: context.date)
            Button { showingDetails = true } label: {
                Image(systemName: presentation.indicator.symbol)
                    .foregroundStyle(presentation.indicatorColor)
                    .contentShape(Rectangle())
            }
            .help(presentation.accessibilityLabel)
            .accessibilityIdentifier("notebook-sync-details")
            .accessibilityLabel(presentation.accessibilityLabel)
            .accessibilityValue(presentation.accessibilityValue)
            .accessibilityHint("Show sync details")
            .popover(isPresented: $showingDetails) {
                NotebookSyncDetailsView(workspace: workspace)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }

}

struct NotebookWorkspaceStatusView: View {
    let workspace: NotebookWorkspace

    var body: some View {
        if workspace.copyError != nil || workspace.recoveryAction != nil
            || workspace.replica?.deletionCleanupErrorMessage != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let error = workspace.copyError {
                    Text("Markdown copies paused: \(error)")
                        .accessibilityIdentifier("markdown-copy-status")
                }
                if let error = workspace.replica?.deletionCleanupErrorMessage {
                    Text("Deleted note cleanup paused: \(error)")
                        .accessibilityIdentifier("notebook-deletion-cleanup-status")
                    Button("Retry Cleanup") {
                        Task { await workspace.refresh(manual: true) }
                    }
                    .disabled(workspace.isRefreshing)
                }
                if let action = workspace.recoveryAction {
                    Text(action.details + " Restoring may lose newer changes.")
                    Button(action.title) {
                        Task { await workspace.recoverPendingIssue() }
                    }
                    .disabled(workspace.isLoading || workspace.isRefreshing)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }
}

struct NotebookSyncDetailsView: View {
    let workspace: NotebookWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var showingEventLog = false

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
                if let fraction = presentation.fraction {
                    ProgressView(value: fraction)
                        .accessibilityLabel("Sync progress")
                        .accessibilityValue(
                            "\(Int((fraction * 100).rounded())) percent"
                        )
                } else if presentation.showsActivity {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Sync in progress")
                }
                if let progress = workspace.sync?.progress {
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
                if let error = workspace.notificationRegistrationError {
                    Text(error).font(.caption)
                }
                if case .failed(let error) = workspace.sync?.status {
                    Text(error).font(.caption)
                }
                Text("Progress counts saved revisions acknowledged by the sync service. Other devices receive them when they synchronize.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Sync Event Log") { showingEventLog = true }
                    .accessibilityIdentifier("notebook-sync-event-log")
                Button("Sync Now") { Task { await workspace.refresh(manual: true) } }
                    .disabled(workspace.isRefreshing || !workspace.usesSync)
                    .accessibilityIdentifier("sync-now")
            }
            .padding(20)
            .frame(idealWidth: 340, maxWidth: 420)
        }
        .presentationDetents([.medium, .large])
        .sheet(isPresented: $showingEventLog) {
            NotebookSyncEventLogView(log: workspace.syncEventLog)
        }
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
        guard workspace.usesSync else { return "Sync not enabled" }
        if let deadline = retryDeadline {
            let seconds = max(1, Int(ceil(deadline.timeIntervalSince(now))))
            return "Sync paused · retry available in \(seconds)s"
        }
        if workspace.isSyncing {
            if let progress = workspace.sync?.progress {
                switch progress.phase {
                case .uploadingNotes:
                    return "Uploading notes · \(progress.completedNotes) of \(progress.totalNotes)"
                case .uploadingCatalog: return "Updating folder structure…"
                case .cleaningUp: return "Removing deleted note copies…"
                case .receiving where progress.receivedRecords > 0:
                    return "Receiving changes · \(progress.receivedRecords) received"
                default: break
                }
            }
            return workspace.showSyncCheck ? "Checking for changes…" : nil
        }
        if workspace.syncSetupError != nil { return "Sync paused · open for details" }
        if case .failed = workspace.sync?.status { return "Sync paused · open for details" }
        if workspace.notificationRegistrationError != nil {
            return "Sync notifications unavailable · open for details"
        }
        if case .pending = workspace.sync?.status { return "Changes waiting to sync" }
        return nil
    }

    var fraction: Double? {
        guard workspace.isSyncing, retryDeadline == nil,
              let progress = workspace.sync?.progress, progress.phase == .uploadingNotes,
              progress.totalNotes > 0 else { return nil }
        return min(1, max(0, Double(progress.completedNotes) / Double(progress.totalNotes)))
    }

    var indicator: NotebookSyncIndicator {
        let failed: Bool
        if case .failed = workspace.sync?.status { failed = true }
        else { failed = false }
        let pending: Bool
        if case .pending = workspace.sync?.status { pending = true }
        else { pending = false }
        return NotebookSyncIndicator(
            isEnabled: workspace.usesSync,
            isSyncing: workspace.isSyncing,
            isRetryPaused: retryDeadline != nil,
            hasError: failed || workspace.syncSetupError != nil
                || workspace.notificationRegistrationError != nil,
            hasPendingChanges: pending
        )
    }

    var indicatorColor: Color {
        switch indicator {
        case .synced, .syncing: .primary
        case .failed: .orange
        case .disabled: .secondary
        }
    }

    var showsActivity: Bool {
        workspace.isSyncing && retryDeadline == nil
    }

    var accessibilityLabel: String {
        if let summary { return "Sync: \(summary)" }
        return "Sync"
    }

    var accessibilityValue: String {
        guard workspace.usesSync else { return "Not enabled" }
        if let fraction {
            return "\(Int((fraction * 100).rounded())) percent complete"
        }
        if showsActivity { return "In progress" }
        if retryDeadline != nil || workspace.syncSetupError != nil {
            return "Paused"
        }
        if case .failed = workspace.sync?.status { return "Error" }
        if workspace.notificationRegistrationError != nil {
            return "Automatic sync notifications unavailable"
        }
        if case .pending = workspace.sync?.status { return "Waiting to sync" }
        return lastSyncAccessibilityValue
    }

    private var lastSyncAccessibilityValue: String {
        if workspace.lastSuccessfulSync != nil { return "Up to date" }
        return "No completed sync in this session"
    }
}


private struct NotebookSyncEventLogView: View {
    let log: NotebookSyncEventLog
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Sync Event Log").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            Text("Recent events from this device. No note contents, names, paths, or account identifiers are recorded.")
                .font(.caption).foregroundStyle(.secondary)
            if log.persistenceError {
                Text("Some log history could not be loaded or saved. Current events are available below.")
                    .font(.caption).foregroundStyle(.orange)
            }
            ScrollView {
                Text(diagnosticText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("notebook-sync-event-log-text")
            HStack {
                Button(copied ? "Copied" : "Copy Log") {
                    #if os(macOS)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(diagnosticText, forType: .string)
                    #else
                    UIPasteboard.general.string = diagnosticText
                    #endif
                    copied = true
                }
                .accessibilityIdentifier("notebook-sync-event-log-copy")
                ShareLink("Share Log", item: diagnosticText)
                Spacer()
                Button("Clear Log") { log.clear(); copied = false }
            }
        }
        .padding(20)
        .frame(minWidth: 300, idealWidth: 680, minHeight: 360, idealHeight: 540)
    }

    private var diagnosticText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        #if os(macOS)
        let platform = "macOS"
        #else
        let platform = "iOS"
        #endif
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "meh.md \(version) (\(build)); \(platform) \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)\n" + log.exportText
    }
}
