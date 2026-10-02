import Foundation
import Observation

public enum NotebookAttachmentTransferStatus: Equatable, Sendable {
    case uploading, downloading, available, uploaded
    case failed(String)
}

private struct AttachmentSyncState: Codable {
    var version = 1
    let notebookID: UUID
    let scope: String
    var uploaded: [UUID: NotebookAttachmentContent] = [:]
    var requestedDownloads: Set<UUID> = []
    var pendingDeletions: Set<UUID> = []
    var completedDeletions: Set<UUID> = []
    var retryNotBefore: Date?
    var serverNotBefore: Date?
}

/// Attachment work has its own durable progress and never holds the Markdown
/// exchange open. One upload and one requested download may run concurrently.
@MainActor
@Observable
public final class NotebookAttachmentSyncCoordinator {
    public private(set) var statuses: [UUID: NotebookAttachmentTransferStatus] = [:]
    public private(set) var errorMessage: String?
    public private(set) var isSyncing = false
    public private(set) var pendingUploadCount = 0
    @ObservationIgnored private let replica: NotebookReplica
    @ObservationIgnored private let transport: any NotebookAttachmentTransport
    @ObservationIgnored private let stateURL: URL
    @ObservationIgnored private var state: AttachmentSyncState
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var downloads: [UUID: Task<URL, Error>] = [:]
    @ObservationIgnored private var downloadTail: Task<URL, Error>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retryPolicy = NotebookSyncRetryPolicy()
    @ObservationIgnored private var anotherPass = false
    @ObservationIgnored private var stopped = false

    public init(replica: NotebookReplica, transport: any NotebookAttachmentTransport) throws {
        guard let notebookID = replica.catalogSnapshot?.notebookID else {
            throw NotebookReplicaError.notJoined
        }
        self.replica = replica
        self.transport = transport
        stateURL = replica.directory.appending(path: "attachment-sync-state.json")
        do {
            state = try JSONDecoder().decode(
                AttachmentSyncState.self, from: Data(contentsOf: stateURL))
            guard state.version == 1, state.notebookID == notebookID else {
                throw SyncError.identityConflict
            }
            guard state.scope == transport.scope else { throw SyncError.scopeChanged }
        } catch CocoaError.fileReadNoSuchFile {
            state = AttachmentSyncState(notebookID: notebookID, scope: transport.scope)
        }
        for id in state.uploaded.keys { statuses[id] = .uploaded }
        updatePendingCount()
    }

    public func stop() {
        stopped = true
        worker?.cancel()
        downloads.values.forEach { $0.cancel() }
        retryTask?.cancel()
    }

    /// The caller supplies only deletion IDs from a remotely acknowledged
    /// catalog. Local deletion alone is not authorization for remote cleanup.
    public func synchronize(
        confirmedDeletedIDs: Set<UUID> = [], force: Bool = false
    ) async {
        guard !stopped else { return }
        do {
            try checkNotebook()
            state.pendingDeletions.formUnion(
                confirmedDeletedIDs.subtracting(state.completedDeletions))
            for id in confirmedDeletedIDs {
                state.uploaded[id] = nil
                state.requestedDownloads.remove(id)
                statuses[id] = nil
            }
            if force { state.retryNotBefore = nil }
            try save()
        } catch { errorMessage = error.localizedDescription; return }
        let deadline = max(state.serverNotBefore ?? .distantPast,
                           force ? .distantPast : state.retryNotBefore ?? .distantPast)
        if deadline > Date() {
            armRetry(at: deadline)
            return
        }
        state.retryNotBefore = nil
        if let worker {
            anotherPass = true
            await worker.value
            return
        }
        let task = Task { @MainActor in
            isSyncing = true
            defer { isSyncing = false; worker = nil }
            repeat {
                anotherPass = false
                await exchange()
            } while anotherPass && !Task.isCancelled && state.retryNotBefore == nil
        }
        worker = task
        await task.value
    }

    public func prepareAttachment(_ id: UUID) async throws -> URL {
        try checkNotebook()
        let descriptor = try replica.attachmentDescriptor(for: id)
        do {
            let url = try await replica.attachmentFileURL(for: id)
            if state.requestedDownloads.remove(id) != nil {
                state.uploaded[id] = descriptor.content
                try save()
            }
            if state.uploaded[id] != descriptor.content { statuses[id] = .available }
            return url
        } catch NotebookAttachmentError.missing {
            // A catalog reference can arrive well before the large file.
        }
        if let task = downloads[id] { return try await task.value }
        state.requestedDownloads.insert(id)
        try save()
        if let deadline = state.serverNotBefore, deadline > Date() {
            armRetry(at: deadline)
            throw SyncError.unavailable("iCloud asked to pause file transfers. They will retry automatically.")
        }
        let previous = downloadTail
        let task = Task { @MainActor in
            // A single download lane bounds disk and network pressure.
            if let previous { _ = try? await previous.value }
            try Task.checkCancellation()
            return try await receive(descriptor)
        }
        downloads[id] = task
        downloadTail = task
        defer {
            downloads[id] = nil
            if downloads.isEmpty { downloadTail = nil }
        }
        return try await task.value
    }

    private func exchange() async {
        errorMessage = nil
        var failure: (any Error)?
        do {
            try checkNotebook()
            for id in state.pendingDeletions.sorted(by: { $0.uuidString < $1.uuidString }) {
                try Task.checkCancellation()
                try await transport.delete(attachmentIDs: [id], notebookID: state.notebookID)
                try checkNotebook()
                state.pendingDeletions.remove(id)
                state.completedDeletions.insert(id)
                try save()
            }
        } catch {
            failure = error
            errorMessage = error.localizedDescription
            recordRetry(for: error)
        }

        // Resume only downloads explicitly requested by the user, including
        // those interrupted by termination. Other remote files stay on demand.
        for id in state.requestedDownloads {
            guard !Task.isCancelled, !stopped else { break }
            if let deadline = state.retryNotBefore, deadline > Date() { break }
            if (try? replica.attachmentDescriptor(for: id)) == nil {
                state.requestedDownloads.remove(id)
                continue
            }
            do { _ = try await prepareAttachment(id) }
            catch { failure = error; errorMessage = error.localizedDescription }
        }

        do {
            let descriptors = try replica.attachmentDescriptors()
            for descriptor in descriptors {
                try Task.checkCancellation()
                try checkNotebook()
                if let deadline = state.retryNotBefore, deadline > Date() { break }
                guard state.uploaded[descriptor.id] != descriptor.content,
                      !state.pendingDeletions.contains(descriptor.id),
                      !state.completedDeletions.contains(descriptor.id) else { continue }
                do {
                    // Missing local content is normal for received metadata.
                    _ = try await replica.attachmentStore.descriptor(for: descriptor.id)
                } catch NotebookAttachmentError.missing { continue }
                do { try await send(descriptor) }
                catch {
                    failure = error
                    errorMessage = error.localizedDescription
                    recordRetry(for: error)
                    if (try? replica.deletedIDs.contains(descriptor.id)) != true {
                        statuses[descriptor.id] = .failed(error.localizedDescription)
                    }
                }
            }
        } catch { failure = error; errorMessage = error.localizedDescription }
        do {
            if failure == nil {
                retryPolicy.reset()
                state.retryNotBefore = nil
            }
            try save()
        } catch { errorMessage = error.localizedDescription }
    }

    private func send(_ descriptor: NotebookAttachmentDescriptor) async throws {
        statuses[descriptor.id] = .uploading
        let temporary = try transferURL(for: descriptor.id)
        defer { try? FileManager.default.removeItem(at: temporary) }
        // Keep a verified, independent file alive throughout CKAsset upload;
        // local deletion may remove the authoritative store while awaiting it.
        try await replica.attachmentStore.export(descriptor, to: temporary)
        try ensureCurrent(descriptor)
        try await transport.upload(descriptor, notebookID: state.notebookID, from: temporary)
        try ensureCurrent(descriptor)
        state.uploaded[descriptor.id] = descriptor.content
        try save()
        statuses[descriptor.id] = .uploaded
    }

    private func receive(_ descriptor: NotebookAttachmentDescriptor) async throws -> URL {
        // A previous download can establish a deadline while this one waits
        // for its turn in the download lane.
        if let deadline = state.serverNotBefore, deadline > Date() {
            armRetry(at: deadline)
            throw SyncError.unavailable("iCloud asked to pause file transfers. They will retry automatically.")
        }
        statuses[descriptor.id] = .downloading
        do {
            try ensureCurrent(descriptor)
            let temporary = try transferURL(for: descriptor.id)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try await transport.download(
                descriptor, notebookID: state.notebookID, to: temporary)
            try ensureCurrent(descriptor)
            try await replica.acceptAttachmentFile(at: temporary, descriptor: descriptor)
            try ensureCurrent(descriptor)
            state.uploaded[descriptor.id] = descriptor.content
            state.requestedDownloads.remove(descriptor.id)
            try save()
            statuses[descriptor.id] = .available
            return try await replica.attachmentFileURL(for: descriptor.id)
        } catch {
            if (try? replica.deletedIDs.contains(descriptor.id)) != true {
                statuses[descriptor.id] = .failed(error.localizedDescription)
            }
            errorMessage = error.localizedDescription
            recordRetry(for: error)
            try? save()
            throw error
        }
    }

    private func checkNotebook() throws {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        guard !replica.localEditsSuspended else { throw NotebookReplicaError.resetPending }
        guard replica.catalogSnapshot?.notebookID == state.notebookID else {
            throw SyncError.identityConflict
        }
    }

    private func ensureCurrent(_ descriptor: NotebookAttachmentDescriptor) throws {
        try checkNotebook()
        guard try replica.attachmentDescriptor(for: descriptor.id) == descriptor else {
            throw NotebookAttachmentError.identityConflict(descriptor.id)
        }
    }

    private func transferURL(for id: UUID) throws -> URL {
        let directory = replica.directory.appending(
            path: "attachment-transfers/\(id.uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: UUID().uuidString)
    }

    private func save() throws {
        try SyncFileIO.replace(JSONEncoder().encode(state), at: stateURL)
        updatePendingCount()
    }

    private func updatePendingCount() {
        pendingUploadCount = ((try? replica.attachmentDescriptors()) ?? []).filter { item in
            state.uploaded[item.id] != item.content
                && FileManager.default.fileExists(atPath: replica.directory.appending(
                    path: "attachments/\(item.id.uuidString)/content").path)
        }.count
    }

    private func recordRetry(for error: any Error) {
        let now = Date()
        if let seconds = CloudKitRetryMetadata.seconds(in: error) {
            state.serverNotBefore = max(state.serverNotBefore ?? .distantPast,
                                        now.addingTimeInterval(seconds))
        }
        let retryError: any Error
        if let error = error as? NotebookAttachmentTransferError,
           error == .notUploaded || error == .unacknowledged
            || error == .accountUnavailable {
            retryError = SyncError.unavailable(error.localizedDescription)
        } else { retryError = error }
        let local = retryPolicy.retryDate(for: retryError, now: now,
                                          serverNotBefore: state.serverNotBefore)
        let deadline = max(local ?? .distantPast, state.serverNotBefore ?? .distantPast)
        if deadline > now {
            state.retryNotBefore = deadline
            armRetry(at: deadline)
        }
    }

    private func armRetry(at deadline: Date) {
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
            catch { return }
            guard let self, !stopped else { return }
            await synchronize()
        }
    }
}
