import NoteCore
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension View {
    func notebookMarkdownImporter(
        isPresented: Binding<Bool>,
        choosingFolder: Bool = false,
        replica: NotebookReplica,
        onImport: @escaping (NotebookImportPlan?) async throws -> Void
    ) -> some View {
        modifier(NotebookMarkdownImporter(
            isPresented: isPresented, choosingFolder: choosingFolder,
            replica: replica, onImport: onImport
        ))
    }
}

private struct NotebookMarkdownImporter: ViewModifier {
    @Binding var isPresented: Bool
    let choosingFolder: Bool
    let replica: NotebookReplica
    let onImport: (NotebookImportPlan?) async throws -> Void
    @State private var working = false
    @State private var recovering = false
    #if os(iOS)
    @State private var picking = false
    #endif
    @State private var errorMessage: String?
    @State private var completionMessage: String?
    @State private var pendingAttachmentPlan: NotebookImportPlan?

    func body(content: Content) -> some View {
        content
            .disabled(working)
            .interactiveDismissDisabled(working)
            .overlay {
                if working {
                    ProgressView("Importing Files…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityIdentifier("notebook-import-progress")
                }
            }
            #if os(iOS)
            .sheet(isPresented: $picking) {
                NotebookMarkdownDocumentPicker(choosingFolders: choosingFolder) { urls in
                    picking = false
                    importSelection(.success(urls))
                } onCancel: {
                    picking = false
                }
            }
            #endif
            .onChange(of: isPresented, initial: true) { _, presented in
                guard presented else { return }
                isPresented = false
                if replica.hasPendingImport {
                    recovering = true
                } else {
                    #if os(macOS)
                    chooseOnMac()
                    #else
                    picking = true
                    #endif
                }
            }
            .alert("Interrupted Import", isPresented: $recovering) {
                Button("Resume Import") { resume() }
                    .accessibilityIdentifier("notebook-resume-import")
                Button("Set Aside and Choose Again…") { setAsideAndChoose() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Resume the saved copy without selecting the source again. You can also set it aside for recovery and choose new files. Items already imported keep their edits and placement. Importing the same files again may create duplicates.")
            }
            .confirmationDialog("Import Files?", isPresented: Binding(
                get: { pendingAttachmentPlan != nil },
                set: { if !$0 { discardPendingPlan() } }
            ), titleVisibility: .visible) {
                Button("Import") {
                    guard let plan = pendingAttachmentPlan else { return }
                    pendingAttachmentPlan = nil
                    apply(plan)
                }
                .accessibilityIdentifier("notebook-confirm-import")
                Button("Cancel", role: .cancel) { discardPendingPlan() }
            } message: {
                if let pendingAttachmentPlan {
                    let notes = pendingAttachmentPlan.entries.filter { $0.kind == .note }.count
                    let files = pendingAttachmentPlan.entries.filter { $0.kind == .attachment }.count
                    let folders = pendingAttachmentPlan.entries.filter { $0.kind == .folder }.count
                    Text("Add \(notes) notes, \(files) files, and \(folders) folders to your notebook. Original files stay unchanged. Adding files upgrades this notebook. Older apps will pause syncing until updated.")
                }
            }
            .alert("Couldn’t Import Files", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .alert("Import Complete", isPresented: Binding(
                get: { completionMessage != nil },
                set: { if !$0 { completionMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(completionMessage ?? "")
            }
            .onDisappear { discardPendingPlan() }
    }

    #if os(macOS)
    private func chooseOnMac() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import Files")
        panel.prompt = String(localized: "Import")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.resolvesAliases = false
        panel.allowedContentTypes = [.item, .folder]
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK { importSelection(.success(panel.urls)) }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
    #endif

    private func importSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            let cocoaError = error as NSError
            if cocoaError.domain != NSCocoaErrorDomain
                || cocoaError.code != CocoaError.userCancelled.rawValue {
                errorMessage = error.localizedDescription
            }
        case .success(let urls):
            guard !urls.isEmpty, !working else { return }
            working = true
            Task { @MainActor in
                let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
                defer {
                    scoped.forEach { $0.stopAccessingSecurityScopedResource() }
                    working = false
                }
                do {
                    let scanner = NotebookImportScanner(
                        attachmentStore: replica.attachmentStore
                    )
                    let plan = try await scanner.scan(urls: urls)
                    guard !plan.entries.isEmpty else {
                        try? await scanner.discard(plan: plan)
                        errorMessage = String(localized: "No visible files or ordinary folders were found. Hidden items, links, and packages are skipped.")
                        return
                    }
                    if plan.entries.contains(where: { $0.kind == .attachment }) {
                        pendingAttachmentPlan = plan
                    } else {
                        await apply(plan)
                    }
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func apply(_ plan: NotebookImportPlan) {
        working = true
        Task { @MainActor in
            await apply(plan)
            working = false
        }
    }

    private func apply(_ plan: NotebookImportPlan) async {
        do {
            try await onImport(plan)
            if plan.skippedPaths.isEmpty {
                completionMessage = String(localized: "The selected files and folders were added to your notebook.")
            } else {
                completionMessage = String(localized: "The selected files and folders were added to your notebook. \(plan.skippedPaths.count) hidden items, links, or packages were skipped.")
            }
        } catch {
            if !replica.hasPendingImport {
                let scanner = NotebookImportScanner(
                    attachmentStore: replica.attachmentStore
                )
                try? await scanner.discard(plan: plan)
            }
            errorMessage = error.localizedDescription
        }
    }

    private func discardPendingPlan() {
        guard let plan = pendingAttachmentPlan else { return }
        pendingAttachmentPlan = nil
        let scanner = NotebookImportScanner(
            attachmentStore: replica.attachmentStore
        )
        Task { try? await scanner.discard(plan: plan) }
    }

    private func resume() {
        guard !working else { return }
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                try await onImport(nil)
                completionMessage = String(localized: "The interrupted import is complete.")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func setAsideAndChoose() {
        guard !working else { return }
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                _ = try await replica.setAsidePendingImport()
                isPresented = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#if os(iOS)
/// Each presentation creates the native picker for the chosen source kind.
private struct NotebookMarkdownDocumentPicker: UIViewControllerRepresentable {
    let choosingFolders: Bool
    let onSelection: ([URL]) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: choosingFolders ? [.folder] : [.item],
            asCopy: false
        )
        picker.allowsMultipleSelection = !choosingFolders
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(
        _ picker: UIDocumentPickerViewController, context: Context
    ) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelection: onSelection, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onSelection: ([URL]) -> Void
        let onCancel: () -> Void

        init(onSelection: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
            self.onSelection = onSelection
            self.onCancel = onCancel
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
        ) {
            // The native picker dismisses itself. SwiftUI's sheet onDismiss
            // can miss that transition, so deliver URLs after UIKit closes it.
            controller.dismiss(animated: true) {
                self.onSelection(urls)
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
#endif
