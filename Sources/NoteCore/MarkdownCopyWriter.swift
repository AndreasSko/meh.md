import CryptoKit
import Darwin
import Foundation

enum MarkdownCopyWriteStage: Equatable {
    case pendingRecorded
    case stagedFileSynced
    case destinationReplaced
    case replacementVerified
    case bookkeepingRecorded
}

public actor MarkdownCopyWriter {
    public nonisolated let copyURL: URL
    public nonisolated let metadataURL: URL

    private static let bookkeepingVersion = 1
    private static let stagePrefix = ".meh-markdown-stage-"
    private let destinationDirectory: URL
    private let metadataDirectory: URL

    public init(destinationDirectory: URL, metadataDirectory: URL) {
        self.destinationDirectory = destinationDirectory
        self.metadataDirectory = metadataDirectory
        copyURL = destinationDirectory.appendingPathComponent("note.md")
        metadataURL = metadataDirectory.appendingPathComponent(
            "markdown-copy-state.json"
        )
    }

    public func publish(
        _ snapshot: MarkdownCopySnapshot
    ) async throws -> MarkdownCopyReport {
        try materialize(snapshot, afterStage: { _ in })
    }

    public func reconcile(
        with snapshot: MarkdownCopySnapshot
    ) async throws -> MarkdownCopyReport {
        try materialize(snapshot, afterStage: { _ in })
    }

    func publish(
        _ snapshot: MarkdownCopySnapshot,
        afterStage: (MarkdownCopyWriteStage) throws -> Void,
        beforeReplacement: () throws -> Void = {}
    ) throws -> MarkdownCopyReport {
        try materialize(
            snapshot,
            afterStage: afterStage,
            beforeReplacement: beforeReplacement
        )
    }

    private func materialize(
        _ snapshot: MarkdownCopySnapshot,
        afterStage: (MarkdownCopyWriteStage) throws -> Void,
        beforeReplacement: () throws -> Void = {}
    ) throws -> MarkdownCopyReport {
        let identity = try validateDestinationDirectory()
        var record: Bookkeeping
        if let stored = try loadRecord() {
            guard stored.noteID == snapshot.noteID else {
                throw MarkdownCopyError.noteIdentityMismatch
            }
            guard stored.destinationIdentity == identity else {
                return .paused(.destinationReplaced)
            }
            record = stored
        } else {
            switch try inspect(copyURL) {
            case .absent:
                record = Bookkeeping(
                    version: Self.bookkeepingVersion,
                    noteID: snapshot.noteID,
                    destinationIdentity: identity
                )
            case .regular:
                return .paused(.preexistingFile)
            case .unsafe:
                return .paused(.unsafeDestination)
            }
        }

        if let pending = record.pending,
           let report = try recover(
               pending,
               record: &record,
               snapshot: snapshot,
               afterStage: afterStage,
               beforeReplacement: beforeReplacement
           ) {
            return report
        }

        let fingerprint = Self.fingerprint(snapshot.utf8)
        switch try inspect(copyURL, contents: .fingerprint) {
        case .unsafe:
            return .paused(.unsafeDestination)
        case let .regular(observed)
            where record.last != nil
                && observed.fingerprint == fingerprint:
            if record.last?.heads != snapshot.heads.sorted()
                || record.last?.fingerprint != fingerprint {
                record.last = Materialization(snapshot)
                try store(record)
                try afterStage(.bookkeepingRecorded)
            }
            return .current(heads: snapshot.heads)
        case .regular where record.last == nil:
            return .paused(.preexistingFile)
        case .regular, .absent:
            return try beginWrite(
                snapshot,
                record: &record,
                afterStage: afterStage,
                beforeReplacement: beforeReplacement
            )
        }
    }

    private func recover(
        _ pending: PendingAttempt,
        record: inout Bookkeeping,
        snapshot: MarkdownCopySnapshot,
        afterStage: (MarkdownCopyWriteStage) throws -> Void,
        beforeReplacement: () throws -> Void
    ) throws -> MarkdownCopyReport? {
        guard isValidStageName(pending.stageName) else {
            throw MarkdownCopyError.invalidBookkeeping
        }
        let stageURL = destinationDirectory.appendingPathComponent(
            pending.stageName
        )

        if case let .regular(destination) = try inspect(
            copyURL,
            contents: .fingerprint
        ),
           destination.fingerprint == pending.fingerprint,
           record.last != nil
                || destination.identity == pending.stagedIdentity {
            try removeStageIfPresent(stageURL)
            record.last = Materialization(pending)
            record.pending = nil
            try store(record)
            try afterStage(.bookkeepingRecorded)
            return nil
        }

        let isDesired = pending.fingerprint == Self.fingerprint(snapshot.utf8)
            && pending.heads == snapshot.heads.sorted()
        guard isDesired else {
            switch try inspect(stageURL) {
            case .absent:
                break
            case .regular:
                try removeManagedStage(stageURL)
            case .unsafe:
                return .paused(.unsafeDestination)
            }
            record.pending = nil
            try store(record)
            return nil
        }

        switch try inspect(stageURL, contents: .fingerprint) {
        case .absent:
            try writeAndSync(snapshot.utf8, to: stageURL)
            try recordStageIdentity(stageURL, in: &record)
            try afterStage(.stagedFileSynced)
        case let .regular(stage)
            where stage.fingerprint == pending.fingerprint
                && (pending.stagedIdentity == nil
                    || pending.stagedIdentity == stage.identity):
            if pending.stagedIdentity == nil {
                try recordStageIdentity(stageURL, in: &record)
            }
        case .regular:
            try removeManagedStage(stageURL)
            try writeAndSync(snapshot.utf8, to: stageURL)
            try recordStageIdentity(stageURL, in: &record)
            try afterStage(.stagedFileSynced)
        case .unsafe:
            return .paused(.unsafeDestination)
        }
        return try install(
            pending,
            stageURL: stageURL,
            record: &record,
            afterStage: afterStage,
            beforeReplacement: beforeReplacement
        )
    }

    private func beginWrite(
        _ snapshot: MarkdownCopySnapshot,
        record: inout Bookkeeping,
        afterStage: (MarkdownCopyWriteStage) throws -> Void,
        beforeReplacement: () throws -> Void
    ) throws -> MarkdownCopyReport {
        let stageName = Self.stagePrefix + UUID().uuidString + ".tmp"
        var pending = PendingAttempt(snapshot, stageName: stageName)
        record.pending = pending
        try store(record)
        try afterStage(.pendingRecorded)

        let stageURL = destinationDirectory.appendingPathComponent(stageName)
        try writeAndSync(snapshot.utf8, to: stageURL)
        guard case let .regular(stage) = try inspect(
            stageURL,
            contents: .fingerprint
        ) else {
            return .paused(.unsafeDestination)
        }
        pending.stagedIdentity = stage.identity
        record.pending = pending
        try store(record)
        try afterStage(.stagedFileSynced)
        return try install(
            pending,
            stageURL: stageURL,
            record: &record,
            afterStage: afterStage,
            beforeReplacement: beforeReplacement
        )
    }

    private func install(
        _ pending: PendingAttempt,
        stageURL: URL,
        record: inout Bookkeeping,
        afterStage: (MarkdownCopyWriteStage) throws -> Void,
        beforeReplacement: () throws -> Void
    ) throws -> MarkdownCopyReport {
        try coordinateWriting(copyURL) { coordinatedURL in
            guard try validateDestinationDirectory()
                    == record.destinationIdentity else {
                return .paused(.destinationReplaced)
            }
            switch try inspect(coordinatedURL) {
            case .unsafe:
                return .paused(.unsafeDestination)
            case .regular where record.last == nil:
                return .paused(.preexistingFile)
            case .absent, .regular:
                break
            }

            try beforeReplacement()
            guard try validateDestinationDirectory()
                    == record.destinationIdentity else {
                return .paused(.destinationReplaced)
            }
            switch try inspect(coordinatedURL) {
            case .unsafe:
                return .paused(.unsafeDestination)
            case .regular where record.last == nil:
                return .paused(.preexistingFile)
            case .absent where record.last == nil:
                do {
                    try renameExclusive(stageURL, to: coordinatedURL)
                } catch let MarkdownCopyError.fileSystem(
                    _, domain, code
                ) where domain == NSPOSIXErrorDomain && code == Int(EEXIST) {
                    return .paused(.preexistingFile)
                }
            case .absent, .regular:
                try renameReplacing(stageURL, with: coordinatedURL)
            }

            try afterStage(.destinationReplaced)
            try syncDirectory(destinationDirectory)
            guard case let .regular(installed) = try inspect(
                coordinatedURL,
                contents: .fingerprint
            ),
                  installed.fingerprint == pending.fingerprint else {
                throw MarkdownCopyError.fileSystem(
                    operation: "verify Markdown copy",
                    domain: NSPOSIXErrorDomain,
                    code: Int(EAGAIN)
                )
            }
            try afterStage(.replacementVerified)
            guard case let .regular(verified) = try inspect(
                coordinatedURL,
                contents: .fingerprint
            ),
                  verified.fingerprint == pending.fingerprint else {
                throw MarkdownCopyError.fileSystem(
                    operation: "verify Markdown copy",
                    domain: NSPOSIXErrorDomain,
                    code: Int(EAGAIN)
                )
            }
            record.last = Materialization(pending)
            record.pending = nil
            try store(record)
            try afterStage(.bookkeepingRecorded)
            return .current(heads: Set(pending.heads))
        }
    }

    private struct ObservedFile {
        let identity: String
        let data: Data?
        let fingerprint: String?
    }

    private enum InspectedContents {
        case none
        case data
        case fingerprint
    }

    private enum Inspection {
        case absent
        case regular(ObservedFile)
        case unsafe
    }

    private func inspect(
        _ url: URL,
        contents: InspectedContents = .none
    ) throws -> Inspection {
        var information = stat()
        let lookup = url.withUnsafeFileSystemRepresentation {
            lstat($0, &information)
        }
        guard lookup == 0 else {
            if errno == ENOENT { return .absent }
            throw posixError(operation: "inspect copy")
        }
        guard information.st_mode & S_IFMT == S_IFREG else { return .unsafe }

        if case .none = contents {
            return .regular(
                ObservedFile(
                    identity: "\(information.st_dev):\(information.st_ino)",
                    data: nil,
                    fingerprint: nil
                )
            )
        }

        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ELOOP { return .unsafe }
            throw posixError(operation: "read copy")
        }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else {
            throw posixError(operation: "inspect open copy")
        }
        guard opened.st_mode & S_IFMT == S_IFREG else { return .unsafe }

        var data = Data()
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw posixError(operation: "read copy") }
            if count == 0 { break }
            switch contents {
            case .none:
                break
            case .data:
                data.append(buffer, count: count)
            case .fingerprint:
                hasher.update(data: Data(buffer[..<count]))
            }
        }
        let identity = "\(opened.st_dev):\(opened.st_ino)"
        switch contents {
        case .none:
            return .regular(
                ObservedFile(
                    identity: identity,
                    data: nil,
                    fingerprint: nil
                )
            )
        case .data:
            return .regular(
                ObservedFile(
                    identity: identity,
                    data: data,
                    fingerprint: nil
                )
            )
        case .fingerprint:
            let fingerprint = hasher.finalize().map {
                String(format: "%02x", $0)
            }.joined()
            return .regular(
                ObservedFile(
                    identity: identity,
                    data: nil,
                    fingerprint: fingerprint
                )
            )
        }
    }

    private func validateDestinationDirectory() throws -> String {
        var information = stat()
        let lookup = destinationDirectory.withUnsafeFileSystemRepresentation {
            lstat($0, &information)
        }
        guard lookup == 0 else {
            throw posixError(operation: "inspect destination directory")
        }
        guard information.st_mode & S_IFMT == S_IFDIR else {
            throw MarkdownCopyError.fileSystem(
                operation: "unsafe destination directory",
                domain: NSPOSIXErrorDomain,
                code: Int(ENOTDIR)
            )
        }
        return "\(information.st_dev):\(information.st_ino)"
    }

    private func loadRecord() throws -> Bookkeeping? {
        switch try inspect(metadataURL, contents: .data) {
        case .absent:
            return nil
        case .unsafe:
            throw MarkdownCopyError.invalidBookkeeping
        case let .regular(file):
            guard let data = file.data else {
                throw MarkdownCopyError.invalidBookkeeping
            }
            do {
                let record = try JSONDecoder().decode(
                    Bookkeeping.self,
                    from: data
                )
                guard record.version == Self.bookkeepingVersion else {
                    throw MarkdownCopyError.unsupportedBookkeepingVersion
                }
                return record
            } catch let error as MarkdownCopyError {
                throw error
            } catch {
                throw MarkdownCopyError.invalidBookkeeping
            }
        }
    }

    private func store(_ record: Bookkeeping) throws {
        do {
            try FileManager.default.createDirectory(
                at: metadataDirectory,
                withIntermediateDirectories: true
            )
        } catch let error as NSError {
            throw fileSystemError(
                operation: "create bookkeeping directory",
                error: error
            )
        }
        let temporary = metadataDirectory.appendingPathComponent(
            ".markdown-copy-state-\(UUID().uuidString).tmp"
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeAndSync(try encoder.encode(record), to: temporary)
        try renameReplacing(temporary, with: metadataURL)
        try syncDirectory(metadataDirectory)
    }

    private func isValidStageName(_ name: String) -> Bool {
        name.hasPrefix(Self.stagePrefix)
            && name.hasSuffix(".tmp")
            && !name.contains("/")
    }

    private func recordStageIdentity(
        _ stageURL: URL,
        in record: inout Bookkeeping
    ) throws {
        guard case let .regular(stage) = try inspect(stageURL),
              var pending = record.pending else {
            throw MarkdownCopyError.invalidBookkeeping
        }
        pending.stagedIdentity = stage.identity
        record.pending = pending
        try store(record)
    }

    private func removeStageIfPresent(_ url: URL) throws {
        switch try inspect(url) {
        case .absent:
            return
        case .regular:
            try removeManagedStage(url)
        case .unsafe:
            throw MarkdownCopyError.invalidBookkeeping
        }
    }

    private func removeManagedStage(_ url: URL) throws {
        guard isValidStageName(url.lastPathComponent) else {
            throw MarkdownCopyError.invalidBookkeeping
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as NSError where error.code == NSFileNoSuchFileError {
            return
        } catch let error as NSError {
            throw fileSystemError(operation: "remove staged file", error: error)
        }
    }

    private func coordinateWriting<T>(
        _ url: URL,
        operation: (URL) throws -> T
    ) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        coordinator.coordinate(
            writingItemAt: url,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            result = Result { try operation(coordinatedURL) }
        }
        if let result { return try result.get() }
        if let coordinationError {
            throw fileSystemError(
                operation: "coordinate copy",
                error: coordinationError
            )
        }
        throw MarkdownCopyError.fileSystem(
            operation: "coordinate copy",
            domain: NSCocoaErrorDomain,
            code: NSFileWriteUnknownError
        )
    }

    fileprivate static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func writeAndSync(_ data: Data, to url: URL) throws {
        let mode = S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH
        let descriptor = open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode
        )
        guard descriptor >= 0 else {
            throw posixError(operation: "create staged file")
        }
        defer { close(descriptor) }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    base.advanced(by: written),
                    bytes.count - written
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else {
                    throw posixError(operation: "write staged file")
                }
                written += result
            }
        }
        guard fsync(descriptor) == 0 else {
            throw posixError(operation: "sync staged file")
        }
    }

    private func renameExclusive(_ source: URL, to destination: URL) throws {
        let status = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
            }
        }
        guard status == 0 else {
            throw posixError(operation: "create Markdown copy")
        }
    }

    private func renameReplacing(_ source: URL, with destination: URL) throws {
        let status = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                rename(sourcePath, destinationPath)
            }
        }
        guard status == 0 else {
            throw posixError(operation: "replace file")
        }
    }

    private func syncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw posixError(operation: "open directory for sync")
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw posixError(operation: "sync directory")
        }
    }

    private func posixError(operation: String) -> MarkdownCopyError {
        .fileSystem(
            operation: operation,
            domain: NSPOSIXErrorDomain,
            code: Int(errno)
        )
    }

    private func fileSystemError(
        operation: String,
        error: NSError
    ) -> MarkdownCopyError {
        .fileSystem(
            operation: operation,
            domain: error.domain,
            code: error.code
        )
    }
}

private struct Bookkeeping: Codable {
    let version: Int
    let noteID: UUID
    let destinationIdentity: String
    var last: Materialization?
    var pending: PendingAttempt?

    init(
        version: Int,
        noteID: UUID,
        destinationIdentity: String,
        last: Materialization? = nil,
        pending: PendingAttempt? = nil
    ) {
        self.version = version
        self.noteID = noteID
        self.destinationIdentity = destinationIdentity
        self.last = last
        self.pending = pending
    }
}

private struct Materialization: Codable {
    let fingerprint: String
    let heads: [String]

    init(_ snapshot: MarkdownCopySnapshot) {
        fingerprint = MarkdownCopyWriter.fingerprint(snapshot.utf8)
        heads = snapshot.heads.sorted()
    }

    init(_ pending: PendingAttempt) {
        fingerprint = pending.fingerprint
        heads = pending.heads
    }
}

private struct PendingAttempt: Codable {
    let fingerprint: String
    let heads: [String]
    let stageName: String
    var stagedIdentity: String?

    init(_ snapshot: MarkdownCopySnapshot, stageName: String) {
        fingerprint = MarkdownCopyWriter.fingerprint(snapshot.utf8)
        heads = snapshot.heads.sorted()
        self.stageName = stageName
        stagedIdentity = nil
    }
}
