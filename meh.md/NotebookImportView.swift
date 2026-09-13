import NoteCore
import SwiftUI
import UniformTypeIdentifiers

struct NotebookImportView: View {
    let replica: NotebookReplica
    let onImport: (NotebookImportPlan?) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var plan: NotebookImportPlan?
    @State private var choosingFiles = false
    @State private var choosingFolder = false
    @State private var preparing = false
    @State private var importing = false
    @State private var settingAside = false
    @State private var confirmingSetAside = false
    @State private var importWasSetAside = false
    @State private var errorMessage: String?
    @State private var preparation: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Copy Markdown files into your notebook. Folder structure and text are preserved; your source files stay unchanged.")
                    if settingAside {
                        ProgressView("Setting import aside…")
                    } else if importing {
                        ProgressView("Importing into notebook…")
                    } else if replica.hasPendingImport {
                        Label("An interrupted import is ready to resume.", systemImage: "arrow.clockwise")
                        Text("Resume the saved copy without selecting the source again. Notes already imported keep their edits and placement.")
                        Button("Resume Import") { apply(nil) }
                            .accessibilityIdentifier("notebook-resume-import")
                        Button("Set Aside…") { confirmingSetAside = true }
                    } else if preparing {
                        ProgressView("Reading Markdown files…")
                    } else if let plan {
                        Text("\(noteCount(plan)) notes · \(folderCount(plan)) folders")
                            .font(.headline)
                            .accessibilityIdentifier("notebook-import-summary")
                        Text("These will be added at the top level of your notebook. Matching names stay separate; existing notes are never replaced.")
                        ForEach(plan.entries.filter { $0.parentID == nil }, id: \.id) { entry in
                            Label(entry.name, systemImage: entry.kind == .folder ? "folder" : "doc.text")
                        }
                        if !plan.skippedPaths.isEmpty {
                            DisclosureGroup("\(plan.skippedPaths.count) skipped items") {
                                Text("Only visible Markdown files and ordinary folders are imported. Hidden items, links, packages, and other file types are skipped.")
                                ForEach(Array(plan.skippedPaths.enumerated()), id: \.offset) { _, path in
                                    Text(path).font(.caption).textSelection(.enabled)
                                }
                            }
                        }
                        HStack {
                            Button("Choose Again") { self.plan = nil }
                            Spacer()
                            Button("Import") { apply(plan) }
                                .buttonStyle(.borderedProminent)
                                .disabled(plan.entries.isEmpty)
                                .accessibilityIdentifier("notebook-confirm-import")
                        }
                    } else {
                        if importWasSetAside {
                            Text("The interrupted import is kept for recovery. You can choose files again.")
                        }
                        HStack {
                            Button("Choose Files…") { choosingFiles = true }
                            Button("Choose Folder…") { choosingFolder = true }
                        }
                    }
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
                .padding(20)
                .disabled(importing || settingAside)
            }
            .navigationTitle("Import Markdown")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { preparation?.cancel(); dismiss() }
                        .disabled(importing || settingAside)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 360, idealHeight: 480)
        #endif
        .interactiveDismissDisabled(importing || settingAside)
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item],
                      allowsMultipleSelection: true, onCompletion: prepare)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder],
                      allowsMultipleSelection: false, onCompletion: prepare)
        .onDisappear { preparation?.cancel() }
        .confirmationDialog("Set Aside Interrupted Import?",
                            isPresented: $confirmingSetAside, titleVisibility: .visible) {
            Button("Set Aside Import") { setAside() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The saved import will be kept for recovery. Notes already imported stay unchanged. Starting a new import of the same files may create duplicates.")
        }
    }

    private func prepare(_ result: Result<[URL], Error>) {
        errorMessage = nil
        switch result {
        case .failure(let error): errorMessage = error.localizedDescription
        case .success(let urls):
            preparing = true
            preparation = Task { @MainActor in
                let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
                defer {
                    scoped.forEach { $0.stopAccessingSecurityScopedResource() }
                    preparing = false
                }
                do {
                    let result = try await NotebookImportScanner().scan(urls: urls)
                    try Task.checkCancellation()
                    plan = result
                } catch is CancellationError {
                    return
                } catch { errorMessage = error.localizedDescription }
            }
        }
    }

    private func apply(_ plan: NotebookImportPlan?) {
        guard !importing else { return }
        importing = true
        errorMessage = nil
        Task { @MainActor in
            defer { importing = false }
            do {
                try await onImport(plan)
                dismiss()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func setAside() {
        guard !importing, !settingAside else { return }
        settingAside = true
        Task { @MainActor in
            defer { settingAside = false }
            do {
                _ = try await replica.setAsidePendingImport()
                plan = nil
                errorMessage = nil
                importWasSetAside = true
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func noteCount(_ plan: NotebookImportPlan) -> Int {
        plan.entries.filter { $0.kind == .note }.count
    }
    private func folderCount(_ plan: NotebookImportPlan) -> Int {
        plan.entries.filter { $0.kind == .folder }.count
    }
}
