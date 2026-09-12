import Darwin
import Foundation

public enum NoteFileStorageError: Error, Equatable {
    case invalidIncomingDocument
    case invalidCurrentDocument
    case noteIdentityMismatch
    case disconnectedHistory
    case recoverySourceChanged
}

enum NoteFileWriteStage: CaseIterable {
    case temporarySynced
    case previousReplaced
    case currentReplaced
    case directorySynced
}

enum NoteRecoveryStage: Equatable {
    case sourceRetained
    case currentRestored
    case directorySynced
}

public actor NoteFileStorage: NoteStorage {
    public nonisolated let currentURL: URL
    public nonisolated let previousURL: URL

    public init(directory: URL) {
        currentURL = directory.appendingPathComponent("note.automerge")
        previousURL = directory.appendingPathComponent(
            "note.previous.automerge"
        )
    }

    public func load() -> NoteLoadResult {
        let current = candidate(at: currentURL)
        switch current {
        case let .valid(snapshot):
            return .current(snapshot)
        case .unsupportedSchemaVersion:
            return .blocked(
                NoteLoadFailure(
                    current: .unsupportedSchemaVersion,
                    previous: failure(at: previousURL)
                )
            )
        case .absent, .corrupt, .unreadable:
            break
        }

        let previous = candidate(at: previousURL)
        if case let .valid(snapshot) = previous {
            return .recoveryRequired(
                NoteRecovery(
                    previous: snapshot,
                    currentFailure: current.failure,
                    currentMarker: current.marker
                )
            )
        }
        if case .absent = current, case .absent = previous {
            return .firstLaunch
        }
        return .blocked(
            NoteLoadFailure(
                current: current.failure,
                previous: previous.failure
            )
        )
    }

    public func save(_ snapshot: NoteSnapshot) throws {
        try write(snapshot)
    }

    public func recover(_ recovery: NoteRecovery) throws -> NoteSnapshot {
        try recover(recovery, afterStage: { _ in })
    }

    func recover(
        _ recovery: NoteRecovery,
        afterStage: (NoteRecoveryStage) throws -> Void
    ) throws -> NoteSnapshot {
        let source = candidate(at: previousURL)
        guard case let .valid(previous) = source,
              previous == recovery.previous else {
            throw NoteFileStorageError.recoverySourceChanged
        }
        guard let expectedMarker = recovery.currentMarker else {
            throw NoteFileStorageError.recoverySourceChanged
        }

        let fileManager = FileManager.default
        let directory = currentURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let observedCurrent = candidate(at: currentURL)
        let retainedURL = quarantineURL(
            matching: expectedMarker,
            in: directory
        )
        let sourceAlreadyRetained: Bool
        if observedCurrent.marker == expectedMarker {
            sourceAlreadyRetained = retainedURL != nil
        } else if case let .valid(current) = observedCurrent,
                  current == previous,
                  retainedURL != nil || expectedMarker == .absent {
            try Self.syncDirectory(directory)
            return previous
        } else if case .absent = observedCurrent, retainedURL != nil {
            sourceAlreadyRetained = true
        } else {
            throw NoteFileStorageError.recoverySourceChanged
        }

        let temporary = temporaryURL(in: directory, prefix: "recovery")
        defer { try? fileManager.removeItem(at: temporary) }
        try Self.writeAndSync(previous.data, to: temporary)

        if expectedMarker != .absent, !sourceAlreadyRetained {
            let quarantineURL = directory.appendingPathComponent(
                "note.quarantine-\(UUID().uuidString).automerge"
            )
            switch expectedMarker {
            case let .bytes(data):
                try Self.writeAndSync(data, to: quarantineURL)
            case .unreadable:
                try Self.renameReplacing(currentURL, with: quarantineURL)
            case .absent:
                break
            }
            try Self.syncDirectory(directory)
            try afterStage(.sourceRetained)
        }

        try Self.renameReplacing(temporary, with: currentURL)
        try afterStage(.currentRestored)
        try Self.syncDirectory(directory)
        try afterStage(.directorySynced)
        return previous
    }

    private func quarantineURL(
        matching marker: NoteFileMarker,
        in directory: URL
    ) -> URL? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return nil }
        return urls.first { url in
            url.lastPathComponent.hasPrefix("note.quarantine-")
                && candidate(at: url).marker == marker
        }
    }

    func write(
        _ snapshot: NoteSnapshot,
        afterStage: (NoteFileWriteStage) throws -> Void = { _ in }
    ) throws {
        let incoming: NoteDocument
        do {
            incoming = try NoteDocument(snapshot: snapshot)
        } catch {
            throw NoteFileStorageError.invalidIncomingDocument
        }

        let fileManager = FileManager.default
        let directory = currentURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let temporary = temporaryURL(in: directory, prefix: "current")
        let previousTemporary = temporaryURL(
            in: directory,
            prefix: "previous"
        )
        defer {
            try? fileManager.removeItem(at: temporary)
            try? fileManager.removeItem(at: previousTemporary)
        }

        try Self.writeAndSync(snapshot.data, to: temporary)
        try afterStage(.temporarySynced)

        switch candidate(at: currentURL) {
        case .absent:
            break
        case let .valid(currentSnapshot):
            let current = try NoteDocument(snapshot: currentSnapshot)
            guard current.noteID == incoming.noteID else {
                throw NoteFileStorageError.noteIdentityMismatch
            }
            guard current.heads.isSubset(of: incoming.historyHeads) else {
                throw NoteFileStorageError.disconnectedHistory
            }
            try Self.writeAndSync(
                currentSnapshot.data,
                to: previousTemporary
            )
            try Self.renameReplacing(previousTemporary, with: previousURL)
            try Self.syncDirectory(directory)
            try afterStage(.previousReplaced)
        case .corrupt, .unreadable, .unsupportedSchemaVersion:
            throw NoteFileStorageError.invalidCurrentDocument
        }

        try Self.renameReplacing(temporary, with: currentURL)
        try afterStage(.currentReplaced)
        try Self.syncDirectory(directory)
        try afterStage(.directorySynced)
    }

    private enum Candidate {
        case absent
        case valid(NoteSnapshot)
        case corrupt(Data)
        case unreadable(String)
        case unsupportedSchemaVersion(Data)

        var failure: NoteFileFailure {
            switch self {
            case .absent:
                .absent
            case .valid:
                preconditionFailure("A valid file has no failure")
            case .corrupt:
                .corrupt
            case .unreadable:
                .unreadable
            case .unsupportedSchemaVersion:
                .unsupportedSchemaVersion
            }
        }

        var marker: NoteFileMarker {
            switch self {
            case .absent:
                .absent
            case let .valid(snapshot):
                .bytes(snapshot.data)
            case let .corrupt(data),
                 let .unsupportedSchemaVersion(data):
                .bytes(data)
            case let .unreadable(identity):
                .unreadable(identity)
            }
        }
    }

    private func candidate(at url: URL) -> Candidate {
        var information = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            lstat(path, &information)
        }
        guard status == 0 else {
            if errno == ENOENT { return .absent }
            return .unreadable("lookup:\(errno)")
        }
        guard let data = try? Data(contentsOf: url) else {
            return .unreadable(Self.identity(for: information))
        }
        do {
            let document = try NoteDocument(serializedData: data)
            return .valid(
                NoteSnapshot(
                    data: data,
                    heads: document.heads,
                    noteID: document.noteID
                )
            )
        } catch NoteDocumentError.unsupportedSchemaVersion {
            return .unsupportedSchemaVersion(data)
        } catch {
            return .corrupt(data)
        }
    }

    private func failure(at url: URL) -> NoteFileFailure {
        let result = candidate(at: url)
        if case .valid = result {
            return .valid
        }
        return result.failure
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

    private static func identity(for information: stat) -> String {
        [
            String(information.st_dev),
            String(information.st_ino),
            String(information.st_mode),
            String(information.st_size),
            String(information.st_mtimespec.tv_sec),
            String(information.st_mtimespec.tv_nsec),
        ].joined(separator: ":")
    }
}
