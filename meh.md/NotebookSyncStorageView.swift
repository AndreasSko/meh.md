import NoteCore
import SwiftUI

/// Where notes sync. iCloud is the default and needs no setup. Turning sync
/// off and the S3 beta are there for people who want them, without getting
/// in the way of everyone else.
struct NotebookSyncSettingsView: View {
    let workspace: NotebookWorkspace
    @State private var pending: NotebookSyncStorage?
    @State private var pendingChoice: NotebookWorkspace.StorageMismatchChoice?
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            if let mismatch = workspace.storageMismatch {
                mismatchSection(mismatch)
            }
            Section {
                storageRow(.iCloud, detail: "Recommended")
                if workspace.syncStorage == .s3 || workspace.hasSavedS3Settings {
                    storageRow(.s3, detail: "Beta")
                }
                storageRow(.off, detail: nil)
            } header: {
                Text("Sync Notes With")
            } footer: {
                Text(description(of: workspace.syncStorage))
            }
            if let change = workspace.recentStorageSwitch, change.to != .off {
                Section {
                    Label {
                        Text(otherDevicesHint(from: change.from, to: change.to))
                    } icon: {
                        Image(systemName: "laptopcomputer.and.iphone")
                    }
                    .accessibilityIdentifier("sync-other-devices-hint")
                }
            }
            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            Section {
                NavigationLink {
                    NotebookS3SettingsView(workspace: workspace)
                } label: {
                    LabeledContent("S3 Storage") { Text("Beta") }
                }
                .accessibilityIdentifier("sync-s3-settings")
            } header: {
                Text("Advanced")
            } footer: {
                Text("Sync through Amazon S3 or another S3-compatible storage you run yourself, instead of iCloud.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Sync")
        .disabled(working)
        .confirmationDialog(
            pending.map(confirmationTitle) ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible
        ) {
            if let pending {
                Button(actionTitle(confirmationTitle(pending))) { switchTo(pending) }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            if let pending { Text(confirmationMessage(pending)) }
        }
        .confirmationDialog(
            pendingChoice.map(choiceTitle) ?? "",
            isPresented: Binding(
                get: { pendingChoice != nil }, set: { if !$0 { pendingChoice = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingChoice {
                Button(actionTitle(choiceTitle(pendingChoice))) { resolve(pendingChoice) }
            }
            Button("Cancel", role: .cancel) { pendingChoice = nil }
        } message: {
            if let pendingChoice { Text(choiceMessage(pendingChoice)) }
        }
        .onDisappear { workspace.dismissStorageSwitchHint() }
    }

    private func storageRow(_ storage: NotebookSyncStorage, detail: String?) -> some View {
        Button {
            guard storage != workspace.syncStorage else { return }
            errorMessage = nil
            pending = storage
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(storage.title).foregroundStyle(.primary)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if working, pending == storage {
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

    private func mismatchSection(_ mismatch: NotebookStorageMismatch) -> some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(storageName) Has Other Notes").font(.headline)
                    Text(mismatchMessage(mismatch))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "rectangle.stack.badge.plus").foregroundStyle(.tint)
            }
            Button("Combine Notebooks") { pendingChoice = .combine }
                .accessibilityIdentifier("sync-mismatch-combine")
            Button("Use the Notes in \(storageName)") { pendingChoice = .useStored }
                .accessibilityIdentifier("sync-mismatch-use-stored")
            if let previous = workspace.previousSyncStorage {
                Button(previous == .off ? "Turn Sync Off Again" : "Go Back to \(previous.title)") {
                    resolve(.switchBack)
                }
                .accessibilityIdentifier("sync-mismatch-switch-back")
            }
        } footer: {
            Text("Nothing has changed yet. A backup of this device’s notes is made before either choice.")
        }
        .accessibilityIdentifier("sync-mismatch")
    }

    // MARK: - Text

    private var storageName: String { workspace.syncStorage.title }

    private func description(of storage: NotebookSyncStorage) -> String {
        switch storage {
        case .iCloud:
            "Notes sync through your iCloud account and arrive on your other devices right away."
        case .s3:
            "Notes sync through your S3 storage. Changes from your other devices arrive while meh.md is open, within about a minute."
        case .off:
            "Notes are saved only on this device. Turn sync on to get them on your other devices."
        }
    }

    private func otherDevicesHint(from: NotebookSyncStorage, to: NotebookSyncStorage) -> String {
        let target = to == .s3 ? "S3 storage" : "iCloud"
        if from == .off {
            return "To see your notes on your other devices, sync them with \(target) too."
        }
        return "Switch your other devices to \(target) too. Until then, they keep syncing with \(from == .s3 ? "S3 storage" : "iCloud") and don’t see changes from this device."
    }

    private func mismatchMessage(_ mismatch: NotebookStorageMismatch) -> String {
        let notes = mismatch.noteCount.map { $0 == 1 ? " with 1 note" : " with \($0) notes" } ?? ""
        return "\(storageName) already holds a different notebook\(notes). Choose what to do with the notes on this device."
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
        switch storage {
        case .off:
            return "A backup is made first. Your notes stay on this device, and your \(current.title) copy stays as it is. Changes on this device no longer reach your other devices."
        case .iCloud, .s3:
            let leaving = current == .off
                ? "" : " Your \(current.title) copy stays, but no longer gets changes from this device."
            return "A backup is made first. Then this device syncs with \(storage.title) and uploads what it is missing.\(leaving)"
        }
    }

    /// The dialog asks; its button states the action.
    private func actionTitle(_ question: String) -> String {
        question.hasSuffix("?") ? String(question.dropLast()) : question
    }

    private func choiceTitle(_ choice: NotebookWorkspace.StorageMismatchChoice) -> String {
        switch choice {
        case .combine: "Combine Notebooks?"
        case .useStored: "Use the Notes in \(storageName)?"
        case .switchBack: ""
        }
    }

    private func choiceMessage(_ choice: NotebookWorkspace.StorageMismatchChoice) -> String {
        switch choice {
        case .combine:
            return "This device’s notes are added to the notebook in \(storageName), in a folder named “\(workspace.combineFolderName)”. Notes that are already in both are merged."
        case .useStored:
            return "This device shows the notebook from \(storageName) instead of its own. Its current notes are kept in a backup on this device."
        case .switchBack:
            return ""
        }
    }

    // MARK: - Actions

    private func switchTo(_ storage: NotebookSyncStorage) {
        working = true
        Task { @MainActor in
            defer {
                working = false
                pending = nil
            }
            do {
                try await workspace.changeSyncStorage(storage)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func resolve(_ choice: NotebookWorkspace.StorageMismatchChoice) {
        working = true
        Task { @MainActor in
            defer {
                working = false
                pendingChoice = nil
            }
            do {
                try await workspace.resolveStorageMismatch(choice)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Sets up S3-compatible storage. Settings are used only after they passed a
/// connection check exactly as entered.
struct NotebookS3SettingsView: View {
    let workspace: NotebookWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var endpoint = ""
    @State private var region = "us-east-1"
    @State private var bucket = ""
    @State private var folder = ""
    @State private var accessKeyID = ""
    @State private var secretAccessKey = ""
    @State private var check = ConnectionCheck.idle
    @State private var savedCredentials: S3Credentials?
    @State private var loaded = false
    @State private var confirming = false
    @State private var applying = false
    @State private var applyError: String?

    var body: some View {
        Form {
            Section {
                Label {
                    Text("S3 sync is a beta. Keep automatic backups on. Changes from your other devices arrive while meh.md is open, within about a minute, instead of right away.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .accessibilityIdentifier("sync-storage-beta-warning")
            }
            fields
            connectionSection
            if isActive, !s3Changed { status }
            Section {
                Button(applyTitle) { confirming = true }
                    .disabled(!canApply)
                    .accessibilityIdentifier("sync-storage-apply")
            } footer: {
                if let applyError {
                    Text(applyError).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("S3 Storage")
        .disabled(applying)
        .task { load() }
        .onChange(of: s3Settings) { if loaded { check = .idle } }
        .confirmationDialog(applyTitle, isPresented: $confirming, titleVisibility: .visible) {
            Button(applyTitle) { apply() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(isActive
                ? "This device syncs with the new S3 settings and uploads what that storage is missing."
                : "A backup is made first. Then your notes are uploaded to S3 storage, and this device syncs only there. Your \(workspace.syncStorage.title) copy stays, but no longer gets changes from this device.")
        }
    }

    private var fields: some View {
        Section {
            field("Server", text: $endpoint, prompt: "https://s3.eu-central-1.amazonaws.com",
                  id: "sync-storage-endpoint")
            field("Region", text: $region, prompt: "us-east-1", id: "sync-storage-region")
            field("Bucket", text: $bucket, prompt: "my-notes", id: "sync-storage-bucket")
            field("Folder", text: $folder, prompt: "Optional", id: "sync-storage-folder")
            field("Access Key", text: $accessKeyID, prompt: "Required",
                  id: "sync-storage-access-key")
            LabeledContent("Secret Key") {
                SecureField("Secret Key", text: $secretAccessKey, prompt: Text("Required"))
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("sync-storage-secret-key")
            }
        } footer: {
            Text("Works with Amazon S3 and S3-compatible storage such as MinIO. Use a key that may only read and write this bucket. It is saved in this device’s keychain.")
        }
    }

    private var connectionSection: some View {
        Section {
            Button {
                testConnection()
            } label: {
                HStack {
                    Text("Test Connection")
                    Spacer()
                    if case .checking = check { ProgressView() }
                }
            }
            .disabled(!fieldsComplete || check == .checking)
            .accessibilityIdentifier("sync-storage-test")
            switch check {
            case .idle, .checking:
                EmptyView()
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("sync-storage-test-result")
            case .succeeded(let report, _, _):
                ForEach(findings(for: report), id: \.text) { finding in
                    Label {
                        Text(finding.text)
                    } icon: {
                        Image(systemName: finding.symbol).foregroundStyle(finding.color)
                    }
                    .accessibilityIdentifier("sync-storage-test-result")
                }
            }
        }
    }

    private var status: some View {
        Section("Status") {
            if let failure = workspace.syncFailure {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failure.title)
                        Text(failure.message).font(.footnote).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            } else if let date = workspace.lastSuccessfulSync {
                Label {
                    Text("Synced \(date, format: .relative(presentation: .named))")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            } else {
                Label("Not synced yet", systemImage: "clock")
            }
        }
        .accessibilityIdentifier("sync-storage-status")
    }

    private func field(
        _ title: LocalizedStringKey, text: Binding<String>, prompt: LocalizedStringKey, id: String
    ) -> some View {
        LabeledContent(title) {
            TextField(title, text: text, prompt: Text(prompt))
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(id == "sync-storage-endpoint" ? .URL : .asciiCapable)
                #endif
                .accessibilityIdentifier(id)
        }
    }

    // MARK: - State

    private enum ConnectionCheck: Equatable {
        case idle, checking
        case failed(String)
        case succeeded(S3ConnectionReport, S3SyncConfiguration, S3Credentials)
    }

    private struct Finding {
        let text: String
        let symbol: String
        let color: Color
    }

    private var isActive: Bool { workspace.syncStorage == .s3 }

    private var configuration: S3SyncConfiguration {
        S3SyncConfiguration(
            endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            region: region.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            bucket: bucket.trimmingCharacters(in: .whitespacesAndNewlines),
            prefix: folder.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private var credentials: S3Credentials {
        S3Credentials(
            accessKeyID: accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines),
            secretAccessKey: secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private var s3Settings: [String] {
        [endpoint, region, bucket, folder, accessKeyID, secretAccessKey]
    }

    private var fieldsComplete: Bool {
        !endpoint.isEmpty && !region.isEmpty && !bucket.isEmpty
            && !accessKeyID.isEmpty && !secretAccessKey.isEmpty
    }

    private var s3Changed: Bool {
        configuration != workspace.s3Configuration || credentials != savedCredentials
    }

    private var canApply: Bool {
        guard !applying, !isActive || s3Changed else { return false }
        guard case .succeeded(_, let checked, let checkedCredentials) = check else { return false }
        return checked == configuration && checkedCredentials == credentials
    }

    private var applyTitle: String { isActive ? "Save S3 Settings" : "Sync With S3 Storage" }

    private func findings(for report: S3ConnectionReport) -> [Finding] {
        var result = [Finding(text: "Connected", symbol: "checkmark.circle.fill", color: .green)]
        let notes = report.existingNoteCount == 1 ? "1 note" : "\(report.existingNoteCount) notes"
        switch workspace.storedNotebook(report.existingNotebookID) {
        case .none:
            result.append(Finding(
                text: "The folder is empty. Your notes will be uploaded.",
                symbol: "arrow.up.circle.fill", color: .accentColor
            ))
        case .same:
            result.append(Finding(
                text: "Your notebook is already stored here.",
                symbol: "checkmark.circle.fill", color: .green
            ))
        case .joins:
            result.append(Finding(
                text: "A notebook with \(notes) is stored here. This device joins it and keeps its own notes.",
                symbol: "checkmark.circle.fill", color: .green
            ))
        case .different:
            result.append(Finding(
                text: "This folder holds a different notebook with \(notes). After switching, you can combine it with yours or use it instead.",
                symbol: "rectangle.stack.badge.plus", color: .accentColor
            ))
        }
        if !report.supportsConditionalWrites {
            result.append(Finding(
                text: "This storage can’t stop two devices from setting up at the same time. Set up sync on one device first, then add the others.",
                symbol: "exclamationmark.triangle.fill", color: .orange
            ))
        }
        if configuration.usesUnencryptedConnection {
            result.append(Finding(
                text: "This connection isn’t encrypted. Use it only on a network you trust.",
                symbol: "exclamationmark.triangle.fill", color: .orange
            ))
        }
        return result
    }

    // MARK: - Actions

    /// The keychain is read once, when the screen opens.
    private func load() {
        guard !loaded else { return }
        let saved = workspace.s3Configuration
        let credentials = workspace.savedS3Credentials()
        endpoint = saved?.endpoint ?? ""
        region = saved?.region ?? "us-east-1"
        bucket = saved?.bucket ?? ""
        folder = saved?.prefix ?? ""
        accessKeyID = credentials?.accessKeyID ?? ""
        secretAccessKey = credentials?.secretAccessKey ?? ""
        savedCredentials = credentials
        loaded = true
    }

    private func testConnection() {
        let configuration = configuration
        let credentials = credentials
        check = .checking
        Task { @MainActor in
            do {
                let report = try await workspace.checkS3Connection(
                    configuration, credentials: credentials
                )
                // The fields may have changed while the check ran.
                guard configuration == self.configuration,
                      credentials == self.credentials else { return }
                check = .succeeded(report, configuration, credentials)
            } catch {
                guard configuration == self.configuration,
                      credentials == self.credentials else { return }
                check = .failed(Self.message(for: error))
            }
        }
    }

    private func apply() {
        applying = true
        applyError = nil
        let configuration = configuration
        let credentials = credentials
        Task { @MainActor in
            defer { applying = false }
            do {
                try await workspace.changeSyncStorage(
                    .s3, s3: configuration, credentials: credentials
                )
                savedCredentials = credentials
                check = .idle
                // The Sync screen shows the result and any choice to make.
                dismiss()
            } catch {
                applyError = error.localizedDescription
            }
        }
    }

    private static func message(for error: any Error) -> String {
        if error is URLError || (error as NSError).domain == NSURLErrorDomain {
            return "The server can’t be reached. Check the address and your connection."
        }
        if case .requestFailed = error as? S3SyncTransportError {
            let presentation = SyncFailurePresentation(
                error: error, retryWillOccurAutomatically: false
            )
            return String(localized: presentation.message)
        }
        return error.localizedDescription
    }
}
