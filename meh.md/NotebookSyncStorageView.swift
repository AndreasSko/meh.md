import NoteCore
import SwiftUI

/// A storage's name, with a beta badge for S3.
struct NotebookSyncStorageTitle: View {
    let storage: NotebookSyncStorage

    var body: some View {
        HStack(spacing: 6) {
            Text(storage.title).foregroundStyle(.primary)
            if storage == .s3 {
                Text("BETA")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                    .accessibilityLabel("Beta")
            }
        }
    }
}

/// The storage already holds another notebook. Nothing changes until the
/// user picks what happens to this device's notes.
struct NotebookStorageMismatchView: View {
    typealias Choice = NotebookWorkspace.StorageMismatchChoice

    let workspace: NotebookWorkspace
    let mismatch: NotebookStorageMismatch
    @Environment(\.dismiss) private var dismiss
    @State private var choice = Choice.combine
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(storageTitle) Has Another Notebook")
                .font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
            option(
                .combine, title: "Combine Notebooks",
                detail: "Keep both. This device’s notes go into a folder named “\(workspace.combineFolderName)”. Notes that are in both are merged."
            )
            .accessibilityIdentifier("sync-mismatch-combine")
            option(
                .useStored, title: "Use the Notes in \(storageTitle)",
                detail: "Show only the stored notebook. This device’s notes are kept in a backup."
            )
            .accessibilityIdentifier("sync-mismatch-use-stored")
            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.red)
            }
            Button {
                resolve(choice)
            } label: {
                Group {
                    if working { ProgressView() } else { Text("Continue") }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 4)
            .accessibilityIdentifier("sync-mismatch-continue")
            if let previous = workspace.previousSyncStorage {
                Button(previous == .off ? "Turn Sync Off Again" : "Go Back to \(previous.title)") {
                    resolve(.switchBack)
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("sync-mismatch-switch-back")
            }
            Text("Nothing changes until you continue. A backup is made first.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
        .fittedSheet()
        .disabled(working)
        .interactiveDismissDisabled(working)
    }

    private var storageTitle: String { workspace.syncStorage.title }

    private var message: String {
        let ask = "Choose what happens to the notes on this device."
        switch mismatch.noteCount {
        case nil: return ask
        case 1: return "It holds 1 note. " + ask
        case let count?: return "It holds \(count) notes. " + ask
        }
    }

    private func option(_ value: Choice, title: String, detail: String) -> some View {
        Button {
            choice = value
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: choice == value ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(choice == value ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .font(.title3)
            }
            .padding(12)
            .contentShape(Rectangle())
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(choice == value ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                                  lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(choice == value ? .isSelected : [])
    }

    private func resolve(_ choice: Choice) {
        working = true
        errorMessage = nil
        Task { @MainActor in
            defer { working = false }
            do {
                try await workspace.resolveStorageMismatch(choice)
                dismiss()
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
    @ScaledMetric private var labelWidth = 72
    @State private var endpoint = ""
    @State private var region = "us-east-1"
    @State private var bucket = ""
    @State private var folder = ""
    @State private var accessKeyID = ""
    @State private var secretAccessKey = ""
    @State private var check = ConnectionCheck.idle
    @State private var savedCredentials: S3Credentials?
    @State private var loaded = false
    @State private var reviewing = false
    @State private var applying = false
    @State private var applyError: String?
    /// Loading saved settings fills the address; that is not a new address.
    @State private var keepsLoadedRegion = false

    var body: some View {
        Form {
            Section("Server") {
                field("Address", text: $endpoint, prompt: "https://s3.eu-central-1.amazonaws.com",
                      id: "sync-storage-endpoint")
                field("Region", text: $region, prompt: "us-east-1", id: "sync-storage-region")
            }
            Section("Bucket") {
                field("Bucket", text: $bucket, prompt: "my-notes", id: "sync-storage-bucket")
                field("Folder", text: $folder, prompt: "Optional", id: "sync-storage-folder")
            }
            Section {
                field("Key ID", text: $accessKeyID, prompt: "Required",
                      id: "sync-storage-access-key")
                row("Secret") {
                    SecureField("Secret", text: $secretAccessKey, prompt: Text("Required"))
                        #if os(iOS)
                        // Not an account password: keeps iOS from offering
                        // to save the key in Passwords when the form closes.
                        .textContentType(.oneTimeCode)
                        #endif
                        .accessibilityIdentifier("sync-storage-secret-key")
                }
            } header: {
                Text("Access Key")
            } footer: {
                Text("Saved in this device’s keychain. Use a key that can only access this bucket.")
            }
            Section {
                Button {
                    connect()
                } label: {
                    HStack {
                        Spacer()
                        if check == .checking {
                            ProgressView()
                        } else {
                            Text(isActive ? "Save Changes" : "Connect").fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(!canConnect)
                .accessibilityIdentifier("sync-storage-test")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if case .failed(let message) = check {
                        Label(message, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("sync-storage-test-result")
                    }
                    Text("S3 sync is in beta, so keep automatic backups on. [Setup guide](https://github.com/AndreasSko/meh.md/blob/main/docs/s3-sync.md)")
                        .accessibilityIdentifier("sync-storage-beta-warning")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("S3 Storage")
        .disabled(applying)
        .task { load() }
        .onChange(of: s3Settings) { if loaded { check = .idle } }
        .onChange(of: endpoint) { old, new in fillRegion(from: old, to: new) }
        .sheet(isPresented: $reviewing) { review }
    }

    // MARK: - Views

    private func field(
        _ title: LocalizedStringKey, text: Binding<String>, prompt: LocalizedStringKey, id: String
    ) -> some View {
        row(title) {
            TextField(title, text: text, prompt: Text(prompt))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(id == "sync-storage-endpoint" ? .URL : .asciiCapable)
                .textContentType(id == "sync-storage-access-key" ? .oneTimeCode : nil)
                #endif
                .accessibilityIdentifier(id)
        }
    }

    /// The label in a fixed column and the value left-aligned after it, so
    /// long addresses don't wrap under their label.
    private func row<Content: View>(
        _ title: LocalizedStringKey, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Text(title).frame(width: labelWidth, alignment: .leading)
            content().labelsHidden()
        }
    }

    /// What the check found and the switch itself, confirmed in one place.
    @ViewBuilder
    private var review: some View {
        if case .succeeded(let report, let checked, _) = check {
            VStack(alignment: .leading, spacing: 12) {
                Text(isActive ? "Save S3 Settings?" : "Sync With S3 Storage?")
                    .font(.title3.weight(.semibold))
                ForEach(findings(for: report, location: location(of: checked)), id: \.text) { finding in
                    Label {
                        Text(finding.text)
                    } icon: {
                        Image(systemName: finding.symbol).foregroundStyle(finding.color)
                    }
                    .accessibilityIdentifier("sync-storage-test-result")
                }
                if let applyError {
                    Text(applyError).font(.footnote).foregroundStyle(.red)
                }
                Button {
                    apply()
                } label: {
                    Group {
                        if applying { ProgressView() } else { Text(isActive ? "Save" : "Sync With S3") }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 4)
                .accessibilityIdentifier("sync-storage-apply")
                Button("Cancel", role: .cancel) { reviewing = false }
                    .frame(maxWidth: .infinity)
                Text(reviewFootnote(report))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            .fittedSheet()
            .disabled(applying)
            .interactiveDismissDisabled(applying)
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

    private var canConnect: Bool {
        fieldsComplete && check != .checking && !applying && (!isActive || s3Changed)
    }

    private func reviewFootnote(_ report: S3ConnectionReport) -> String {
        if workspace.storedNotebook(report.existingNotebookID) == .different {
            return "Nothing changes until you choose."
        }
        if isActive { return "This device then uploads what the new location is missing." }
        let current = workspace.syncStorage
        return current == .off
            ? "A backup is made first."
            : "A backup is made first. Your \(current.name) copy stays as it is."
    }

    private func location(of configuration: S3SyncConfiguration) -> String {
        let folder = configuration.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return folder.isEmpty ? configuration.bucket : configuration.bucket + "/" + folder
    }

    private func findings(for report: S3ConnectionReport, location: String) -> [Finding] {
        var result = [Finding(
            text: "Connected to \(location)", symbol: "checkmark.circle.fill", color: .green
        )]
        let notes = report.existingNoteCount == 1 ? "1 note" : "\(report.existingNoteCount) notes"
        switch workspace.storedNotebook(report.existingNotebookID) {
        case .none:
            result.append(Finding(
                text: "The folder is empty. This device’s notes will be uploaded.",
                symbol: "arrow.up.circle.fill", color: .accentColor
            ))
        case .same:
            result.append(Finding(
                text: "Your notebook is already stored here.",
                symbol: "checkmark.circle.fill", color: .green
            ))
        case .joins:
            result.append(Finding(
                text: "It holds a notebook with \(notes). This device joins it and keeps its own notes.",
                symbol: "arrow.triangle.merge", color: .accentColor
            ))
        case .different:
            result.append(Finding(
                text: "It holds another notebook with \(notes). Next, you choose whether to combine them.",
                symbol: "rectangle.stack.badge.plus", color: .accentColor
            ))
        }
        if !report.supportsConditionalWrites {
            result.append(Finding(
                text: "This storage can’t stop two devices from setting up at once. Set up one device first.",
                symbol: "exclamationmark.triangle.fill", color: .orange
            ))
        }
        if configuration.usesUnencryptedConnection {
            result.append(Finding(
                text: "Not encrypted (http). Use it only on a network you trust.",
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
        keepsLoadedRegion = !endpoint.isEmpty
        loaded = true
    }

    /// AWS addresses name their region. It replaces the region only while
    /// that still holds the default or what the previous address named.
    private func fillRegion(from old: String, to new: String) {
        if keepsLoadedRegion {
            keepsLoadedRegion = false
            return
        }
        guard loaded, let named = S3SyncConfiguration.awsRegion(inEndpoint: new) else { return }
        let current = region.trimmingCharacters(in: .whitespacesAndNewlines)
        if current.isEmpty || current == "us-east-1"
            || current == S3SyncConfiguration.awsRegion(inEndpoint: old) {
            region = named
        }
    }

    private func connect() {
        let configuration = configuration
        let credentials = credentials
        check = .checking
        applyError = nil
        Task { @MainActor in
            do {
                let report = try await workspace.checkS3Connection(
                    configuration, credentials: credentials
                )
                // The fields may have changed while the check ran.
                guard configuration == self.configuration,
                      credentials == self.credentials else { return }
                check = .succeeded(report, configuration, credentials)
                reviewing = true
            } catch {
                guard configuration == self.configuration,
                      credentials == self.credentials else { return }
                check = .failed(Self.message(for: error))
            }
        }
    }

    private func apply() {
        guard case .succeeded(_, let configuration, let credentials) = check else { return }
        applying = true
        applyError = nil
        Task { @MainActor in
            defer { applying = false }
            do {
                try await workspace.changeSyncStorage(
                    .s3, s3: configuration, credentials: credentials
                )
                savedCredentials = credentials
                reviewing = false
                // Sync & Backups shows the result and any choice to make.
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
                error: error, retryWillOccurAutomatically: false, storageName: "S3"
            )
            // Errors without a specific explanation keep the code the
            // service answered with, which helps more than a generic text.
            let title = String(localized: presentation.title)
            if title != "Sync failed", title != "Can't reach S3" {
                return String(localized: presentation.message)
            }
        }
        return error.localizedDescription
    }
}

/// A sheet as tall as its content, with the margins of native sheets. Very
/// large text still scrolls, up to the full height.
private struct FittedSheet<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var height: CGFloat = 320

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, 24)
                .padding(.top, 32)
                .padding(.bottom, 16)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        #if os(iOS)
        .presentationDetents([.height(height)])
        #else
        .frame(width: 420, height: height)
        #endif
    }
}

private extension View {
    func fittedSheet() -> some View {
        FittedSheet { self }
    }
}
