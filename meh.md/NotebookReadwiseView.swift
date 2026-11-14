import NoteCore
import SwiftUI

/// Settings › Readwise: setup, the syncing device, how notes look, and
/// what to do with deleted notes. See docs/readwise-sync.md.
struct NotebookReadwiseView: View {
    let readwise: NotebookReadwise
    var onOpenNote: ((UUID) -> Void)? = nil
    @State private var token = ""
    @State private var folderName = "Readwise"
    @State private var summary: String?
    @State private var checking = false
    @State private var connecting = false
    @State private var setupError: String?
    @State private var confirmingDisconnect = false

    var body: some View {
        Form {
            if let status = readwise.status {
                if readwise.needsToken { tokenSection }
                syncSection(status)
                notesSection
                templateSection
                deletedSection
                disconnectSection
            } else {
                setupSections
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Readwise")
        .onAppear { readwise.reload() }
    }

    // MARK: Setup

    @ViewBuilder private var setupSections: some View {
        Section {
            Link(destination: Self.tokenPage) {
                Label("Get Your Access Token", systemImage: "arrow.up.forward")
            }
        }
        Section {
            LabeledContent("Access Token") {
                SecureField("Paste Token", text: $token)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("readwise-token")
                    .onChange(of: token) { summary = nil }
            }
            LabeledContent("Folder") {
                TextField("Readwise", text: $folderName)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("readwise-folder")
            }
        } footer: {
            Text("Your highlights become notes in this folder and stay up to date.")
        }
        Section {
            if let summary {
                prominentButton("Import \(summary)", busy: connecting) {
                    // Set before the first await, so a second tap cannot
                    // create a second connection.
                    guard !connecting else { return }
                    connecting = true
                    Task {
                        defer { connecting = false }
                        do {
                            try await readwise.connect(token: token, folderName: folderName)
                            token = ""
                        } catch { setupError = error.localizedDescription }
                    }
                }
                .disabled(connecting)
                .accessibilityIdentifier("readwise-connect")
            } else {
                prominentButton("Check Token", busy: checking) { Task { await check() } }
                    .disabled(token.isEmpty || folderName.isEmpty || checking)
                    .accessibilityIdentifier("readwise-check")
            }
        } footer: {
            if let setupError { Text(setupError).foregroundStyle(.red) }
        }
    }

    private static let tokenPage = URL(string: "https://readwise.io/access_token")!

    private func prominentButton(
        _ title: String, busy: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Text(title).fontWeight(.semibold).opacity(busy ? 0 : 1)
                if busy { ProgressView() }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    private var tokenSection: some View {
        Section {
            LabeledContent("Access Token") {
                SecureField("Paste Token", text: $token)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
            }
            Button("Save Token") {
                Task {
                    do {
                        try await readwise.replaceToken(token)
                        token = ""
                    } catch { setupError = error.localizedDescription }
                }
            }
            .disabled(token.isEmpty)
            Link(destination: Self.tokenPage) {
                Label("Get Your Access Token", systemImage: "arrow.up.forward")
            }
            if let setupError {
                Text(setupError).foregroundStyle(.red)
            }
        } header: {
            Text("Token Missing")
        } footer: {
            Text("This device has no Readwise token yet.")
        }
    }

    private func check() async {
        checking = true
        defer { checking = false }
        let checked = token
        do {
            let result = try await readwise.checkToken(checked)
            // The token may have changed meanwhile; only the checked one
            // may be imported.
            guard token == checked else { return }
            summary = result
            setupError = nil
        } catch {
            guard token == checked else { return }
            setupError = error.localizedDescription
        }
    }

    // MARK: Syncing

    private func syncSection(_ status: NotebookIntegrationStatus) -> some View {
        Section {
            LabeledContent("Syncs On", value: syncingDevice(status))
            TimelineView(.everyMinute) { context in
                LabeledContent("Last Synced", value: lastSynced(status.lastSync, now: context.date))
                    .accessibilityIdentifier("readwise-status")
                if let lastSync = status.lastSync,
                   context.date.timeIntervalSince(lastSync) > 7 * 24 * 60 * 60 {
                    Label("Readwise hasn't synced for \(lastSync, format: .relative(presentation: .named)).",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }
            if let blocked = status.deviceNeedingUpdate, blocked.id == status.syncingDevice?.id {
                Label("\(blocked.kind) needs an app update to keep syncing Readwise.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.footnote)
            }
            LabeledContent("Folder", value: readwise.settings["folderName"] ?? "Readwise")
            if let progress = readwise.progress {
                VStack(alignment: .leading, spacing: 6) {
                    if let total = progress.total, total > 0 {
                        Text("Syncing… \(min(progress.done, total)) of \(total)")
                            .foregroundStyle(.secondary)
                        ProgressView(value: Double(min(progress.done, total)), total: Double(total))
                    } else {
                        Text("Syncing…").foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if readwise.isSyncingDevice {
                Button {
                    Task { await readwise.sync() }
                } label: {
                    HStack {
                        Text("Sync Now")
                        Spacer()
                        if readwise.isSyncing {
                            ProgressView()
                        } else {
                            Text(readwise.noteCount == 1 ? "1 note" : "\(readwise.noteCount) notes")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(readwise.isSyncing)
                .accessibilityIdentifier("readwise-sync-now")
            } else {
                Button("Sync on This \(readwise.device.kind)") {
                    Task { await readwise.syncOnThisDevice() }
                }
                .accessibilityIdentifier("readwise-claim")
            }
            if let error = readwise.lastError {
                Text(error).foregroundStyle(.red).font(.footnote)
            }
        } footer: {
            Text("One device syncs with Readwise. Your other devices get the notes through iCloud.")
        }
    }

    private func syncingDevice(_ status: NotebookIntegrationStatus) -> String {
        guard let device = status.syncingDevice else { return "No Device" }
        return device.id == readwise.device.id ? "This \(device.kind)" : device.kind
    }

    private func lastSynced(_ date: Date?, now: Date) -> String {
        guard let date else { return "Never" }
        if now.timeIntervalSince(date) < 60 { return "Just now" }
        return date.formatted(.relative(presentation: .named))
    }

    // MARK: Notes

    @ViewBuilder private var notesSection: some View {
        Section {
            Toggle("Highlight Links", isOn: Binding(
                get: { readwise.settings["blockIDs"] != "off" },
                set: { value in Task { await readwise.setBlockIDs(value) } }))
                .accessibilityIdentifier("readwise-block-ids")
        } header: {
            Text("Notes")
        } footer: {
            Text("Adds an ID like ^rw-123 under each highlight, so other notes can link to it.")
        }
        Section {
            Toggle("Readwise Supplementals", isOn: Binding(
                get: { readwise.settings["supplementals"] == "show" },
                set: { value in Task { await readwise.setSupplementals(value) } }))
        } footer: {
            Text("Highlights Readwise adds for you.")
        }
    }

    private var templateSection: some View {
        Section {
            if let id = readwise.settings["template"].flatMap(UUID.init) {
                Button("Edit Template") { onOpenNote?(id) }
                Button("Reset to Default") { Task { await readwise.resetTemplate() } }
                Button("Use Built-in Layout") { Task { await readwise.useBuiltInTemplate() } }
            } else {
                Button("Edit Template") {
                    Task {
                        if let id = await readwise.customizeTemplate() { onOpenNote?(id) }
                    }
                }
                .accessibilityIdentifier("readwise-customize-template")
            }
            if let error = readwise.templateError {
                Text(error).foregroundStyle(.red).font(.footnote)
            }
        } header: {
            Text("Layout")
        } footer: {
            Text("The template is a note. Changes update every Readwise note.")
        }
    }

    @ViewBuilder private var deletedSection: some View {
        if readwise.deletedCount > 0 {
            Section {
                Button("Bring Back \(readwise.deletedCount) Deleted Notes") {
                    Task { await readwise.bringBackDeletedNotes() }
                }
                .disabled(!readwise.isSyncingDevice || readwise.isSyncing)
            } footer: {
                Text("Notes you delete stay deleted until you bring them back.")
            }
        }
    }

    private var disconnectSection: some View {
        Section {
            Button("Disconnect", role: .destructive) { confirmingDisconnect = true }
                .confirmationDialog(
                    "Disconnect Readwise?", isPresented: $confirmingDisconnect,
                    titleVisibility: .visible
                ) {
                    Button("Disconnect", role: .destructive) {
                        Task { await readwise.disconnect() }
                    }
                } message: {
                    Text("Your notes stay. They stop updating.")
                }
        } footer: {
            Text("Your notes stay. They stop updating.")
        }
    }
}

/// Note Actions for a note that came from Readwise. A menu closes before a
/// dialog could show, so Reset asks through `readwiseResetDialog`.
struct NotebookReadwiseNoteActions: View {
    let readwise: NotebookReadwise
    let noteID: UUID

    var body: some View {
        if readwise.isEnabled, let (record, isDuplicate) = readwise.record(forNote: noteID) {
            Menu {
                if isDuplicate {
                    Text("A second copy of a Readwise note")
                } else {
                    if let url = record.url {
                        Link(destination: url) {
                            Label("Open in Readwise", systemImage: "arrow.up.forward.app")
                        }
                    }
                    Button {
                        Task { await readwise.sync() }
                    } label: {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(!readwise.isSyncingDevice || readwise.isSyncing)
                    Button(role: .destructive) {
                        readwise.resetRequest = noteID
                    } label: {
                        Label("Reset to Readwise Version…", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(!readwise.isSyncingDevice || readwise.isSyncing)
                }
            } label: {
                Label(isDuplicate ? "Duplicate from Readwise" : "From Readwise",
                      systemImage: "quote.opening")
            }
            .accessibilityIdentifier("notebook-readwise")
        }
    }
}

extension View {
    /// Asks before Reset to Readwise Version removes the person's text.
    /// Every window shares the request, so only the window showing that
    /// note asks.
    func readwiseResetDialog(_ readwise: NotebookReadwise?, noteID: UUID, noteName: String) -> some View {
        confirmationDialog(
            noteName.isEmpty ? "Reset This Note?" : "Reset “\(noteName)”?",
            isPresented: Binding(
                get: { readwise?.resetRequest == noteID },
                set: { if !$0, readwise?.resetRequest == noteID { readwise?.resetRequest = nil } }),
            titleVisibility: .visible
        ) {
            Button("Reset Note", role: .destructive) {
                guard let readwise, readwise.resetRequest == noteID else { return }
                readwise.resetRequest = nil
                Task { await readwise.reimport(noteID: noteID) }
            }
        } message: {
            Text("The note goes to Trash and comes back as Readwise has it. Text you added is removed.")
        }
    }
}

/// Shown once in notes from Readwise, until closed: where the person's own
/// text is safe from updates.
struct NotebookReadwiseHint: View {
    let readwise: NotebookReadwise
    let noteID: UUID
    @AppStorage("readwise.hintDismissed") private var dismissed = false

    var body: some View {
        if !dismissed, readwise.isEnabled, let (_, isDuplicate) = readwise.record(forNote: noteID),
           !isDuplicate {
            HStack(alignment: .top, spacing: 8) {
                Text("Write between highlights. Text inside a highlight, marked in the margin, is replaced when it changes in Readwise.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    dismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(10)
            .background(Color(MehStyle.highlighter).opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("readwise-hint")
        }
    }
}
