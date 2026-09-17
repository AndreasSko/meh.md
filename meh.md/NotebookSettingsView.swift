import NoteCore
import SwiftUI
import UniformTypeIdentifiers

struct NotebookSettingsView: View {
    let replica: NotebookReplica
    let onImport: (NotebookImportPlan?) async throws -> Void
    let beforeExport: () async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var saving = false
    @State private var preparing = false
    @State private var document: MarkdownExportDocument?
    @State private var exported = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Markdown") {
                    Button("Import Markdown…") { importing = true }
                        .accessibilityIdentifier("notebook-import")
                    Button("Export All Notes…") { exportAll() }
                        .accessibilityIdentifier("notebook-export")
                    if preparing { ProgressView("Preparing Markdown…") }
                }
                .disabled(preparing || saving)
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
        .frame(width: 480, height: 320)
        #endif
        .interactiveDismissDisabled(preparing || saving)
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
                let notes = try await replica.persistedNoteSnapshots()
                let activeIDs = Set(placements.filter { !$0.isInTrash }.map { $0.item.id })
                document = MarkdownExportDocument(wrapper: try NotebookMarkdownExport.makeWrapper(
                    placements: placements, notes: notes, selectedIDs: activeIDs
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
