import Darwin
import Foundation

public struct NotebookMarkdownBackup: Equatable, Sendable {
    public let url: URL
    public let createdAt: Date
    public let noteCount: Int
    public let attachmentCount: Int
    public let notebookID: UUID
}

public enum NotebookMarkdownBackupError: Error, Equatable, LocalizedError {
    case backupInProgress
    case invalidRetentionCount
    case invalidCatalog
    case reservedName
    case verificationFailed

    public var errorDescription: String? {
        switch self {
        case .backupInProgress:
            "A backup is already being prepared."
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
    private var isCreatingBackup = false

    public init(directory: URL) {
        self.directory = directory
    }

    public func createBackup(
        catalog: NotebookCatalogSnapshot,
        placements: [NotebookPlacement],
        notes: [NoteSnapshot],
        attachmentStore: NotebookAttachmentStore? = nil,
        retentionCount: Int
    ) async throws -> NotebookMarkdownBackup {
        try await createBackup(
            catalog: catalog,
            placements: placements,
            notes: notes,
            attachmentStore: attachmentStore,
            retentionCount: retentionCount,
            createdAt: Date()
        )
    }

    func createBackup(
        catalog: NotebookCatalogSnapshot,
        placements: [NotebookPlacement],
        notes: [NoteSnapshot],
        attachmentStore: NotebookAttachmentStore? = nil,
        retentionCount: Int,
        createdAt: Date
    ) async throws -> NotebookMarkdownBackup {
        guard !isCreatingBackup else {
            throw NotebookMarkdownBackupError.backupInProgress
        }
        isCreatingBackup = true
        defer { isCreatingBackup = false }
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
        let tree = try makeTree(
            placements: active, notes: notes,
            includeAttachments: attachmentStore != nil
        )
        guard !tree.keys.contains(where: {
            NotebookName.collisionKey($0) == NotebookName.collisionKey(Self.markerName)
        }) else {
            throw NotebookMarkdownBackupError.reservedName
        }
        let attachmentCount = attachmentStore == nil ? 0
            : active.filter { $0.item.kind == .attachment }.count
        let noteCount = active.filter { $0.item.kind == .note }.count
        let identifier = UUID()
        let marker = BackupMarker(
            version: 1,
            id: identifier,
            notebookID: catalog.notebookID,
            createdAt: createdAt,
            noteCount: noteCount,
            attachmentCount: attachmentCount
        )
        let name = Self.backupPrefix + Self.timestamp(createdAt)
            + "-" + identifier.uuidString
        let stage = directory.appending(path: Self.stagePrefix + identifier.uuidString)
        let destination = directory.appending(path: name)

        try prepareRoot()
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: false)
        do {
            try Task.checkCancellation()
            try await write(tree, at: stage, attachmentStore: attachmentStore)
            let markerData = try JSONEncoder().encode(marker)
            try DurableFileIO.writeAndSync(
                markerData,
                to: stage.appending(path: Self.markerName)
            )
            try await verify(tree, at: stage, attachmentStore: attachmentStore, includesMarker: true)
            guard try Data(contentsOf: stage.appending(path: Self.markerName)) == markerData else {
                throw NotebookMarkdownBackupError.verificationFailed
            }
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
            attachmentCount: attachmentCount,
            notebookID: catalog.notebookID
        )
        try Task.checkCancellation()
        try prune(notebookID: catalog.notebookID, keeping: retentionCount)
        return backup
    }

    /// Applies a changed limit without creating a new backup.
    public func enforceRetention(notebookID: UUID, keeping count: Int) throws {
        guard !isCreatingBackup else {
            throw NotebookMarkdownBackupError.backupInProgress
        }
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
                attachmentCount: marker.attachmentCount,
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

    private indirect enum Entry {
        case folder([String: Entry])
        case note(Data)
        case attachment(NotebookAttachmentDescriptor)
    }

    private func makeTree(
        placements: [NotebookPlacement], notes: [NoteSnapshot],
        includeAttachments: Bool
    ) throws -> [String: Entry] {
        let children = Dictionary(grouping: placements, by: \.parentID)
        let snapshots = Dictionary(grouping: notes, by: \.noteID)
        func build(_ parent: UUID?) throws -> [String: Entry] {
            var entries: [String: Entry] = [:]
            var used = Set<String>()
            for placement in (children[parent] ?? []).sorted(by: {
                $0.item.id.uuidString < $1.item.id.uuidString
            }) {
                let id = placement.item.id
                var name = placement.displayName
                let entry: Entry
                switch placement.item.kind {
                case .folder:
                    entry = .folder(try build(id))
                case .note:
                    guard let matches = snapshots[id], matches.count == 1 else {
                        throw NotebookMarkdownPublisherError.missingNote(id)
                    }
                    let document = try NoteDocument(snapshot: matches[0])
                    entry = .note(Data(try document.text.utf8))
                    if !name.lowercased().hasSuffix(".md")
                        && !name.lowercased().hasSuffix(".markdown") {
                        name += ".md"
                    }
                case .attachment:
                    guard includeAttachments else { continue }
                    guard let content = placement.item.attachment else {
                        throw NotebookMarkdownBackupError.invalidCatalog
                    }
                    entry = .attachment(.init(id: id, content: content))
                }
                let original = name
                var attempt = 0
                while used.contains(NotebookName.collisionKey(name))
                    || name.utf8.count > 255 {
                    attempt += 1
                    name = NotebookName.collisionName(original, id: id, attempt: attempt)
                }
                try NotebookName.validate(name)
                used.insert(NotebookName.collisionKey(name))
                entries[name] = entry
            }
            return entries
        }
        return try build(nil)
    }

    private func write(
        _ entries: [String: Entry], at root: URL,
        attachmentStore: NotebookAttachmentStore?
    ) async throws {
        for (name, entry) in entries {
            try Task.checkCancellation()
            let url = root.appending(path: name)
            switch entry {
            case .folder(let children):
                try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
                try await write(children, at: url, attachmentStore: attachmentStore)
                try DurableFileIO.syncDirectory(url)
            case .note(let data):
                try DurableFileIO.writeAndSync(data, to: url)
            case .attachment(let descriptor):
                guard let attachmentStore else {
                    throw NotebookMarkdownBackupError.verificationFailed
                }
                try await attachmentStore.export(descriptor, to: url)
            }
        }
    }

    private func verify(
        _ entries: [String: Entry], at root: URL,
        attachmentStore: NotebookAttachmentStore?, includesMarker: Bool = false
    ) async throws {
        var expectedNames = Set(entries.keys)
        if includesMarker {
            expectedNames.insert(Self.markerName)
        }
        guard Set(try fileManager.contentsOfDirectory(atPath: root.path)) == expectedNames else {
            throw NotebookMarkdownBackupError.verificationFailed
        }
        for (name, entry) in entries {
            try Task.checkCancellation()
            let url = root.appending(path: name)
            let values = try url.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isSymbolicLink != true else {
                throw NotebookMarkdownBackupError.verificationFailed
            }
            switch entry {
            case .folder(let children):
                guard values.isDirectory == true else {
                    throw NotebookMarkdownBackupError.verificationFailed
                }
                try await verify(children, at: url, attachmentStore: attachmentStore)
            case .note(let data):
                guard values.isRegularFile == true, try Data(contentsOf: url) == data else {
                    throw NotebookMarkdownBackupError.verificationFailed
                }
            case .attachment(let descriptor):
                guard values.isRegularFile == true, let attachmentStore else {
                    throw NotebookMarkdownBackupError.verificationFailed
                }
                try await attachmentStore.verifyExternalFile(
                    at: url, expectedContent: descriptor.content
                )
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
    let attachmentCount: Int

    init(version: Int, id: UUID, notebookID: UUID, createdAt: Date,
         noteCount: Int, attachmentCount: Int) {
        self.version = version
        self.id = id
        self.notebookID = notebookID
        self.createdAt = createdAt
        self.noteCount = noteCount
        self.attachmentCount = attachmentCount
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        id = try values.decode(UUID.self, forKey: .id)
        notebookID = try values.decode(UUID.self, forKey: .notebookID)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        noteCount = try values.decode(Int.self, forKey: .noteCount)
        attachmentCount = try values.decodeIfPresent(Int.self, forKey: .attachmentCount) ?? 0
    }
}
