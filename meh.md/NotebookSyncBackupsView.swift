import NoteCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Where notes are kept and how they stay safe: sync, backups, space on this
/// device, and the tools for when something goes wrong.
struct NotebookSyncBackupsView: View {
    let replica: NotebookReplica
    let workspace: NotebookWorkspace
    @Binding var exporting: Bool
    let beforeExport: () async throws -> Void
    let onOpenNote: ((UUID) -> Void)?

    @State private var pending: NotebookSyncStorage?
    @State private var switching: NotebookSyncStorage?
    @State private var syncError: String?
    @State private var mismatchRequest: MismatchRequest?
    @State private var isVisible = false
    @State private var report: NotebookStorageReport?
    @State private var reportError: String?
    @State private var showingSyncEventLog = false
    @State private var confirmingReset = false
    @State private var resetScheduled = false

    var body: some View {
        Form {
            Section {
                Text(intro)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .accessibilityIdentifier("notebook-sync-backups-intro")
            }
            if workspace.canChooseSyncStorage {
                syncSection
            }
            // Signed out, the sync footer already says how to sign in.
            let setupError = workspace.syncFailure?.isSignedOut == true
                ? nil : workspace.syncSetupError
            if setupError != nil || workspace.notificationRegistrationError != nil {
                Section {
                    ForEach([setupError, workspace.notificationRegistrationError]
                        .compactMap { $0 }, id: \.self) { error in
                        Label {
                            Text(error)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .font(.callout)
                    }
                }
            }
            backupSection
            storageSection
            troubleshootingSection
            Section {
                Button("Reset All Local Data…", role: .destructive) {
                    confirmingReset = true
                }
                .foregroundStyle(.red)
                .disabled(exporting || resetScheduled || workspace.isResetPending)
                .accessibilityIdentifier("notebook-reset-local-data")
            } footer: {
                Text("Takes effect on the next launch. Unsynced changes are lost; synced notes and backups are kept.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Sync & Backups")
        .disabled(switching != nil)
        .task { await workspace.reloadBackupInfo() }
        .task(id: reportTrigger) { await measure() }
        .confirmationDialog(
            pending.map(confirmationTitle) ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible
        ) {
            if let pending {
                Button(String(confirmationTitle(pending).dropLast())) { switchTo(pending) }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            if let pending { Text(confirmationMessage(pending)) }
        }
        .sheet(item: $mismatchRequest) { request in
            NotebookStorageMismatchView(workspace: workspace, mismatch: request.mismatch)
        }
        .sheet(isPresented: $showingSyncEventLog) {
            NotebookSyncEventLogView(log: workspace.syncEventLog)
        }
        // A mismatch found while the S3 screen still covers this one is
        // offered once this screen is visible again.
        .onAppear {
            isVisible = true
            presentMismatch()
        }
        .onChange(of: workspace.storageMismatch) {
            if isVisible || workspace.storageMismatch == nil { presentMismatch() }
        }
        .onDisappear {
            isVisible = false
            workspace.dismissStorageSwitchHint()
        }
        .alert("Reset All Local Data?", isPresented: $confirmingReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset on Next Launch", role: .destructive) {
                let defaults = UserDefaults.standard
                defaults.set(true, forKey: "meh.md.resetLocalStorage")
                defaults.synchronize()
                workspace.localStorageResetWasScheduled()
                resetScheduled = true
            }
        } message: {
            Text("This cannot be undone. All local notes, including unsynced changes, settings, and sync history will be removed when you reopen the app. Local backups and notes already in iCloud or S3 storage are kept.")
        }
        .alert("Reset Scheduled", isPresented: $resetScheduled) {
            #if os(macOS)
            Button("Quit Now") { NSApplication.shared.terminate(nil) }
            #else
            Button("OK", role: .cancel) {}
            #endif
        } message: {
            Text("Quit and reopen meh.md to complete the reset. Any changes made before restarting will also be discarded.")
        }
    }

    // MARK: - Sections

    private var syncSection: some View {
        Section {
            storageRow(.iCloud)
            if workspace.hasSavedS3Settings {
                storageRow(.s3)
            } else {
                NavigationLink {
                    NotebookS3SettingsView(workspace: workspace)
                } label: {
                    LabeledContent {
                        Text("Set Up")
                    } label: {
                        NotebookSyncStorageTitle(storage: .s3)
                    }
                }
                .accessibilityIdentifier("sync-s3-settings")
            }
            storageRow(.off)
            if workspace.storageMismatch != nil {
                Button("Choose How to Sync…") { presentMismatch() }
                    .accessibilityIdentifier("sync-mismatch")
            }
            if let syncError {
                Text(syncError).foregroundStyle(.red)
            }
            if workspace.hasSavedS3Settings {
                NavigationLink("S3 Settings") {
                    NotebookS3SettingsView(workspace: workspace)
                }
                .accessibilityIdentifier("sync-s3-settings")
            }
        } header: {
            Text("Sync Notes With")
        } footer: {
            Text(syncFooter)
        }
    }

    private var backupSection: some View {
        Section {
            Picker("Automatic Backups", selection: Binding(
                get: { workspace.backupFrequency },
                set: { workspace.setBackupFrequency($0) }
            )) {
                ForEach(NotebookBackupFrequency.allCases) { frequency in
                    Text(frequency.title).tag(frequency)
                }
            }
            .accessibilityIdentifier("notebook-backup-frequency")
            Stepper(value: Binding(
                get: { workspace.backupRetentionCount },
                set: { workspace.setBackupRetentionCount($0) }
            ), in: 1...365) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep Latest \(workspace.backupRetentionCount)")
                    if let backupBytes {
                        Text("Uses \(storageBytes(backupBytes))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            #if os(macOS)
            LabeledContent {
                HStack(spacing: 8) {
                    if workspace.isBackingUp { ProgressView().controlSize(.small) }
                    Button(workspace.isBackingUp ? "Backing Up…" : "Back Up Now") { backUpNow() }
                        .disabled(workspace.isBackingUp || exporting)
                        .accessibilityIdentifier("notebook-backup-now")
                }
            } label: {
                Text("Last Backup")
                if let lastBackup = workspace.lastBackup {
                    Text(lastBackup.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .accessibilityIdentifier("notebook-last-backup")
                } else {
                    Text("Never")
                }
            }
            #else
            // The date is status, not a value to pick, so it sits under the
            // action as a subtitle.
            Button { backUpNow() } label: {
                LabeledContent {
                    if workspace.isBackingUp {
                        ProgressView().controlSize(.small)
                    }
                } label: {
                    Text(workspace.isBackingUp ? "Backing Up…" : "Back Up Now")
                        .foregroundStyle(.tint)
                    if let lastBackup = workspace.lastBackup {
                        Text("Last backup \(lastBackup.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .accessibilityIdentifier("notebook-last-backup")
                    }
                }
            }
            .disabled(workspace.isBackingUp || exporting)
            .accessibilityIdentifier("notebook-backup-now")
            #endif
            if let backupError = workspace.backupError {
                Text(backupError).foregroundStyle(.red)
            }
            Button("Export All Notes…") { exporting = true }
                .disabled(exporting)
                .accessibilityIdentifier("notebook-export")
        } header: {
            Text("Backups")
        } footer: {
            Text(backupFooter)
        }
    }

    private var storageSection: some View {
        Section {
            NavigationLink {
                NotebookStorageView(
                    replica: replica, workspace: workspace, onOpenNote: onOpenNote
                )
            } label: {
                if let report {
                    NotebookStorageOverview(report: report)
                } else if let reportError {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Couldn’t Measure Storage")
                        Text(reportError).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        Text("Measuring Storage…").foregroundStyle(.secondary)
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .accessibilityIdentifier("notebook-storage-settings")
        } header: {
            Text("On This Device")
        }
    }

    @ViewBuilder
    private var troubleshootingSection: some View {
        Section {
            if workspace.snapshotMaintenanceStatus != nil {
                NotebookCloudCleanupRows(workspace: workspace)
            }
            Button("Sync Event Log") { showingSyncEventLog = true }
                .accessibilityIdentifier("notebook-sync-event-log")
        } header: {
            Text("Troubleshooting")
        } footer: {
            if workspace.snapshotMaintenanceStatus != nil {
                Text("Removes older copies in \(workspace.syncStorageName). Notes and their history are kept. Also runs automatically.")
            }
        }
    }

    private func storageRow(_ storage: NotebookSyncStorage) -> some View {
        Button {
            guard storage != workspace.syncStorage else { return }
            syncError = nil
            pending = storage
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    NotebookSyncStorageTitle(storage: storage)
                    if storage == .s3, workspace.s3Configuration != nil {
                        // "Synced 1 minute ago" stays current while open.
                        TimelineView(.everyMinute) { _ in
                            if let detail = s3Detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Spacer()
                if switching == storage {
                    ProgressView()
                } else if storage == workspace.syncStorage {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Selected")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sync-storage-\(storage.rawValue)")
        .accessibilityAddTraits(storage == workspace.syncStorage ? .isSelected : [])
    }

    // MARK: - Text

    private var intro: String {
        #if os(macOS)
        let device = "this Mac"
        #else
        let device = "this device"
        #endif
        // Copies synced before signing out can still be in iCloud.
        if workspace.syncFailure?.isSignedOut == true {
            return "New changes are saved only on \(device)."
        }
        return workspace.usesSync
            ? "Your notes are saved on \(device) and in \(workspace.syncStorageDestination)."
            : "Your notes are saved only on \(device)."
    }

    private var backupFooter: String {
        #if os(macOS)
        "Backups stay on this Mac, in \(workspace.backupDirectory.path). Export your notes to keep a copy somewhere else."
        #else
        let device = UIDevice.current.userInterfaceIdiom == .pad
            ? "On My iPad" : "On My iPhone"
        return "Backups stay on this device, in Files › \(device) › meh.md › Backups. Export your notes to keep a copy somewhere else."
        #endif
    }

    private var syncFooter: String {
        let description = switch workspace.syncStorage {
        case .iCloud: workspace.syncFailure?.isSignedOut == true
            ? "Sign in to iCloud in the Settings app to sync with your other devices."
            : "Changes reach your other devices right away."
        case .s3: "Changes arrive about once a minute while meh.md is open."
        case .off: "Notes stay on this device only."
        }
        guard let change = workspace.recentStorageSwitch, change.to != .off else {
            return description
        }
        let reminder = change.from == .off
            ? "Turn on \(change.to.name) sync on your other devices too."
            : "Switch your other devices to \(change.to.name) too."
        return description + " " + reminder
    }

    /// Where S3 stores the notes and, while it is in use, how sync is going.
    private var s3Detail: LocalizedStringKey? {
        guard let configuration = workspace.s3Configuration else { return nil }
        let folder = configuration.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let location = folder.isEmpty ? configuration.bucket : configuration.bucket + "/" + folder
        guard workspace.syncStorage == .s3 else { return "\(location)" }
        if let failure = workspace.syncFailure {
            return "\(location) · \(String(localized: failure.title))"
        }
        if let date = workspace.lastSuccessfulSync {
            return "\(location) · Synced \(date, format: .relative(presentation: .named))"
        }
        return "\(location) · Not synced yet"
    }

    private func confirmationTitle(_ storage: NotebookSyncStorage) -> String {
        switch storage {
        case .iCloud: "Sync With iCloud?"
        case .s3: "Sync With S3 Storage?"
        case .off: "Turn Off Sync?"
        }
    }

    private func confirmationMessage(_ storage: NotebookSyncStorage) -> String {
        let current = workspace.syncStorage
        if storage == .off {
            return "A backup is made first. Changes on this device no longer reach your other devices."
        }
        if current == .off {
            return "A backup is made first. Then this device uploads its notes to \(storage.name)."
        }
        return "A backup is made first. Your \(current.name) copy stays as it is, but no longer gets changes from this device."
    }

    // MARK: - Storage

    private var backupBytes: Int64? {
        report?.categories.first { $0.category == .backups }?.byteCount
    }

    /// Measures again after a backup or a new retention count. The short wait
    /// skips measuring for every step while someone holds the stepper.
    private var reportTrigger: [Int] {
        [workspace.backupRetentionCount,
         workspace.lastBackup.map { Int($0.createdAt.timeIntervalSince1970) } ?? 0]
    }

    private func measure() async {
        if report != nil {
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
        }
        do {
            let measured = try await workspace.storageReport(for: replica)
            try Task.checkCancellation()
            report = measured
            reportError = nil
        } catch is CancellationError {
            // Leaving the screen cancels the measurement without an error.
        } catch {
            report = nil
            reportError = error.localizedDescription
        }
    }

    // MARK: - Actions

    private func backUpNow() {
        Task { @MainActor in
            try? await workspace.backupNow(beforeBackup: beforeExport)
        }
    }

    /// Each request is new, so the sheet opens again after it was dismissed.
    private func presentMismatch() {
        mismatchRequest = workspace.storageMismatch.map(MismatchRequest.init)
    }

    private func switchTo(_ storage: NotebookSyncStorage) {
        switching = storage
        pending = nil
        Task { @MainActor in
            defer { switching = nil }
            do {
                try await workspace.changeSyncStorage(storage)
            } catch {
                syncError = error.localizedDescription
            }
        }
    }
}

private struct MismatchRequest: Identifiable {
    let id = UUID()
    let mismatch: NotebookStorageMismatch
}

/// Cleans up old copies in iCloud or S3 by hand, next to when that last
/// happened.
private struct NotebookCloudCleanupRows: View {
    let workspace: NotebookWorkspace

    var body: some View {
        Button {
            Task { await workspace.requestCloudCopyCleanup() }
        } label: {
            HStack {
                Text("Clean Up \(workspace.syncStorageName) Copies")
                Spacer()
                if workspace.isCleaningCloudCopies { ProgressView() }
            }
        }
        .disabled(!workspace.canCleanCloudCopies)
        .accessibilityIdentifier("notebook-storage-cleanup")
        LabeledContent("Last Cleanup") {
            if let date = workspace.snapshotMaintenanceStatus?.lastSuccessfulCleanup {
                Text(date, format: .dateTime.year().month().day().hour().minute())
            } else {
                Text("Never")
            }
        }
        .accessibilityIdentifier("notebook-storage-last-cleanup")
        if let error = workspace.cloudCleanupError {
            VStack(alignment: .leading, spacing: 4) {
                Text("Couldn’t Clean Up \(workspace.syncStorageName) Copies")
                    .font(.headline)
                Text(error).foregroundStyle(.secondary)
            }
        }
    }
}
