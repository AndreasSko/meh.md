import CryptoKit
import Darwin
import Foundation

enum NotebookAttachmentWriteStage: Sendable {
    case contentSynced
    case manifestSynced
    case published
}

/// Stores immutable attachment bytes beneath one notebook's attachment directory.
/// The parent notebook directory must already exist.
public actor NotebookAttachmentStore {
    private struct Manifest: Codable {
        let schemaVersion: Int
        let descriptor: NotebookAttachmentDescriptor
    }

    private let directory: URL
    private let writeStageHook: (@Sendable (NotebookAttachmentWriteStage) throws -> Void)?
    private let fileManager = FileManager.default
    private static let chunkSize = 64 * 1024
    private static let manifestLimit = 16 * 1024

    public init(directory: URL) {
        self.directory = directory
        self.writeStageHook = nil
    }

    init(
        directory: URL,
        writeStageHook: @escaping @Sendable
            (NotebookAttachmentWriteStage) throws -> Void
    ) {
        self.directory = directory
        self.writeStageHook = writeStageHook
    }

    public func storeFile(
        at sourceURL: URL,
        attachmentID: UUID,
        expectedContent: NotebookAttachmentContent? = nil
    ) async throws -> NotebookAttachmentDescriptor {
        try storeFileContents(
            at: sourceURL, attachmentID: attachmentID,
            expectedContent: expectedContent
        )
    }

    /// File-provider sources can be placeholders. Keep the entire durable
    /// streamed copy inside the coordinator's synchronous read accessor.
    public func storeCoordinatedFile(
        at sourceURL: URL,
        attachmentID: UUID,
        expectedContent: NotebookAttachmentContent? = nil
    ) async throws -> NotebookAttachmentDescriptor {
        try Task.checkCancellation()
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        var outcome: Result<NotebookAttachmentDescriptor, Error>?
        coordinator.coordinate(
            readingItemAt: sourceURL, options: [], error: &coordinatorError
        ) { coordinatedURL in
            outcome = Result {
                try storeFileContents(
                    at: coordinatedURL, attachmentID: attachmentID,
                    expectedContent: expectedContent
                )
            }
        }
        if let outcome { return try outcome.get() }
        if let coordinatorError { throw coordinatorError }
        throw NotebookAttachmentError.unsupportedSource
    }

    /// Read a selected source and publish its files while the provider's
    /// coordinated URL remains valid. The caller's walk is synchronous.
    func withCoordinatedRead<T: Sendable>(
        at sourceURL: URL,
        _ walk: @Sendable (
            URL, (URL, UUID) throws -> NotebookAttachmentDescriptor
        ) throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        var outcome: Result<T, Error>?
        coordinator.coordinate(
            readingItemAt: sourceURL, options: [], error: &coordinatorError
        ) { coordinatedURL in
            outcome = Result {
                try walk(coordinatedURL) { fileURL, id in
                    try storeFileContents(
                        at: fileURL, attachmentID: id,
                        expectedContent: nil
                    )
                }
            }
        }
        if let outcome { return try outcome.get() }
        if let coordinatorError { throw coordinatorError }
        throw NotebookAttachmentError.unsupportedSource
    }

    private func storeFileContents(
        at sourceURL: URL,
        attachmentID: UUID,
        expectedContent: NotebookAttachmentContent?
    ) throws -> NotebookAttachmentDescriptor {
        try Task.checkCancellation()
        try ensureDirectory()
        let stage = directory.appendingPathComponent(
            ".stage-\(UUID().uuidString)", isDirectory: true
        )
        guard mkdir(stage.path, S_IRUSR | S_IWUSR | S_IXUSR) == 0 else {
            throw DurableFileIO.posixError()
        }
        defer { try? fileManager.removeItem(at: stage) }

        let contentURL = stage.appendingPathComponent("content")
        let content = try streamCopy(sourceURL, to: contentURL)
        try writeStageHook?(.contentSynced)
        if let expectedContent, content != expectedContent {
            throw NotebookAttachmentError.checksumMismatch
        }
        let descriptor = NotebookAttachmentDescriptor(
            id: attachmentID, content: content
        )
        let manifest = Manifest(schemaVersion: 1, descriptor: descriptor)
        try DurableFileIO.writeAndSync(
            JSONEncoder().encode(manifest),
            to: stage.appendingPathComponent("manifest.json")
        )
        try DurableFileIO.syncDirectory(stage)
        try writeStageHook?(.manifestSynced)

        let target = itemDirectory(for: attachmentID)
        do {
            try Task.checkCancellation()
            try renameExclusive(stage, to: target)
            try writeStageHook?(.published)
            try DurableFileIO.syncDirectory(directory)
            return descriptor
        } catch {
            guard (error as NSError).domain == NSPOSIXErrorDomain,
                  (error as NSError).code == EEXIST else { throw error }
            let stored = try readManifest(for: attachmentID).descriptor
            guard stored.content == content else {
                throw NotebookAttachmentError.identityConflict(attachmentID)
            }
            try verify(stored)
            try syncStoredItem(stored.id)
            return stored
        }
    }

    public func descriptor(for id: UUID) async throws -> NotebookAttachmentDescriptor {
        try readManifest(for: id).descriptor
    }

    /// The returned URL is for read-only, app-internal use. Call again before
    /// each use if another process could have modified the attachment.
    public func verifiedFileURL(
        for descriptor: NotebookAttachmentDescriptor
    ) async throws -> URL {
        try verify(descriptor)
        return contentURL(for: descriptor.id)
    }

    /// Checks an external regular file without copying or retaining its bytes.
    func verifyExternalFile(
        at fileURL: URL, expectedContent: NotebookAttachmentContent
    ) throws {
        guard try hashFile(fileURL) == expectedContent else {
            throw NotebookAttachmentError.checksumMismatch
        }
    }

    public func export(
        _ descriptor: NotebookAttachmentDescriptor,
        to destination: URL
    ) async throws {
        try verify(descriptor)
        let parent = destination.deletingLastPathComponent()
        let stage = parent.appendingPathComponent(
            ".attachment-export-\(UUID().uuidString)"
        )
        defer { try? fileManager.removeItem(at: stage) }
        let copied = try streamCopy(contentURL(for: descriptor.id), to: stage)
        guard copied == descriptor.content else {
            throw NotebookAttachmentError.checksumMismatch
        }
        do {
            try Task.checkCancellation()
            try renameExclusive(stage, to: destination)
        } catch {
            if (error as NSError).domain == NSPOSIXErrorDomain,
               (error as NSError).code == EEXIST {
                throw NotebookAttachmentError.destinationExists
            }
            throw error
        }
        try DurableFileIO.syncDirectory(parent)
    }

    public func remove(id: UUID) async throws {
        try Task.checkCancellation()
        let target = itemDirectory(for: id)
        var information = stat()
        guard lstat(target.path, &information) == 0 else {
            if errno == ENOENT {
                if fileManager.fileExists(atPath: directory.path) {
                    try DurableFileIO.syncDirectory(directory)
                }
                return
            }
            throw DurableFileIO.posixError()
        }
        guard information.st_mode & S_IFMT == S_IFDIR else {
            throw NotebookAttachmentError.invalidStoredAttachment
        }
        try fileManager.removeItem(at: target)
        try DurableFileIO.syncDirectory(directory)
    }

    private func ensureDirectory() throws {
        let parent = directory.deletingLastPathComponent()
        var information = stat()
        guard lstat(parent.path, &information) == 0,
              information.st_mode & S_IFMT == S_IFDIR else {
            throw NotebookAttachmentError.invalidStoredAttachment
        }
        if lstat(directory.path, &information) != 0 {
            guard errno == ENOENT else { throw DurableFileIO.posixError() }
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: false
            )
        }
        guard lstat(directory.path, &information) == 0,
              information.st_mode & S_IFMT == S_IFDIR else {
            throw NotebookAttachmentError.invalidStoredAttachment
        }
        try DurableFileIO.syncDirectory(parent)
    }

    private func readManifest(for id: UUID) throws -> Manifest {
        let item = itemDirectory(for: id)
        var information = stat()
        guard lstat(item.path, &information) == 0 else {
            if errno == ENOENT { throw NotebookAttachmentError.missing(id) }
            throw DurableFileIO.posixError()
        }
        guard information.st_mode & S_IFMT == S_IFDIR else {
            throw NotebookAttachmentError.invalidStoredAttachment
        }
        let url = item.appendingPathComponent("manifest.json")
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            throw NotebookAttachmentError.invalidStoredAttachment
        }
        defer { close(fd) }
        guard fstat(fd, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_size >= 0,
              information.st_size <= Self.manifestLimit else {
            throw NotebookAttachmentError.invalidStoredAttachment
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0, data.count + count <= Self.manifestLimit else {
                throw NotebookAttachmentError.invalidStoredAttachment
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[..<count])
        }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            throw NotebookAttachmentError.invalidStoredAttachment
        }
        guard manifest.schemaVersion == 1 else {
            throw NotebookAttachmentError.unsupportedFormat
        }
        guard
              manifest.descriptor.id == id,
              (try? NotebookAttachmentContent(
                sha256: manifest.descriptor.content.sha256,
                byteCount: manifest.descriptor.content.byteCount
              )) != nil else {
            throw NotebookAttachmentError.invalidStoredAttachment
        }
        return manifest
    }

    private func verify(_ descriptor: NotebookAttachmentDescriptor) throws {
        let stored = try readManifest(for: descriptor.id).descriptor
        guard stored == descriptor else {
            throw NotebookAttachmentError.identityConflict(descriptor.id)
        }
        let actual = try hashFile(contentURL(for: descriptor.id))
        guard actual == descriptor.content else {
            throw NotebookAttachmentError.checksumMismatch
        }
    }

    private func syncStoredItem(_ id: UUID) throws {
        let url = contentURL(for: id)
        let fd = try openRegularFile(url)
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw DurableFileIO.posixError() }
        let manifest = itemDirectory(for: id)
            .appendingPathComponent("manifest.json")
        let manifestFD = try openRegularFile(manifest)
        defer { close(manifestFD) }
        guard fsync(manifestFD) == 0 else {
            throw DurableFileIO.posixError()
        }
        try DurableFileIO.syncDirectory(itemDirectory(for: id))
        try DurableFileIO.syncDirectory(directory)
    }

    private func hashFile(_ url: URL) throws -> NotebookAttachmentContent {
        let fd = try openRegularFile(url)
        defer { close(fd) }
        var hasher = SHA256()
        var bytes: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: Self.chunkSize)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw DurableFileIO.posixError() }
            if count == 0 { break }
            let (next, overflow) = bytes.addingReportingOverflow(Int64(count))
            guard !overflow else { throw NotebookAttachmentError.invalidStoredAttachment }
            bytes = next
            hasher.update(data: Data(buffer[..<count]))
        }
        return try NotebookAttachmentContent(
            sha256: Self.hexDigest(hasher.finalize()), byteCount: bytes
        )
    }

    private func streamCopy(_ source: URL, to destination: URL) throws
        -> NotebookAttachmentContent {
        let input = try openRegularFile(source)
        defer { close(input) }
        var before = stat()
        guard fstat(input, &before) == 0 else {
            throw DurableFileIO.posixError()
        }
        let output = open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard output >= 0 else { throw DurableFileIO.posixError() }
        defer { close(output) }
        var hasher = SHA256()
        var bytes: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: Self.chunkSize)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(input, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw DurableFileIO.posixError() }
            if count == 0 { break }
            let (next, overflow) = bytes.addingReportingOverflow(Int64(count))
            guard !overflow else { throw NotebookAttachmentError.invalidMetadata }
            bytes = next
            hasher.update(data: Data(buffer[..<count]))
            var written = 0
            while written < count {
                let result = buffer.withUnsafeBytes { raw in
                    Darwin.write(
                        output, raw.baseAddress!.advanced(by: written),
                        count - written
                    )
                }
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw DurableFileIO.posixError() }
                written += result
            }
        }
        var after = stat()
        guard fstat(input, &after) == 0 else {
            throw DurableFileIO.posixError()
        }
        guard before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              bytes == after.st_size else {
            throw NotebookAttachmentError.sourceChanged
        }
        guard fsync(output) == 0 else { throw DurableFileIO.posixError() }
        return try NotebookAttachmentContent(
            sha256: Self.hexDigest(hasher.finalize()), byteCount: bytes
        )
    }

    private func openRegularFile(_ url: URL) throws -> Int32 {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ELOOP || errno == EISDIR {
                throw NotebookAttachmentError.unsupportedSource
            }
            throw DurableFileIO.posixError()
        }
        var information = stat()
        guard fstat(fd, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            throw NotebookAttachmentError.unsupportedSource
        }
        return fd
    }

    private func renameExclusive(_ source: URL, to destination: URL) throws {
        let result = source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                renamex_np(from, to, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else { throw DurableFileIO.posixError() }
    }

    private func itemDirectory(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func contentURL(for id: UUID) -> URL {
        itemDirectory(for: id).appendingPathComponent("content")
    }

    private static func hexDigest(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
