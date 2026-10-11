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
        // Only a retry countdown depends on the clock; otherwise the
        // toolbar button redraws when the workspace changes.
        TimelineView(.animation(
            minimumInterval: 1, paused: workspace.syncRetryNotBefore == nil
        )) { context in
            let presentation = NotebookSyncPresentation(workspace: workspace, now: context.date)
            Button {
                showingDetails = true
                Task { await workspace.requestSyncFromStatus() }
            } label: {
                Image(systemName: presentation.showsActivity ? "icloud" : presentation.indicator.symbol)
                    .foregroundStyle(presentation.indicatorColor)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonBorderShape(.circle)
            .overlay {
                if presentation.showsActivity {
                    NotebookSyncRing(fraction: presentation.activity.fraction)
                }
            }
            .help(String(localized: presentation.title))
            .accessibilityIdentifier("notebook-sync-details")
            .accessibilityLabel("Sync with iCloud")
            .accessibilityValue(presentation.accessibilityValue)
            .accessibilityHint(presentation.showsActivity ? "Show current sync activity" : "Sync now and show status")
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

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let presentation = NotebookSyncPresentation(workspace: workspace, now: context.date)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(presentation.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("note-sync-status")
                    if presentation.showsActivity {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.blue)
                            .accessibilityLabel("Sync in progress")
                            .accessibilityIdentifier("notebook-sync-activity")
                    }
                }
                if presentation.showsActivity {
                    NotebookSyncFilesView(files: presentation.activeFiles)
                    if let hint = presentation.activity.hint {
                        Text(hint).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("notebook-sync-activity-hint")
                    }
                    if let fraction = presentation.activity.fraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .tint(.blue)
                            .accessibilityLabel("Sync progress")
                            .accessibilityValue(presentation.accessibilityValue)
                            .accessibilityIdentifier("notebook-sync-progress")
                    }
                } else {
                    NotebookSyncFailureView(workspace: workspace)
                }
                if let date = workspace.lastSuccessfulSync {
                    Text("Last synced \(date, format: .relative(presentation: .named))")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("notebook-sync-last-success")
                }
            }
            .padding(20)
            .frame(idealWidth: 320, maxWidth: 380, alignment: .leading)
        }
        .presentationSizing(.fitted)
    }
}

private struct NotebookSyncFilesView: View {
    let files: [NotebookSyncActiveFile]
    @State private var expanded = false

    var body: some View {
        if let first = files.first {
            VStack(alignment: .leading, spacing: 6) {
                if expanded && files.count > 1 {
                    NotebookSyncFilesDisclosure(count: files.count - 1, expanded: $expanded)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            NotebookSyncFilename(file: first, showsFolder: false)
                            if files.count > 1 {
                                NotebookSyncFilesDisclosure(count: files.count - 1, expanded: $expanded)
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            NotebookSyncFilename(file: first, showsFolder: false)
                            if files.count > 1 {
                                NotebookSyncFilesDisclosure(count: files.count - 1, expanded: $expanded)
                            }
                        }
                    }
                }
                if expanded && files.count > 1 {
                    if files.count <= 4 {
                        fileRows
                    } else {
                        ScrollView { fileRows }
                            .frame(height: 180)
                            .accessibilityIdentifier("notebook-sync-active-file-list")
                    }
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .onChange(of: files.map(\.id)) { _, _ in expanded = false }
        }
    }

    private var fileRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(files) { file in
                NotebookSyncFilename(file: file, showsFolder: true)
                    .accessibilityIdentifier("notebook-sync-active-file-\(file.id.uuidString)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

private struct NotebookSyncFilename: View {
    let file: NotebookSyncActiveFile
    let showsFolder: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let name = file.name { Text(verbatim: name) }
            else { Text("A note") }
            if showsFolder, let folder = file.folder {
                if folder.isEmpty { Text("Root").font(.caption) }
                else { Text(verbatim: folder).font(.caption) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct NotebookSyncFilesDisclosure: View {
    let count: Int
    @Binding var expanded: Bool

    var body: some View {
        Button { expanded.toggle() } label: {
            if expanded { Text("Hide filenames") }
            else if count == 1 { Text("and 1 other") }
            else { Text("and \(count) others") }
        }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            .padding(.vertical, 6)
            .accessibilityLabel(expanded ? "Hide filenames" : "Show all filenames")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("notebook-sync-active-files")
    }
}

private struct NotebookSyncFailureView: View {
    let workspace: NotebookWorkspace

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if workspace.isSyncUpdateRequired {
                Text("Update meh.md to resume iCloud sync. You can keep editing your notes on this device.")
                    .accessibilityIdentifier("sync-update-required")
            } else if let failure = workspace.syncFailure {
                Text(failure.message)
                    .accessibilityIdentifier("sync-failure-explanation")
                if let hint = failure.actionHint {
                    Text(hint).foregroundStyle(.secondary)
                }
                if workspace.replica?.catalogSnapshot != nil,
                   workspace.replica?.localEditsSuspended == false {
                    Text("Notes stay on this device while sync is unavailable.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("sync-local-saving-explanation")
                }
                if workspace.canRetrySync {
                    Button("Try Again") {
                        Task { await workspace.requestSyncFromStatus() }
                    }
                    .disabled(workspace.isRefreshing || workspace.syncRetryNotBefore.map { $0 > Date() } == true)
                    .accessibilityIdentifier("sync-now")
                }
            } else if workspace.syncSetupError != nil {
                Text("Sync is paused. Open Settings → Diagnostics for details.")
            } else if workspace.notificationRegistrationError != nil {
                Text("Open Settings → Diagnostics for details about automatic sync notifications.")
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct NotebookSyncPresentation {
    let workspace: NotebookWorkspace
    let now: Date

    var retryDeadline: Date? {
        guard let deadline = workspace.syncRetryNotBefore, deadline > now else { return nil }
        return deadline
    }

    var showsActivity: Bool {
        workspace.usesSync && workspace.isSyncing && retryDeadline == nil
            && !workspace.isSyncUpdateRequired
    }

    var activity: NotebookSyncActivityPresentation {
        NotebookSyncActivityPresentation(isActive: showsActivity, progress: workspace.sync?.progress)
    }

    var activeFiles: [NotebookSyncActiveFile] {
        NotebookSyncActiveFile.resolve(ids: activity.activeNoteIDs,
                                       placements: workspace.replica?.placements ?? [])
    }

    var title: LocalizedStringResource {
        guard workspace.usesSync else { return "Sync not enabled" }
        if workspace.isSyncUpdateRequired { return "Update needed to sync" }
        if retryDeadline != nil { return "Waiting to retry…" }
        if showsActivity { return activity.title }
        if let failure = workspace.syncFailure { return failure.title }
        if workspace.syncSetupError != nil { return "Sync needs attention" }
        if case .failed = workspace.sync?.status { return "Sync needs attention" }
        if workspace.notificationRegistrationError != nil { return "Sync notifications unavailable" }
        if case .pending = workspace.sync?.status { return "Changes waiting to sync" }
        return workspace.lastSuccessfulSync == nil ? "Ready to sync" : "Synced with iCloud"
    }

    var indicator: NotebookSyncIndicator {
        let failed: Bool
        if case .failed = workspace.sync?.status { failed = true }
        else { failed = false }
        let pending: Bool
        if case .pending = workspace.sync?.status { pending = true }
        else { pending = false }
        return NotebookSyncIndicator(
            isEnabled: workspace.usesSync, isSyncing: workspace.isSyncing,
            isRetryPaused: retryDeadline != nil || workspace.isSyncUpdateRequired,
            hasError: workspace.isSyncUpdateRequired || failed || workspace.syncSetupError != nil
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

    var accessibilityValue: LocalizedStringResource {
        if let fraction = activity.fraction {
            let percent = Int((fraction * 100).rounded())
            return "\(percent) percent of notes sent"
        }
        return title
    }
}

private struct NotebookSyncRing: View {
    let fraction: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion || fraction != nil)) { context in
            let angle = fraction != nil || reduceMotion ? -90
                : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6 * 360 - 90
            Circle()
                .trim(from: 0, to: max(0.01, fraction ?? 0.23))
                .stroke(.blue, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .rotationEffect(.degrees(angle))
                #if os(iOS)
                .padding(-4)
                #else
                .padding(1)
                #endif
                .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: fraction)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct NotebookSyncEventLogView: View {
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
                    .accessibilityIdentifier("notebook-sync-event-log-text")
            }
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
