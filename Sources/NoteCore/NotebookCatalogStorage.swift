import Darwin
import Foundation

public enum NotebookCatalogStorageError: Error, Equatable {
    case invalidIncomingDocument
    case invalidCurrentDocument
    case notebookIdentityMismatch
    case disconnectedHistory
    case recoverySourceChanged
}

public enum NotebookCatalogFileFailure: Equatable, Sendable {
    case valid
    case absent
    case corrupt
    case unreadable
    case unsupportedSchemaVersion
}

public struct NotebookCatalogRecovery: Equatable, Sendable {
    public let previous: NotebookCatalogSnapshot
    public let currentFailure: NotebookCatalogFileFailure
    let currentMarker: NotebookCatalogFileMarker?

    public init(
        previous: NotebookCatalogSnapshot,
        currentFailure: NotebookCatalogFileFailure
    ) {
        self.previous = previous
        self.currentFailure = currentFailure
        currentMarker = nil
    }

    init(
        previous: NotebookCatalogSnapshot,
        currentFailure: NotebookCatalogFileFailure,
        currentMarker: NotebookCatalogFileMarker
    ) {
        self.previous = previous
        self.currentFailure = currentFailure
        self.currentMarker = currentMarker
    }
}

public struct NotebookCatalogLoadFailure: Equatable, Sendable {
    public let current: NotebookCatalogFileFailure
    public let previous: NotebookCatalogFileFailure

    public init(
        current: NotebookCatalogFileFailure,
        previous: NotebookCatalogFileFailure
    ) {
        self.current = current
        self.previous = previous
    }
}

public enum NotebookCatalogLoadResult: Equatable, Sendable {
    case firstLaunch
    case current(NotebookCatalogSnapshot)
    case recoveryRequired(NotebookCatalogRecovery)
    case blocked(NotebookCatalogLoadFailure)
}

enum NotebookCatalogFileMarker: Equatable, Sendable {
    case absent
    case bytes(Data)
    case unreadable(String)
}

enum NotebookCatalogWriteStage: CaseIterable {
    case temporarySynced
    case previousReplaced
    case currentReplaced
    case directorySynced
}

enum NotebookCatalogRecoveryStage: CaseIterable, Equatable {
    case sourceRetained
    case currentRestored
    case directorySynced
}

public actor NotebookCatalogStorage {
    public nonisolated let currentURL: URL
    public nonisolated let previousURL: URL

    public init(directory: URL) {
        currentURL = directory.appendingPathComponent("catalog.automerge")
        previousURL = directory.appendingPathComponent(
            "catalog.previous.automerge"
        )
    }

    public func load() -> NotebookCatalogLoadResult {
        let current = candidate(at: currentURL)
        switch current {
        case .valid(let snapshot):
            return .current(snapshot)
        case .unsupportedSchemaVersion:
            return .blocked(
                NotebookCatalogLoadFailure(
                    current: .unsupportedSchemaVersion,
                    previous: failure(at: previousURL)
                )
            )
        case .absent, .corrupt, .unreadable:
            break
        }

        let previous = candidate(at: previousURL)
        if case .valid(let snapshot) = previous {
            return .recoveryRequired(
                NotebookCatalogRecovery(
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
            NotebookCatalogLoadFailure(
                current: current.failure,
                previous: previous.failure
            )
        )
    }

    public func save(_ snapshot: NotebookCatalogSnapshot) throws {
        try write(snapshot)
    }

    public func recover(
        _ recovery: NotebookCatalogRecovery
    ) throws -> NotebookCatalogSnapshot {
        try recover(recovery, afterStage: { _ in })
    }

    func recover(
        _ recovery: NotebookCatalogRecovery,
        afterStage: (NotebookCatalogRecoveryStage) throws -> Void
    ) throws -> NotebookCatalogSnapshot {
        let source = candidate(at: previousURL)
        guard case .valid(let previous) = source,
            previous == recovery.previous
        else {
            throw NotebookCatalogStorageError.recoverySourceChanged
        }
        guard let expectedMarker = recovery.currentMarker else {
            throw NotebookCatalogStorageError.recoverySourceChanged
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
        } else if case .valid(let current) = observedCurrent,
            current == previous,
            retainedURL != nil || expectedMarker == .absent
        {
            try DurableFileIO.syncDirectory(directory)
            return previous
        } else if case .absent = observedCurrent, retainedURL != nil {
            sourceAlreadyRetained = true
        } else {
            throw NotebookCatalogStorageError.recoverySourceChanged
        }

        let temporary = temporaryURL(in: directory, prefix: "recovery")
        defer { try? fileManager.removeItem(at: temporary) }
        try DurableFileIO.writeAndSync(previous.data, to: temporary)

        if expectedMarker != .absent, !sourceAlreadyRetained {
            let quarantineURL = directory.appendingPathComponent(
                "catalog.quarantine-\(UUID().uuidString).automerge"
            )
            switch expectedMarker {
            case .bytes(let data):
                try DurableFileIO.writeAndSync(data, to: quarantineURL)
            case .unreadable:
                try DurableFileIO.renameReplacing(
                    currentURL,
                    with: quarantineURL
                )
            case .absent:
                break
            }
            try DurableFileIO.syncDirectory(directory)
            try afterStage(.sourceRetained)
        }

        try DurableFileIO.renameReplacing(temporary, with: currentURL)
        try afterStage(.currentRestored)
        try DurableFileIO.syncDirectory(directory)
        try afterStage(.directorySynced)
        return previous
    }

    func write(
        _ snapshot: NotebookCatalogSnapshot,
        afterStage: (NotebookCatalogWriteStage) throws -> Void = { _ in }
    ) throws {
        let incoming: NotebookCatalogDocument
        do {
            incoming = try NotebookCatalogDocument(snapshot: snapshot)
        } catch {
            throw NotebookCatalogStorageError.invalidIncomingDocument
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

        try DurableFileIO.writeAndSync(snapshot.data, to: temporary)
        try afterStage(.temporarySynced)

        switch candidate(at: currentURL) {
        case .absent:
            break
        case .valid(let currentSnapshot):
            let current = try NotebookCatalogDocument(
                snapshot: currentSnapshot
            )
            guard current.notebookID == incoming.notebookID else {
                throw NotebookCatalogStorageError.notebookIdentityMismatch
            }
            guard current.heads.isSubset(of: incoming.historyHeads) else {
                throw NotebookCatalogStorageError.disconnectedHistory
            }
            try DurableFileIO.writeAndSync(
                currentSnapshot.data,
                to: previousTemporary
            )
            try DurableFileIO.renameReplacing(
                previousTemporary,
                with: previousURL
            )
            try DurableFileIO.syncDirectory(directory)
            try afterStage(.previousReplaced)
        case .corrupt, .unreadable, .unsupportedSchemaVersion:
            throw NotebookCatalogStorageError.invalidCurrentDocument
        }

        try DurableFileIO.renameReplacing(temporary, with: currentURL)
        try afterStage(.currentReplaced)
        try DurableFileIO.syncDirectory(directory)
        try afterStage(.directorySynced)
    }

    private enum Candidate {
        case absent
        case valid(NotebookCatalogSnapshot)
        case corrupt(Data)
        case unreadable(String)
        case unsupportedSchemaVersion(Data)

        var failure: NotebookCatalogFileFailure {
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

        var marker: NotebookCatalogFileMarker {
            switch self {
            case .absent:
                .absent
            case .valid(let snapshot):
                .bytes(snapshot.data)
            case .corrupt(let data),
                .unsupportedSchemaVersion(let data):
                .bytes(data)
            case .unreadable(let identity):
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
            let document = try NotebookCatalogDocument(
                serializedData: data
            )
            return .valid(
                NotebookCatalogSnapshot(
                    data: data,
                    heads: document.heads,
                    notebookID: document.notebookID
                )
            )
        } catch NotebookCatalogError.unsupportedSchemaVersion {
            return .unsupportedSchemaVersion(data)
        } catch {
            return .corrupt(data)
        }
    }

    private func failure(at url: URL) -> NotebookCatalogFileFailure {
        let result = candidate(at: url)
        if case .valid = result {
            return .valid
        }
        return result.failure
    }

    private func quarantineURL(
        matching marker: NotebookCatalogFileMarker,
        in directory: URL
    ) -> URL? {
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
        else { return nil }
        return urls.first { url in
            url.lastPathComponent.hasPrefix("catalog.quarantine-")
                && candidate(at: url).marker == marker
        }
    }

    private func temporaryURL(in directory: URL, prefix: String) -> URL {
        directory.appendingPathComponent(
            ".catalog-\(prefix)-\(UUID().uuidString).tmp"
        )
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
