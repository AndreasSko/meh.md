import Foundation
import NoteCore
import QuickLook
import SwiftUI

struct NotebookAttachmentView: View {
    let placement: NotebookPlacement
    let replica: NotebookReplica
    let prepareFile: (UUID) async throws -> URL
    let rename: () -> Void
    let move: () -> Void
    let trash: () -> Void
    let restore: () -> Void
    var transferStatus: NotebookAttachmentTransferStatus? = nil
    var transferError: String? = nil

    @State private var exportedURL: URL?
    @State private var previewURL: URL?
    @State private var isPreparing = false
    @State private var errorMessage: String?
    @State private var generation = 0
    @State private var preparation: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc")
                .font(.system(size: 64, weight: .ultraLight))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(placement.displayName)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("notebook-attachment-title")
                if let size = placement.item.attachment?.byteCount {
                    Text(Int64(size), format: .byteCount(style: .file))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if isPreparing {
                ProgressView(statusText)
                    .accessibilityIdentifier("notebook-attachment-loading")
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.icloud")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("notebook-attachment-error")
                Button("Try Again") { prepare() }
                    .accessibilityIdentifier("notebook-attachment-retry")
            } else if exportedURL != nil {
                if case .uploading = transferStatus {
                    Label("Uploading to iCloud…", systemImage: "icloud.and.arrow.up")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Ready to preview or share", systemImage: "checkmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("Available from iCloud", systemImage: "icloud.and.arrow.down")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Download") { prepare() }
                    .accessibilityIdentifier("notebook-attachment-download")
            }
            if let transferError, errorMessage == nil {
                Text(transferError)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Button("Preview") { previewURL = exportedURL }
                    .disabled(exportedURL == nil || isPreparing)
                    .accessibilityIdentifier("notebook-attachment-preview")
                if let exportedURL {
                    ShareLink(item: exportedURL) {
                        Label("Share or Export", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("notebook-attachment-export")
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(placement.displayName)
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Rename…", action: rename)
                    Button("Move…", action: move)
                    Divider()
                    if placement.isInTrash {
                        Button("Restore", action: restore)
                    } else {
                        Button("Move to Trash", role: .destructive,
                               action: trash)
                    }
                } label: {
                    Label("File Actions", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("notebook-attachment-actions")
            }
        }
        .quickLookPreview($previewURL)
        .task(id: placement.displayName) {
            cleanup()
            prepare()
        }
        .onDisappear { cleanup() }
    }

    private var statusText: LocalizedStringResource {
        if case .downloading = transferStatus { return "Downloading from iCloud…" }
        return "Preparing file…"
    }

    private func prepare() {
        guard !isPreparing else { return }
        generation &+= 1
        let currentGeneration = generation
        isPreparing = true
        errorMessage = nil
        preparation = Task { @MainActor in
            var directory: URL?
            do {
                _ = try await prepareFile(placement.item.id)
                let descriptor = try replica.attachmentDescriptor(
                    for: placement.item.id
                )
                let temporaryDirectory = replica.directory
                    .appendingPathComponent("attachment-previews", isDirectory: true)
                    .appendingPathComponent(placement.item.id.uuidString,
                                            isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                directory = temporaryDirectory
                try FileManager.default.createDirectory(
                    at: temporaryDirectory, withIntermediateDirectories: true
                )
                let copy = temporaryDirectory.appendingPathComponent(
                    placement.displayName
                )
                try await replica.attachmentStore.export(descriptor, to: copy)
                try Task.checkCancellation()
                guard try replica.attachmentDescriptor(for: placement.item.id)
                    == descriptor else {
                    throw NotebookAttachmentError.missing(placement.item.id)
                }
                guard generation == currentGeneration else {
                    try? FileManager.default.removeItem(at: temporaryDirectory)
                    return
                }
                cleanupCopy()
                exportedURL = copy
                directory = nil
            } catch {
                if let directory { try? FileManager.default.removeItem(at: directory) }
                if generation == currentGeneration, !(error is CancellationError) {
                    if case .failed(let message) = transferStatus {
                        errorMessage = message
                    } else {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            if generation == currentGeneration { isPreparing = false }
        }
    }

    private func cleanup() {
        preparation?.cancel()
        preparation = nil
        generation &+= 1
        isPreparing = false
        previewURL = nil
        cleanupCopy()
    }

    private func cleanupCopy() {
        if let exportedURL {
            try? FileManager.default.removeItem(
                at: exportedURL.deletingLastPathComponent()
            )
            self.exportedURL = nil
        }
    }
}
