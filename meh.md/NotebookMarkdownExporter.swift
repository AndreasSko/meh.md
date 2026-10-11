import Foundation
import NoteCore
import SwiftUI
import UniformTypeIdentifiers

extension View {
    func notebookMarkdownExporter(
        isPresented: Binding<Bool>,
        replica: NotebookReplica,
        beforeExport: @escaping () async throws -> Void
    ) -> some View {
        modifier(NotebookMarkdownExporter(
            isPresented: isPresented,
            replica: replica,
            beforeExport: beforeExport
        ))
    }
}

private struct NotebookMarkdownExporter: ViewModifier {
    @Binding var isPresented: Bool
    let replica: NotebookReplica
    let beforeExport: () async throws -> Void

    @State private var isPreparing = false
    @State private var isSaving = false
    @State private var preparationTask: Task<Void, Never>?
    @State private var document: NotebookMarkdownExportDocument?
    @State private var alert: ExportAlert?

    func body(content: Content) -> some View {
        content
            .disabled(isPreparing || isSaving)
            .overlay {
                if isPreparing {
                    ProgressView("Preparing Markdown…")
                        .padding(24)
                        .background(.regularMaterial,
                                    in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityIdentifier("notebook-export-progress")
                }
            }
            .fileExporter(
                isPresented: $isSaving,
                document: document,
                contentTypes: [.folder],
                defaultFilename: "meh.md Export",
                onCompletion: { result in
                    document = nil
                    isPresented = false
                    switch result {
                    case .success:
                        alert = .success
                    case .failure(let error):
                        let cocoaError = error as NSError
                        guard cocoaError.domain != NSCocoaErrorDomain
                                || cocoaError.code != CocoaError.userCancelled.rawValue
                        else { return }
                        alert = .failure(error.localizedDescription)
                    }
                },
                onCancellation: {
                    document = nil
                    isPresented = false
                }
            )
            .onChange(of: isPresented, initial: true) { _, presented in
                if presented {
                    prepareExport()
                } else if isPreparing {
                    preparationTask?.cancel()
                    preparationTask = nil
                    isPreparing = false
                }
            }
            .onDisappear {
                preparationTask?.cancel()
                preparationTask = nil
            }
            .alert(
                alert?.title ?? "Export",
                isPresented: Binding(
                    get: { alert != nil },
                    set: { if !$0 { alert = nil } }
                )
            ) {
                Button("OK", role: .cancel) { alert = nil }
            } message: {
                if case .success? = alert {
                    Text("All notes were exported as Markdown.")
                } else if case .failure(let message)? = alert {
                    Text(message)
                }
            }
    }

    @MainActor
    private func prepareExport() {
        guard isPresented, !isPreparing, !isSaving else { return }
        isPreparing = true
        preparationTask = Task { @MainActor in
            defer {
                isPreparing = false
                preparationTask = nil
            }

            do {
                try await beforeExport()
                try Task.checkCancellation()
                try await replica.flushOpenNotes()
                try Task.checkCancellation()
                let notes = try await replica.persistedNoteSnapshots()
                try Task.checkCancellation()

                let placements = replica.placements
                let linkNotes = replica.linkNotes
                let activeIDs = Set(
                    placements.filter { !$0.isInTrash }.map { $0.item.id }
                )
                let wrapper = try NotebookMarkdownExport.makeWrapper(
                    placements: placements,
                    notes: notes,
                    selectedIDs: activeIDs,
                    originalLinkNotes: linkNotes
                )
                try Task.checkCancellation()
                document = NotebookMarkdownExportDocument(wrapper: wrapper)
                isSaving = true
            } catch is CancellationError {
                // The presentation ended while its export was being prepared.
            } catch {
                guard !Task.isCancelled else { return }
                isPresented = false
                alert = .failure(error.localizedDescription)
            }
        }
    }

    private enum ExportAlert {
        case success
        case failure(String)

        var title: LocalizedStringResource {
            switch self {
            case .success: "Export Complete"
            case .failure: "Couldn’t Export Notes"
            }
        }

    }
}

private struct NotebookMarkdownExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.folder] }

    let wrapper: FileWrapper

    init(wrapper: FileWrapper) {
        self.wrapper = wrapper
    }

    init(configuration: ReadConfiguration) throws {
        wrapper = configuration.file
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        wrapper
    }
}
