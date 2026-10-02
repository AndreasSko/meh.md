import NoteCore
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct NotebookSettingsView: View {
    let replica: NotebookReplica
    let workspace: NotebookWorkspace
    let onImport: (NotebookImportPlan?) async throws -> Void
    let beforeExport: () async throws -> Void
    var onOpenNote: ((UUID) -> Void)? = nil
    var onShowWelcome: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingReset = false
    @State private var resetScheduled = false
    @State private var importing = false
    @State private var choosingImportSource = false
    @State private var importingFolder = false
    @State private var exporting = false
    @State private var destinationError: String?
    @State private var updatingDefaultDestination = false
    @State private var showingSyncEventLog = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Destination", selection: Binding(
                        get: { replica.defaultNewNoteParentID },
                        set: { setDefaultNewNoteParentID($0) }
                    )) {
                        Text("Top Level").tag(UUID?.none)
                        ForEach(activeFolders, id: \.item.id) { placement in
                            Text(folderPath(for: placement))
                                .tag(Optional(placement.item.id))
                        }
                    }
                    .disabled(updatingDefaultDestination)
                    .accessibilityIdentifier("notebook-new-note-destination")
                } header: {
                    Text("New Notes")
                } footer: {
                    Text("New notes are saved in this folder.")
                }
                Section {
                    NavigationLink {
                        NotebookTemplatesSettingsView(
                            replica: replica, onOpenNote: onOpenNote
                        )
                    } label: {
                        Label("Templates & Snippets", systemImage: "doc.on.doc")
                    }
                    .accessibilityIdentifier("notebook-templates-settings")
                }
                Section("Markdown") {
                    Button("Import Markdown…") {
                        #if os(iOS)
                        choosingImportSource = true
                        #else
                        importing = true
                        #endif
                    }
                        .accessibilityIdentifier("notebook-import")
                        #if os(iOS)
                        .confirmationDialog(
                            "Import Markdown", isPresented: $choosingImportSource
                        ) {
                            Button("Import Files…") {
                                importingFolder = false
                                importing = true
                            }
                            Button("Import Folder…") {
                                importingFolder = true
                                importing = true
                            }
                        }
                        #endif
                    Button("Export All Notes…") { exporting = true }
                        .accessibilityIdentifier("notebook-export")
                }
                .disabled(exporting)
                Section {
                    Picker("Frequency", selection: Binding(
                        get: { workspace.backupFrequency },
                        set: { workspace.setBackupFrequency($0) }
                    )) {
                        ForEach(NotebookBackupFrequency.allCases) { frequency in
                            Text(frequency.title).tag(frequency)
                        }
                    }
                    Stepper(value: Binding(
                        get: { workspace.backupRetentionCount },
                        set: { workspace.setBackupRetentionCount($0) }
                    ), in: 1...365) {
                        Text("Keep latest \(workspace.backupRetentionCount)")
                    }
                    Button { backUpNow() } label: {
                        HStack {
                            Text(workspace.isBackingUp ? "Backing Up…" : "Back Up Now")
                            Spacer()
                            if workspace.isBackingUp {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(workspace.isBackingUp || exporting)
                    .accessibilityIdentifier("notebook-backup-now")
                    if let lastBackup = workspace.lastBackup {
                        LabeledContent("Last backup",
                            value: lastBackup.createdAt.formatted(
                                date: .abbreviated, time: .shortened
                            ))
                    }
                    if let backupError = workspace.backupError {
                        Text(backupError).foregroundStyle(.red)
                    }
                } header: {
                    Text("Automatic Backups")
                } footer: {
                    #if os(macOS)
                    Text("In Finder, use Go to Folder to open \(workspace.backupDirectory.deletingLastPathComponent().path). Current notes are in Notebook Copies/Markdown; backups are in Backups. Trash is not included.")
                    #else
                    let device = UIDevice.current.userInterfaceIdiom == .pad
                        ? "On My iPad" : "On My iPhone"
                    Text("In Files, open \(device) › meh.md. Current notes are in Notebook Copies/Markdown; backups are in Backups. Trash is not included.")
                    #endif
                }
                Section {
                    NavigationLink {
                        NotebookStorageView(
                            replica: replica, workspace: workspace,
                            onOpenNote: onOpenNote
                        )
                    } label: {
                        Label("Storage", systemImage: "internaldrive")
                    }
                    .accessibilityIdentifier("notebook-storage-settings")
                }
                Section("Help") {
                    Button("Getting Started…", action: onShowWelcome)
                        .accessibilityIdentifier("notebook-getting-started")
                }
                Section("Local Storage") {
                    Button("Reset All Local Data…", role: .destructive) {
                        confirmingReset = true
                    }
                    .foregroundStyle(.red)
                    .disabled(exporting || resetScheduled)
                    Text("Removes local notes, settings, and sync data on the next launch. Unsynced changes will be lost. iCloud data and backups are kept.")
                        .font(.footnote)
                }
                Section("Diagnostics") {
                    Button("Sync Event Log") { showingSyncEventLog = true }
                        .accessibilityIdentifier("notebook-sync-event-log")
                    if let error = workspace.syncSetupError {
                        Text(error).font(.caption)
                    }
                    if let error = workspace.notificationRegistrationError {
                        Text(error).font(.caption)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(exporting)
                }
            }
        }
        #if os(macOS)
        .frame(width: 480, height: 460)
        #endif
        .interactiveDismissDisabled(exporting)
        .sheet(isPresented: $showingSyncEventLog) {
            NotebookSyncEventLogView(log: workspace.syncEventLog)
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
            Text("This cannot be undone. All local notes, including unsynced changes, settings, and sync history will be removed when you reopen the app. Local backups and notes already in iCloud are kept.")
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
        .notebookMarkdownImporter(
            isPresented: $importing, choosingFolder: importingFolder,
            replica: replica, onImport: onImport
        )
        .notebookMarkdownExporter(
            isPresented: $exporting, replica: replica, beforeExport: beforeExport
        )
        .alert("Couldn’t Change Destination", isPresented: Binding(
            get: { destinationError != nil },
            set: { if !$0 { destinationError = nil } }
        )) {
            Button("OK", role: .cancel) { destinationError = nil }
        } message: {
            Text(destinationError ?? "")
        }
        .task { await workspace.reloadBackupInfo() }
    }

    private var activeFolders: [NotebookPlacement] {
        replica.placements
            .filter { $0.item.kind == .folder && !$0.isInTrash }
            .sorted {
                folderPath(for: $0).localizedStandardCompare(folderPath(for: $1))
                    == .orderedAscending
            }
    }

    private func folderPath(for placement: NotebookPlacement) -> String {
        let byID = Dictionary(uniqueKeysWithValues: replica.placements.map {
            ($0.item.id, $0)
        })
        var parts = [placement.displayName]
        var parentID = placement.parentID
        while let id = parentID, let parent = byID[id] {
            parts.insert(parent.displayName, at: 0)
            parentID = parent.parentID
        }
        return parts.joined(separator: " / ")
    }

    private func setDefaultNewNoteParentID(_ id: UUID?) {
        guard !updatingDefaultDestination else { return }
        updatingDefaultDestination = true
        Task { @MainActor in
            defer { updatingDefaultDestination = false }
            do {
                try await replica.setDefaultNewNoteParentID(id)
            } catch {
                destinationError = error.localizedDescription
            }
        }
    }

    private func backUpNow() {
        Task { @MainActor in
            try? await workspace.backupNow(beforeBackup: beforeExport)
        }
    }

}
