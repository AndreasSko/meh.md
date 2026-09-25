import Darwin
import Foundation

public struct NotebookMarkdownBackup: Equatable, Sendable {
    public let url: URL
    public let createdAt: Date
    public let noteCount: Int
    public let notebookID: UUID
}

public enum NotebookMarkdownBackupError: Error, Equatable, LocalizedError {
    case invalidRetentionCount
    case invalidCatalog
    case reservedName
    case verificationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidRetentionCount:
            "Keep at least one backup."
        case .invalidCatalog:
            "The saved notebook catalog changed while preparing the backup."
        case .reservedName:
            "A notebook item uses a name reserved for backup metadata."
        case .verificationFailed:
            "The backup files did not match the saved notes."
        }
    }
}

/// Publishes complete, browsable Markdown snapshots under an app-managed root.
/// The caller supplies persisted catalog and note snapshots from one saved state.
public actor NotebookMarkdownBackupStore {
    public nonisolated let directory: URL

    private static let markerName = ".meh-markdown-backup.json"
    private static let stagePrefix = ".meh-backup-stage-"
    private static let backupPrefix = "Backup-"
    private let fileManager = FileManager.default

    public init(directory: URL) {
        self.directory = directory
    }

    public func createBackup(
        catalog: NotebookCatalogSnapshot,
        placements: [NotebookPlacement],
        notes: [NoteSnapshot],
        retentionCount: Int
    ) throws -> NotebookMarkdownBackup {
        try createBackup(
            catalog: catalog,
            placements: placements,
            notes: notes,
            retentionCount: retentionCount,
            createdAt: Date()
        )
    }

    func createBackup(
        catalog: NotebookCatalogSnapshot,
        placements: [NotebookPlacement],
        notes: [NoteSnapshot],
        retentionCount: Int,
        createdAt: Date
    ) throws -> NotebookMarkdownBackup {
        guard retentionCount > 0 else {
            throw NotebookMarkdownBackupError.invalidRetentionCount
        }
        let document: NotebookCatalogDocument
        do {
            document = try NotebookCatalogDocument(snapshot: catalog)
            guard try document.placements() == placements else {
                throw NotebookMarkdownBackupError.invalidCatalog
            }
        } catch {
            throw NotebookMarkdownBackupError.invalidCatalog
        }

        let active = placements.filter { !$0.isInTrash }
        let selectedIDs = Set(active.map { $0.item.id })
        let wrapper = try NotebookMarkdownExport.makeWrapper(
            placements: placements,
            notes: notes,
            selectedIDs: selectedIDs
        )
        guard !(wrapper.fileWrappers ?? [:]).keys.contains(where: {
            NotebookName.collisionKey($0) == NotebookName.collisionKey(Self.markerName)
        }) else {
            throw NotebookMarkdownBackupError.reservedName
        }
        let noteCount = active.filter { $0.item.kind == .note }.count
        let identifier = UUID()
        let marker = BackupMarker(
            version: 1,
            id: identifier,
            notebookID: catalog.notebookID,
            createdAt: createdAt,
            noteCount: noteCount
        )
        let name = Self.backupPrefix + Self.timestamp(createdAt)
            + "-" + identifier.uuidString
        let stage = directory.appending(path: Self.stagePrefix + identifier.uuidString)
        let destination = directory.appending(path: name)

        try prepareRoot()
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: false)
        do {
            try Task.checkCancellation()
            try write(wrapper, at: stage)
            let markerData = try JSONEncoder().encode(marker)
            try DurableFileIO.writeAndSync(
                markerData,
                to: stage.appending(path: Self.markerName)
            )
            try verify(wrapper, at: stage, markerData: markerData)
            try DurableFileIO.syncDirectory(stage)
            try Task.checkCancellation()
            try rename(stage, to: destination)
            try DurableFileIO.syncDirectory(directory)
        } catch {
            try? fileManager.removeItem(at: stage)
            throw error
        }

        let backup = NotebookMarkdownBackup(
            url: destination,
            createdAt: createdAt,
            noteCount: noteCount,
            notebookID: catalog.notebookID
        )
        try Task.checkCancellation()
        try prune(notebookID: catalog.notebookID, keeping: retentionCount)
        return backup
    }

    /// Applies a changed limit without creating a new backup.
    public func enforceRetention(notebookID: UUID, keeping count: Int) throws {
        guard count > 0 else {
            throw NotebookMarkdownBackupError.invalidRetentionCount
        }
        try Task.checkCancellation()
        try prune(notebookID: notebookID, keeping: count)
    }

    public func listBackups() throws -> [NotebookMarkdownBackup] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ).compactMap { url in
            guard url.lastPathComponent.hasPrefix(Self.backupPrefix),
                  let values = try? url.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                  ),
                  values.isDirectory == true,
                  values.isSymbolicLink != true,
                  let markerValues = try? url.appending(path: Self.markerName)
                    .resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  markerValues.isRegularFile == true,
                  markerValues.isSymbolicLink != true,
                  let data = try? Data(contentsOf: url.appending(path: Self.markerName)),
                  let marker = try? JSONDecoder().decode(BackupMarker.self, from: data),
                  marker.version == 1,
                  url.lastPathComponent == Self.backupPrefix
                    + Self.timestamp(marker.createdAt)
                    + "-" + marker.id.uuidString
            else { return nil }
            return NotebookMarkdownBackup(
                url: directory.appending(path: url.lastPathComponent),
                createdAt: marker.createdAt,
                noteCount: marker.noteCount,
                notebookID: marker.notebookID
            )
        }.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.url.lastPathComponent > $1.url.lastPathComponent
        }
    }

    private func prune(notebookID: UUID, keeping count: Int) throws {
        let owned = try listBackups().filter { $0.notebookID == notebookID }
        for backup in owned.dropFirst(count) {
            try Task.checkCancellation()
            try fileManager.removeItem(at: backup.url)
        }
        if owned.count > count {
            try DurableFileIO.syncDirectory(directory)
        }
    }

    private func prepareRoot() throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw CocoaError(.fileWriteFileExists)
            }
            let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw CocoaError(.fileWriteNoPermission)
            }
        } else {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try DurableFileIO.syncDirectory(directory.deletingLastPathComponent())
        }
    }

    private func write(_ wrapper: FileWrapper, at root: URL) throws {
        for (name, child) in wrapper.fileWrappers ?? [:] {
            try Task.checkCancellation()
            let url = root.appending(path: name)
            if child.isDirectory {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: false
                )
                try write(child, at: url)
                try DurableFileIO.syncDirectory(url)
            } else if child.isRegularFile, let data = child.regularFileContents {
                try DurableFileIO.writeAndSync(data, to: url)
            } else {
                throw NotebookMarkdownBackupError.verificationFailed
            }
        }
    }

    private func verify(
        _ wrapper: FileWrapper,
        at root: URL,
        markerData: Data
    ) throws {
        let expectedNames = Set((wrapper.fileWrappers ?? [:]).keys)
            .union([Self.markerName])
        let actualNames = Set(try fileManager.contentsOfDirectory(atPath: root.path))
        guard actualNames == expectedNames else {
            throw NotebookMarkdownBackupError.verificationFailed
        }
        for (name, child) in wrapper.fileWrappers ?? [:] {
            try Task.checkCancellation()
            let url = root.appending(path: name)
            let values = try url.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isSymbolicLink != true else {
                throw NotebookMarkdownBackupError.verificationFailed
            }
            if child.isDirectory {
                guard values.isDirectory == true else {
                    throw NotebookMarkdownBackupError.verificationFailed
                }
                try verifyContents(child, at: url)
            } else {
                guard values.isRegularFile == true,
                      try Data(contentsOf: url) == child.regularFileContents else {
                    throw NotebookMarkdownBackupError.verificationFailed
                }
            }
        }
        guard try Data(contentsOf: root.appending(path: Self.markerName))
            == markerData else {
            throw NotebookMarkdownBackupError.verificationFailed
        }
    }

    private func verifyContents(_ wrapper: FileWrapper, at root: URL) throws {
        let expectedNames = Set((wrapper.fileWrappers ?? [:]).keys)
        let actualNames = Set(try fileManager.contentsOfDirectory(atPath: root.path))
        guard actualNames == expectedNames else {
            throw NotebookMarkdownBackupError.verificationFailed
        }
        for (name, child) in wrapper.fileWrappers ?? [:] {
            try Task.checkCancellation()
            let url = root.appending(path: name)
            let values = try url.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isSymbolicLink != true else {
                throw NotebookMarkdownBackupError.verificationFailed
            }
            if child.isDirectory {
                guard values.isDirectory == true else {
                    throw NotebookMarkdownBackupError.verificationFailed
                }
                try verifyContents(child, at: url)
            } else {
                guard values.isRegularFile == true,
                      try Data(contentsOf: url) == child.regularFileContents else {
                    throw NotebookMarkdownBackupError.verificationFailed
                }
            }
        }
    }

    private func rename(_ source: URL, to destination: URL) throws {
        let status = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard status == 0 else { throw DurableFileIO.posixError() }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return formatter.string(from: date)
    }
}

private struct BackupMarker: Codable {
    let version: Int
    let id: UUID
    let notebookID: UUID
    let createdAt: Date
    let noteCount: Int
}
