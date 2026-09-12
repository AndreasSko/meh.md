import Darwin
import Foundation

public enum FileWriteStage: String, CaseIterable, Sendable {
    case tempSynced
    case previousReplaced
    case currentReplaced
    case directorySynced
}

public enum RecoveryFailure: Equatable, Sendable {
    case corrupt
    case unreadable
    case unsupportedSchemaVersion
}

public enum RecoveryOutcome: Equatable, Sendable {
    case absent
    case incompatibleCurrent
    case current(Data)
    case previous(Data, currentFailure: RecoveryFailure?)
    case unrecoverable(
        current: RecoveryFailure?,
        previous: RecoveryFailure?
    )
}

public enum KnownGoodFileStoreError: Error, Equatable {
    case invalidIncomingDocument
    case invalidCurrentDocument
    case noteIdentityMismatch
    case disconnectedHistory
}

public struct KnownGoodFileStore: Sendable {
    public let currentURL: URL
    public let previousURL: URL

    public init(directory: URL) {
        currentURL = directory.appendingPathComponent("note.automerge")
        previousURL = directory.appendingPathComponent(
            "note.previous.automerge"
        )
    }

    public func write(
        _ data: Data,
        afterStage: (FileWriteStage) throws -> Void = { _ in }
    ) throws {
        guard let incomingNote = try? SpikeNoteDocument(
            serializedData: data
        ) else {
            throw KnownGoodFileStoreError.invalidIncomingDocument
        }

        let fileManager = FileManager.default
        let directory = currentURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let tempURL = temporaryURL(in: directory, prefix: "current")
        let previousTempURL = temporaryURL(
            in: directory,
            prefix: "previous"
        )
        defer {
            try? fileManager.removeItem(at: tempURL)
            try? fileManager.removeItem(at: previousTempURL)
        }

        try Self.writeAndSync(data, to: tempURL)
        try afterStage(.tempSynced)

        if fileManager.fileExists(atPath: currentURL.path) {
            let currentData = try Data(contentsOf: currentURL)
            guard let currentNote = try? SpikeNoteDocument(
                serializedData: currentData
            ) else {
                throw KnownGoodFileStoreError.invalidCurrentDocument
            }
            guard currentNote.noteID == incomingNote.noteID else {
                throw KnownGoodFileStoreError.noteIdentityMismatch
            }
            guard currentNote.headsSnapshot.isSubset(
                of: incomingNote.historyHashes
            ) else {
                throw KnownGoodFileStoreError.disconnectedHistory
            }
            try Self.writeAndSync(currentData, to: previousTempURL)
            try Self.renameReplacing(previousTempURL, with: previousURL)
            try Self.syncDirectory(directory)
            try afterStage(.previousReplaced)
        }

        try Self.renameReplacing(tempURL, with: currentURL)
        try afterStage(.currentReplaced)

        try Self.syncDirectory(directory)
        try afterStage(.directorySynced)
    }

    public func recover() -> RecoveryOutcome {
        let current = recoveryCandidate(at: currentURL)
        switch current {
        case let .valid(data):
            return .current(data)
        case .absent:
            break
        case .unsupportedSchemaVersion:
            return .incompatibleCurrent
        case .corrupt, .unreadable:
            let previous = recoveryCandidate(at: previousURL)
            if case let .valid(data) = previous {
                return .previous(data, currentFailure: current.failure!)
            }
            return .unrecoverable(
                current: current.failure,
                previous: previous.failure
            )
        }

        let previous = recoveryCandidate(at: previousURL)
        switch previous {
        case let .valid(data):
            return .previous(data, currentFailure: nil)
        case .absent:
            return .absent
        case .corrupt, .unreadable, .unsupportedSchemaVersion:
            return .unrecoverable(current: nil, previous: previous.failure)
        }
    }

    public func quarantineCurrent() throws -> URL {
        let directory = currentURL.deletingLastPathComponent()
        let quarantineURL = directory.appendingPathComponent(
            "note.quarantine-\(UUID().uuidString).automerge"
        )
        try Self.renameReplacing(currentURL, with: quarantineURL)
        try Self.syncDirectory(directory)
        return quarantineURL
    }

    private enum RecoveryCandidate {
        case absent
        case valid(Data)
        case corrupt
        case unreadable
        case unsupportedSchemaVersion

        var failure: RecoveryFailure? {
            switch self {
            case .absent, .valid:
                nil
            case .corrupt:
                .corrupt
            case .unreadable:
                .unreadable
            case .unsupportedSchemaVersion:
                .unsupportedSchemaVersion
            }
        }
    }

    private func recoveryCandidate(at url: URL) -> RecoveryCandidate {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .absent
        }
        guard let data = try? Data(contentsOf: url) else {
            return .unreadable
        }
        do {
            _ = try SpikeNoteDocument(serializedData: data)
            return .valid(data)
        } catch SpikeNoteError.unsupportedSchemaVersion {
            return .unsupportedSchemaVersion
        } catch {
            return .corrupt
        }
    }

    private func temporaryURL(in directory: URL, prefix: String) -> URL {
        directory.appendingPathComponent(
            ".\(prefix)-\(UUID().uuidString).tmp"
        )
    }

    private static func writeAndSync(_ data: Data, to url: URL) throws {
        let descriptor = open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }

        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written
                )
                if result < 0, errno == EINTR {
                    continue
                }
                guard result > 0 else { throw posixError() }
                written += result
            }
        }

        guard fsync(descriptor) == 0 else { throw posixError() }
    }

    private static func renameReplacing(
        _ source: URL,
        with destination: URL
    ) throws {
        let result = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation {
                destinationPath in
                rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else { throw posixError() }
    }

    private static func syncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw posixError() }
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

}
