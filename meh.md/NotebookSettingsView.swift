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
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingReset = false
    @State private var resetScheduled = false
    @State private var importing = false
    @State private var saving = false
    @State private var preparing = false
    @State private var document: MarkdownExportDocument?
    @State private var exported = false
    @State private var errorMessage: String?
    @State private var destinationError: String?
    @State private var updatingDefaultDestination = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Destination", selection: Binding(
                        get: { replica.defaultNewNoteParentID },
                        set: { setDefaultNewNoteParentID($0) }
                    )) {
                        Text("Root").tag(UUID?.none)
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
                Section("Markdown") {
                    Button("Import Markdown…") { importing = true }
                        .accessibilityIdentifier("notebook-import")
                    Button("Export All Notes…") { exportAll() }
                        .accessibilityIdentifier("notebook-export")
                    if preparing { ProgressView("Preparing Markdown…") }
                }
                .disabled(preparing || saving)
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
                    .disabled(workspace.isBackingUp || preparing || saving)
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
                Section("Local Storage") {
                    Button("Reset All Local Data…", role: .destructive) {
                        confirmingReset = true
                    }
                    .foregroundStyle(.red)
                    .disabled(preparing || saving || resetScheduled)
                    Text("Removes local notes, settings, and sync data on the next launch. Unsynced changes will be lost. iCloud data and backups are kept.")
                        .font(.footnote)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(preparing || saving)
                }
            }
        }
        #if os(macOS)
        .frame(width: 480, height: 460)
        #endif
        .interactiveDismissDisabled(preparing || saving)
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
        .sheet(isPresented: $importing) {
            NotebookImportView(replica: replica, onImport: onImport)
        }
        .fileExporter(isPresented: $saving, document: document,
                      contentType: .folder, defaultFilename: "meh.md Export") { result in
            document = nil
            switch result {
            case .success:
                exported = true
            case .failure(let error):
                let cocoaError = error as NSError
                if cocoaError.domain != NSCocoaErrorDomain
                    || cocoaError.code != CocoaError.userCancelled.rawValue {
                    errorMessage = error.localizedDescription
                }
            }
        }
        .alert("Export Complete", isPresented: $exported) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("All notes were exported as Markdown.")
        }
        .alert("Couldn’t Export Notes", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
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

    private func exportAll() {
        guard !preparing, !saving else { return }
        preparing = true
        Task { @MainActor in
            defer { preparing = false }
            do {
                try await beforeExport()
                try await replica.flushOpenNotes()
                let placements = replica.placements
                let linkNotes = replica.linkNotes
                let notes = try await replica.persistedNoteSnapshots()
                let activeIDs = Set(placements.filter { !$0.isInTrash }.map { $0.item.id })
                document = MarkdownExportDocument(wrapper: try NotebookMarkdownExport.makeWrapper(
                    placements: placements, notes: notes, selectedIDs: activeIDs,
                    originalLinkNotes: linkNotes
                ))
                saving = true
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct MarkdownExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.folder] }
    let wrapper: FileWrapper
    init(wrapper: FileWrapper) { self.wrapper = wrapper }
    init(configuration: ReadConfiguration) throws { wrapper = configuration.file }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { wrapper }
}
