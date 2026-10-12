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
        suppliedURLs: Binding<[URL]> = .constant([]),
        stagingDirectory: URL? = nil,
        isActive: Binding<Bool> = .constant(false),
        replica: NotebookReplica,
        onImport: @escaping (NotebookImportPlan?) async throws -> Void
    ) -> some View {
        modifier(NotebookMarkdownImporter(
            isPresented: isPresented, choosingFolder: choosingFolder,
            suppliedURLs: suppliedURLs, stagingDirectory: stagingDirectory, isActive: isActive,
            replica: replica, onImport: onImport
        ))
    }
}

private struct NotebookMarkdownImporter: ViewModifier {
    @Binding var isPresented: Bool
    let choosingFolder: Bool
    @Binding var suppliedURLs: [URL]
    let stagingDirectory: URL?
    @Binding var isActive: Bool
    let replica: NotebookReplica
    let onImport: (NotebookImportPlan?) async throws -> Void
    @State private var working = false
    @State private var recovering = false
    #if os(iOS)
    @State private var picking = false
    #endif
    @State private var errorMessage: String?
    @State private var importTask: Task<Void, Never>?
    @State private var presentationGeneration = UUID()
    @State private var isVisible = true

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
                    isActive = false
                }
            }
            #endif
            .onChange(of: isPresented, initial: true) { _, presented in
                guard presented else { return }
                isPresented = false
                isActive = true
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
            .onChange(of: suppliedURLs, initial: true) { _, urls in
                guard !urls.isEmpty else { return }
                suppliedURLs = []
                guard !working, !replica.hasPendingImport else {
                    cleanupStagedSources(urls)
                    errorMessage = String(localized: "Finish the current import before adding more files.")
                    return
                }
                importSelection(.success(urls))
            }
            .alert("Interrupted Import", isPresented: $recovering) {
                Button("Resume Import") { resume() }
                    .accessibilityIdentifier("notebook-resume-import")
                Button("Set Aside and Choose Again…") { setAsideAndChoose() }
                Button("Cancel", role: .cancel) { isActive = false }
            } message: {
                Text("Resume the saved copy without selecting the source again. You can also set it aside for recovery and choose new files. Items already imported keep their edits and placement. Importing the same files again may create duplicates.")
            }
            .alert("Couldn’t Import Files", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onChange(of: working || recovering) { _, active in
                isActive = active
            }
            .onAppear { isVisible = true }
            .onDisappear {
                isVisible = false
                presentationGeneration = UUID()
                importTask?.cancel()
                importTask = nil
                working = false
                cleanupStagedSources(suppliedURLs)
                suppliedURLs = []
                isActive = false
            }
    }

    #if os(macOS)
    private func chooseOnMac() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import Files")
        panel.prompt = String(localized: "Import")
        panel.canChooseFiles = !choosingFolder
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.resolvesAliases = false
        panel.allowedContentTypes = [.item, .folder]
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK { importSelection(.success(panel.urls)) }
            else { isActive = false }
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
            guard !urls.isEmpty, !working, isVisible else {
                cleanupStagedSources(urls)
                return
            }
            working = true
            let generation = presentationGeneration
            importTask = Task { @MainActor in
                let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
                defer {
                    scoped.forEach { $0.stopAccessingSecurityScopedResource() }
                    cleanupStagedSources(urls)
                    if generation == presentationGeneration {
                        working = false
                        importTask = nil
                    }
                }
                do {
                    let scanner = NotebookImportScanner(
                        attachmentStore: replica.attachmentStore
                    )
                    let plan = try await scanner.scan(urls: urls)
                    guard !Task.isCancelled, isVisible,
                          generation == presentationGeneration else {
                        try? await scanner.discard(plan: plan)
                        return
                    }
                    guard !plan.entries.isEmpty else {
                        try? await scanner.discard(plan: plan)
                        errorMessage = String(localized: "No visible files or ordinary folders were found. Hidden items, links, and packages are skipped.")
                        return
                    }
                    await apply(plan)
                } catch {
                    if !Task.isCancelled, isVisible,
                       generation == presentationGeneration {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func cleanupStagedSources(_ urls: [URL]) {
        guard let stagingDirectory else { return }
        let root = stagingDirectory.standardizedFileURL.path + "/"
        for url in urls where url.standardizedFileURL.path.hasPrefix(root) {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    private func apply(_ plan: NotebookImportPlan) async {
        do {
            guard isVisible else { throw CancellationError() }
            try Task.checkCancellation()
            try await onImport(plan)
        } catch {
            if !replica.hasPendingImport {
                let scanner = NotebookImportScanner(
                    attachmentStore: replica.attachmentStore
                )
                try? await scanner.discard(plan: plan)
            }
            if !Task.isCancelled, isVisible { errorMessage = error.localizedDescription }
        }
    }

    private func resume() {
        guard !working else { return }
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                try await onImport(nil)
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
