import Darwin
import Foundation
import Observation

public enum MarkdownCopyControllerError: Error, Equatable, LocalizedError {
    case busy
    case destinationIsNotDirectory
    case destinationIsNotLocal
    case destinationIsInICloudDrive

    public var errorDescription: String? {
        switch self {
        case .busy:
            "Wait for the current Markdown copy operation to finish."
        case .destinationIsNotDirectory:
            "Choose a folder for the Markdown copy."
        case .destinationIsNotLocal:
            "Choose a folder on this Mac's local storage."
        case .destinationIsInICloudDrive:
            "Choose a local folder outside iCloud Drive."
        }
    }
}

@MainActor
@Observable
public final class MarkdownCopyController {
    public enum Status: Equatable {
        case starting
        case notConfigured
        case idle
        case updating
        case current
        case paused(MarkdownCopyPause)
        case reconnectRequired(message: String)
        case failed(message: String)
    }

    public private(set) var status: Status = .starting
    public private(set) var destinationURL: URL?

    public var isBusy: Bool {
        switch status {
        case .starting, .updating:
            true
        case .notConfigured, .idle, .current, .paused,
             .reconnectRequired, .failed:
            false
        }
    }

    public var helpMessage: String {
        switch status {
        case .starting:
            "Preparing the Markdown copy."
        case .notConfigured:
            "Choose a local folder for the portable Markdown copy."
        case .idle:
            "The Markdown copy will update after the note is saved."
        case .updating:
            "Updating the portable Markdown copy."
        case .current:
            "The portable Markdown copy is up to date."
        case let .paused(reason):
            Self.message(for: reason)
        case let .reconnectRequired(message), let .failed(message):
            message
        }
    }

    @ObservationIgnored private let applicationSupportDirectory: URL
    @ObservationIgnored private let documentsDirectory: URL
    @ObservationIgnored private let usesSecurityScopedBookmarks: Bool
    @ObservationIgnored private let beforeOperation: (() async -> Void)?
    @ObservationIgnored private let operationStatusChanged: ((Status) -> Void)?
    @ObservationIgnored private var configuration: Configuration?
    @ObservationIgnored private var writer: MarkdownCopyWriter?
    @ObservationIgnored private var latestSnapshot: NoteSnapshot?
    @ObservationIgnored private var pendingOperation: Operation?
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    public init(
        applicationSupportDirectory: URL = .applicationSupportDirectory
            .appending(path: "Notes/MarkdownCopy", directoryHint: .isDirectory),
        documentsDirectory: URL = .documentsDirectory
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.documentsDirectory = documentsDirectory
        usesSecurityScopedBookmarks = true
        beforeOperation = nil
        operationStatusChanged = nil
    }

    init(
        applicationSupportDirectory: URL,
        documentsDirectory: URL,
        usesSecurityScopedBookmarks: Bool,
        beforeOperation: (() async -> Void)? = nil,
        operationStatusChanged: ((Status) -> Void)? = nil
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.documentsDirectory = documentsDirectory
        self.usesSecurityScopedBookmarks = usesSecurityScopedBookmarks
        self.beforeOperation = beforeOperation
        self.operationStatusChanged = operationStatusChanged
    }

    public func start() async {
        guard !started else { return }
        started = true
        status = .starting

        do {
            if let configuration = try loadConfiguration() {
                self.configuration = configuration
                try install(configuration)
            } else {
#if os(macOS)
                status = .notConfigured
#else
                try configure(destination: documentsDirectory)
#endif
            }
        } catch {
            writer = nil
            destinationURL = nil
            status = .reconnectRequired(message: Self.message(for: error))
        }

        if writer != nil, latestSnapshot != nil {
            enqueue(.reconcile)
        }
    }

    public func submit(_ snapshot: NoteSnapshot?) {
        guard let snapshot else { return }
        latestSnapshot = snapshot
        guard started, writer != nil else { return }
        enqueue(.publish)
    }

    public func retry() {
        guard !isBusy else { return }
        guard writer != nil else {
            status = .starting
            started = false
            Task { [weak self] in await self?.start() }
            return
        }
        guard latestSnapshot != nil else { return }
        enqueue(.publish)
    }

    public func reconcileOnActivation() {
        guard latestSnapshot != nil else { return }
        guard writer != nil else {
            guard configuration != nil, !isBusy else { return }
            status = .starting
            started = false
            Task { [weak self] in await self?.start() }
            return
        }
        enqueue(.reconcile)
    }

    public func chooseDirectory(_ url: URL) async throws {
        guard !isBusy else { throw MarkdownCopyControllerError.busy }
#if os(macOS)
        let accessed = usesSecurityScopedBookmarks
            && url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
#endif
        try validateDestination(url)
        do {
            try configure(destination: url)
        } catch {
            writer = nil
            destinationURL = nil
            status = .reconnectRequired(message: Self.message(for: error))
            throw error
        }
        if latestSnapshot != nil { enqueue(.reconcile) }
    }

    public func createNewCopy() async throws {
        guard !isBusy else { throw MarkdownCopyControllerError.busy }
#if os(macOS)
        configuration = nil
        writer = nil
        destinationURL = nil
        status = .notConfigured
#else
        let directory = documentsDirectory.appending(
            path: "meh-copy-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try configure(destination: directory)
        if latestSnapshot != nil { enqueue(.reconcile) }
#endif
    }

    func waitForPendingWork() async {
        while let task = operationTask { await task.value }
    }

    private func enqueue(_ operation: Operation) {
        pendingOperation = pendingOperation == .publish ? .publish : operation
        guard operationTask == nil else { return }
        operationTask = Task { [weak self] in
            await self?.runOperations()
        }
    }

    private func runOperations() async {
        while let operation = pendingOperation,
              let snapshot = latestSnapshot,
              let configuration {
            pendingOperation = nil
            status = .updating
            if let beforeOperation { await beforeOperation() }
            do {
                let copy = try MarkdownCopySnapshot(persisted: snapshot)
                let report = try await withDestinationAccess(
                    configuration: configuration
                ) { resolved in
                    let writer = MarkdownCopyWriter(
                        destinationDirectory: resolved,
                        metadataDirectory: metadataDirectory(
                            for: configuration.destinationUUID
                        )
                    )
                    self.writer = writer
                    self.destinationURL = writer.copyURL
                    switch operation {
                    case .publish:
                        return try await writer.publish(copy)
                    case .reconcile:
                        let report = try await writer.reconcile(with: copy)
                        switch report {
                        case .needsMaterialization:
                            return try await writer.publish(copy)
                        case let .current(heads) where heads != copy.heads:
                            return try await writer.publish(copy)
                        case .current, .paused:
                            return report
                        }
                    }
                }
                guard self.configuration?.destinationUUID
                        == configuration.destinationUUID else { continue }
                let hasNewerWork = pendingOperation != nil
                    || latestSnapshot != snapshot
                switch report {
                case .needsMaterialization:
                    status = .idle
                case .current:
                    status = hasNewerWork ? .updating : .current
                case let .paused(reason):
                    status = .paused(reason)
                }
                operationStatusChanged?(status)
            } catch {
                guard self.configuration?.destinationUUID
                        == configuration.destinationUUID else { continue }
                if let error = error as? MarkdownCopyControllerError,
                   error == .destinationIsNotLocal
                    || error == .destinationIsInICloudDrive {
                    status = .paused(.unsafeDestination)
                } else if let error = error as? ConfigurationError,
                          error == .destinationReplaced {
                    status = .paused(.destinationReplaced)
                } else {
                    status = .failed(message: Self.message(for: error))
                }
            }
        }
        operationTask = nil
    }

    private func configure(destination: URL) throws {
        let resolved = destination.standardizedFileURL.resolvingSymlinksInPath()
        try validateDestination(resolved)
        let identity = try FileIdentity(url: resolved)
        let destinationUUID: UUID
        if configuration?.identity == identity {
            destinationUUID = configuration?.destinationUUID ?? UUID()
        } else {
            destinationUUID = UUID()
        }

#if os(macOS)
        let bookmark = try resolved.bookmarkData(
            options: usesSecurityScopedBookmarks ? .withSecurityScope : [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
#else
        let bookmark: Data? = nil
#endif
        let configuration = Configuration(
            destinationUUID: destinationUUID,
            bookmark: bookmark,
            relativeDocumentsPath: relativeDocumentsPath(for: resolved),
            identity: identity
        )
        try persist(configuration)
        self.configuration = configuration
        try install(configuration, resolvedURL: resolved)
    }

    private func install(
        _ configuration: Configuration,
        resolvedURL suppliedURL: URL? = nil
    ) throws {
        let resolved: URL
#if os(macOS)
        if let suppliedURL {
            resolved = suppliedURL
        } else {
            guard let bookmark = configuration.bookmark else {
                throw ConfigurationError.invalid
            }
            var stale = false
            resolved = try URL(
                resolvingBookmarkData: bookmark,
                options: usesSecurityScopedBookmarks
                    ? [.withSecurityScope, .withoutUI] : [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ).standardizedFileURL.resolvingSymlinksInPath()
            let accessed = usesSecurityScopedBookmarks
                && resolved.startAccessingSecurityScopedResource()
            defer {
                if accessed { resolved.stopAccessingSecurityScopedResource() }
            }
            try validateDestination(resolved)
            guard try FileIdentity(url: resolved) == configuration.identity else {
                throw ConfigurationError.destinationReplaced
            }
            if stale {
                var updated = configuration
                updated.bookmark = try resolved.bookmarkData(
                    options: usesSecurityScopedBookmarks
                        ? .withSecurityScope : [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                try persist(updated)
                return try install(updated, resolvedURL: resolved)
            }
        }
#else
        guard let relativePath = configuration.relativeDocumentsPath else {
            throw ConfigurationError.invalid
        }
        resolved = documentsDirectory.appending(
            path: relativePath,
            directoryHint: .isDirectory
        ).standardizedFileURL.resolvingSymlinksInPath()
        try validateDestination(resolved)
        guard try FileIdentity(url: resolved) == configuration.identity else {
            throw ConfigurationError.destinationReplaced
        }
#endif
        let metadata = metadataDirectory(for: configuration.destinationUUID)
        try makePrivateDirectory(metadata)
        self.configuration = configuration
        writer = MarkdownCopyWriter(
            destinationDirectory: resolved,
            metadataDirectory: metadata
        )
        destinationURL = resolved.appending(path: "note.md")
        status = .idle
    }

    private func withDestinationAccess<T: Sendable>(
        configuration: Configuration,
        operation: (URL) async throws -> T
    ) async throws -> T {
#if os(macOS)
        guard let bookmark = configuration.bookmark else {
            throw ConfigurationError.invalid
        }
        var stale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: usesSecurityScopedBookmarks
                ? [.withSecurityScope, .withoutUI] : [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let accessed = usesSecurityScopedBookmarks
            && resolved.startAccessingSecurityScopedResource()
        defer {
            if accessed { resolved.stopAccessingSecurityScopedResource() }
        }
        try validateDestination(resolved)
        guard try FileIdentity(url: resolved) == configuration.identity else {
            throw ConfigurationError.destinationReplaced
        }
        if stale {
            var updated = configuration
            updated.bookmark = try resolved.bookmarkData(
                options: usesSecurityScopedBookmarks ? .withSecurityScope : [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            try persist(updated)
            self.configuration = updated
        }
#else
        let relativePath = configuration.relativeDocumentsPath ?? ""
        let resolved = documentsDirectory.appending(
            path: relativePath,
            directoryHint: .isDirectory
        ).standardizedFileURL.resolvingSymlinksInPath()
        try validateDestination(resolved)
        guard try FileIdentity(url: resolved) == configuration.identity else {
            throw ConfigurationError.destinationReplaced
        }
#endif
        return try await operation(resolved)
    }

    private func validateDestination(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isUbiquitousItemKey,
            .volumeIsLocalKey,
        ])
        guard values.isDirectory == true else {
            throw MarkdownCopyControllerError.destinationIsNotDirectory
        }
#if os(macOS)
        guard values.volumeIsLocal == true else {
            throw MarkdownCopyControllerError.destinationIsNotLocal
        }
        let resolvedComponents = url.resolvingSymlinksInPath().pathComponents
        guard values.isUbiquitousItem != true,
              !resolvedComponents.contains(where: {
                  $0.localizedCaseInsensitiveCompare("Mobile Documents")
                      == .orderedSame
              }) else {
            throw MarkdownCopyControllerError.destinationIsInICloudDrive
        }
#endif
    }

    private func relativeDocumentsPath(for destination: URL) -> String? {
#if os(macOS)
        nil
#else
        let base = documentsDirectory.standardizedFileURL.path
        let path = destination.standardizedFileURL.path
        guard path == base || path.hasPrefix(base + "/") else { return nil }
        return path == base ? "" : String(path.dropFirst(base.count + 1))
#endif
    }

    private func loadConfiguration() throws -> Configuration? {
        let url = configurationURL
        var information = stat()
        let lookup = url.withUnsafeFileSystemRepresentation { path in
            lstat(path, &information)
        }
        guard lookup == 0 else {
            if errno == ENOENT { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        do {
            let data = try Data(contentsOf: url)
            let configuration = try JSONDecoder().decode(
                Configuration.self,
                from: data
            )
            guard configuration.version == 1 else {
                throw ConfigurationError.invalid
            }
            return configuration
        } catch {
            throw ConfigurationError.invalid
        }
    }

    private func persist(_ configuration: Configuration) throws {
        try makePrivateDirectory(applicationSupportDirectory)
        let data = try JSONEncoder().encode(configuration)
        try data.write(to: configurationURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configurationURL.path
        )
    }

    private func makePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    private var configurationURL: URL {
        applicationSupportDirectory.appending(path: "configuration.json")
    }

    private func metadataDirectory(for id: UUID) -> URL {
        applicationSupportDirectory
            .appending(path: "Destinations", directoryHint: .isDirectory)
            .appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }

    private static func message(for pause: MarkdownCopyPause) -> String {
        switch pause {
        case .preexistingFile:
            "A file already exists at this destination. Choose another folder."
        case .unsafeDestination:
            "The Markdown copy destination is unsafe. Choose another folder."
        case .destinationReplaced:
            "The selected folder changed. Reconnect the destination."
        }
    }
}

private extension MarkdownCopyController {
    enum Operation: Equatable {
        case publish
        case reconcile
    }

    enum ConfigurationError: Error, Equatable, LocalizedError {
        case invalid
        case destinationReplaced

        var errorDescription: String? {
            switch self {
            case .invalid:
                "The saved Markdown copy destination is invalid. Reconnect it."
            case .destinationReplaced:
                "The saved folder was replaced. Reconnect the destination."
            }
        }
    }

    struct Configuration: Codable {
        var version = 1
        let destinationUUID: UUID
        var bookmark: Data?
        let relativeDocumentsPath: String?
        let identity: FileIdentity
    }

    struct FileIdentity: Codable, Equatable {
        let device: UInt64
        let inode: UInt64

        init(url: URL) throws {
            var information = stat()
            let result = url.withUnsafeFileSystemRepresentation { path in
                lstat(path, &information)
            }
            guard result == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            device = UInt64(information.st_dev)
            inode = UInt64(information.st_ino)
        }
    }
}
