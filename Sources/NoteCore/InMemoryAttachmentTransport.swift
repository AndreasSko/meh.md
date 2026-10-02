import Foundation

/// File-backed shared service for deterministic cross-device transfer tests.
public actor InMemoryAttachmentStore {
    private struct Key: Hashable {
        let scope: String
        let notebookID: UUID
        let attachmentID: UUID
    }

    private struct Entry {
        let descriptor: NotebookAttachmentDescriptor
        let store: NotebookAttachmentStore
    }

    private let directory: URL
    private var entries: [Key: Entry] = [:]
    private var tombstones = Set<Key>()
    private var offline = false
    private var lostAcknowledgements = 0

    public init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("in-memory-attachments-\(UUID().uuidString)")
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    public func setOffline(_ value: Bool) { offline = value }

    public func loseNextAcknowledgement() { lostAcknowledgements += 1 }

    fileprivate func upload(
        scope: String, descriptor: NotebookAttachmentDescriptor,
        notebookID: UUID, source: URL
    ) async throws {
        try requireOnline()
        let key = Key(scope: scope, notebookID: notebookID,
            attachmentID: descriptor.id)
        if tombstones.contains(key) {
            throw NotebookAttachmentTransferError.deleted
        }
        if let entry = entries[key] {
            guard entry.descriptor == descriptor else {
                throw NotebookAttachmentTransferError.mismatchedRecord
            }
            // Verify both sides even when this is a lost-ack retry.
            let sourceStage = try NotebookAttachmentTransferStage.make(near: source)
            defer { try? FileManager.default.removeItem(at: sourceStage.directory) }
            _ = try await sourceStage.store.storeFile(
                at: source, attachmentID: descriptor.id,
                expectedContent: descriptor.content)
            _ = try await entry.store.verifiedFileURL(for: descriptor)
            if tombstones.contains(key) {
                throw NotebookAttachmentTransferError.deleted
            }
            return
        }
        try FileManager.default.createDirectory(at: directory,
            withIntermediateDirectories: true)
        let itemDirectory = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: itemDirectory,
            withIntermediateDirectories: false)
        let store = NotebookAttachmentStore(
            directory: itemDirectory.appendingPathComponent("files"))
        do {
            _ = try await store.storeFile(
                at: source, attachmentID: descriptor.id,
                expectedContent: descriptor.content)
            if tombstones.contains(key) {
                try await store.remove(id: descriptor.id)
                throw NotebookAttachmentTransferError.deleted
            }
            entries[key] = Entry(descriptor: descriptor, store: store)
            try acknowledge()
        } catch {
            if entries[key] == nil {
                try? FileManager.default.removeItem(at: itemDirectory)
            }
            throw error
        }
    }

    fileprivate func download(
        scope: String, descriptor: NotebookAttachmentDescriptor,
        notebookID: UUID, destination: URL
    ) async throws {
        try requireOnline()
        let key = Key(scope: scope, notebookID: notebookID,
            attachmentID: descriptor.id)
        if tombstones.contains(key) {
            throw NotebookAttachmentTransferError.deleted
        }
        guard let entry = entries[key] else {
            throw NotebookAttachmentTransferError.notUploaded
        }
        guard entry.descriptor == descriptor else {
            throw NotebookAttachmentTransferError.mismatchedRecord
        }
        do {
            try await entry.store.export(descriptor, to: destination)
        } catch NotebookAttachmentError.destinationExists {
            throw NotebookAttachmentTransferError.destinationExists
        }
        if tombstones.contains(key) {
            try? FileManager.default.removeItem(at: destination)
            throw NotebookAttachmentTransferError.deleted
        }
    }

    fileprivate func delete(
        scope: String, attachmentIDs: Set<UUID>, notebookID: UUID
    ) async throws {
        try requireOnline()
        for id in attachmentIDs {
            let key = Key(scope: scope, notebookID: notebookID,
                attachmentID: id)
            tombstones.insert(key)
            if let entry = entries[key] {
                // An existing file's bytes are removed when its tombstone lands.
                try await entry.store.remove(id: id)
            }
            entries.removeValue(forKey: key)
            try acknowledge()
        }
    }

    private func requireOnline() throws {
        if offline { throw NotebookAttachmentTransferError.accountUnavailable }
    }

    private func acknowledge() throws {
        if lostAcknowledgements > 0 {
            lostAcknowledgements -= 1
            throw NotebookAttachmentTransferError.unacknowledged
        }
    }
}

public actor InMemoryAttachmentTransport: NotebookAttachmentTransport {
    public nonisolated let scope: String
    private let store: InMemoryAttachmentStore

    public init(scope: String, store: InMemoryAttachmentStore) {
        self.scope = scope
        self.store = store
    }

    public func upload(
        _ descriptor: NotebookAttachmentDescriptor,
        notebookID: UUID, from fileURL: URL
    ) async throws {
        try await store.upload(scope: scope, descriptor: descriptor,
            notebookID: notebookID, source: fileURL)
    }

    public func download(
        _ descriptor: NotebookAttachmentDescriptor,
        notebookID: UUID, to destination: URL
    ) async throws {
        try await store.download(scope: scope, descriptor: descriptor,
            notebookID: notebookID, destination: destination)
    }

    public func delete(
        attachmentIDs: Set<UUID>, notebookID: UUID
    ) async throws {
        try await store.delete(scope: scope, attachmentIDs: attachmentIDs,
            notebookID: notebookID)
    }
}
