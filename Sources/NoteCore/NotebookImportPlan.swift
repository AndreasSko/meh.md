import Foundation

public struct NotebookImportEntry: Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: NotebookItemKind
    public let name: String
    public let parentID: UUID?
    public let text: String?
    public let attachment: NotebookAttachmentDescriptor?
    public let createdAt: Date?
    public let modifiedAt: Date?

    public init(
        id: UUID,
        kind: NotebookItemKind,
        name: String,
        parentID: UUID?,
        text: String?,
        createdAt: Date? = nil,
        modifiedAt: Date? = nil,
        attachment: NotebookAttachmentDescriptor? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.parentID = parentID
        self.text = text
        self.attachment = attachment
        // Keep invalid supplied values visible to plan validation instead of
        // silently turning malformed metadata into an unknown date.
        self.createdAt = createdAt.map { $0.noteTimestamp ?? $0 }
        self.modifiedAt = modifiedAt.map { $0.noteTimestamp ?? $0 }
    }
}

public struct NotebookImportPlan: Codable, Equatable, Sendable {
    public let id: UUID
    public let entries: [NotebookImportEntry]
    public let skippedPaths: [String]

    public init(
        id: UUID,
        entries: [NotebookImportEntry],
        skippedPaths: [String]
    ) {
        self.id = id
        self.entries = entries
        self.skippedPaths = skippedPaths
    }
}

public enum NotebookImportScannerError: Error, Equatable, Sendable,
    LocalizedError
{
    case invalidName(path: String)
    case invalidUTF8(path: String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let path):
            "\(path) has a name that cannot be imported. Rename it and try again."
        case .invalidUTF8(let path):
            "\(path) is not valid UTF-8 Markdown. Save it as UTF-8 and try again."
        }
    }
}

public actor NotebookImportScanner {
    private let attachmentStore: NotebookAttachmentStore?

    public init(attachmentStore: NotebookAttachmentStore? = nil) {
        self.attachmentStore = attachmentStore
    }

    public func scan(urls: [URL]) async throws -> NotebookImportPlan {
        let selections = try selectedSources(from: urls)
        var entries: [NotebookImportEntry] = []
        var skippedPaths: [String] = []
        var stagedIDs: [UUID] = []

        do {
            for selection in selections {
                try Task.checkCancellation()
                let name = selection.url.lastPathComponent
                if Self.shouldSkip(selection.values, name: name) {
                    skippedPaths.append(name)
                } else if selection.values.isDirectory == true {
                    let folderID = UUID()
                    let attempt: ScanAttempt
                    if let attachmentStore {
                        attempt = try await attachmentStore.withCoordinatedRead(
                            at: selection.url
                        ) { coordinatedURL, write in
                            Self.walkRootDirectory(
                                coordinatedURL, name: name,
                                folderID: folderID, includeAttachments: true,
                                write: write
                            )
                        }
                    } else {
                        attempt = try coordinatedRootDirectory(
                            selection.url, name: name, folderID: folderID
                        )
                    }
                    entries.append(contentsOf: attempt.entries)
                    skippedPaths.append(contentsOf: attempt.skippedPaths)
                    stagedIDs.append(contentsOf: attempt.stagedIDs)
                    if let error = attempt.error { throw error }
                } else if selection.values.isRegularFile == true,
                    Self.isMarkdown(selection.url)
                {
                    try Self.appendCoordinatedNote(
                        at: selection.url, parentID: nil,
                        relativePath: name, entries: &entries
                    )
                } else if selection.values.isRegularFile == true,
                    let attachmentStore
                {
                    try Self.validate(name: name, path: name)
                    let id = UUID()
                    stagedIDs.append(id)
                    let imported = try await attachmentStore.withCoordinatedRead(
                        at: selection.url
                    ) { coordinatedURL, write in
                        let descriptor = try write(coordinatedURL, id)
                        let values = try coordinatedURL.resourceValues(
                            forKeys: [.creationDateKey, .contentModificationDateKey]
                        )
                        return NotebookImportEntry(
                            id: id, kind: .attachment, name: name,
                            parentID: nil, text: nil,
                            createdAt: values.creationDate,
                            modifiedAt: values.contentModificationDate,
                            attachment: descriptor
                        )
                    }
                    entries.append(imported)
                } else {
                    skippedPaths.append(name)
                }
            }

            return NotebookImportPlan(
                id: UUID(),
                entries: entries,
                skippedPaths: skippedPaths
            )
        } catch {
            if let attachmentStore {
                for id in stagedIDs {
                    // Cleanup must outlive cancellation of this scan task.
                    try? await Task.detached {
                        try await attachmentStore.remove(id: id)
                    }.value
                }
            }
            throw error
        }
    }

    /// Release staged content when an import review is canceled.
    public func discard(plan: NotebookImportPlan) async throws {
        guard let attachmentStore else { return }
        for entry in plan.entries where entry.kind == .attachment {
            let id = entry.id
            try await Task.detached {
                try await attachmentStore.remove(id: id)
            }.value
        }
    }

    private struct SelectedSource {
        let url: URL
        let values: URLResourceValues
    }

    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .isPackageKey,
        .isHiddenKey,
        .creationDateKey,
        .contentModificationDateKey,
    ]

    private func selectedSources(from urls: [URL]) throws -> [SelectedSource] {
        var urlsByPath: [String: URL] = [:]
        for url in urls {
            try Task.checkCancellation()
            let standardized = url.standardizedFileURL
            urlsByPath[standardized.path] = standardized
        }

        let sources = try urlsByPath.values.map { url in
            try Task.checkCancellation()
            return SelectedSource(
                url: url,
                values: try url.resourceValues(forKeys: Self.resourceKeys)
            )
        }
        let directoryPaths = sources.compactMap { source in
            source.values.isDirectory == true
                && !Self.shouldSkip(
                    source.values,
                    name: source.url.lastPathComponent
                )
                ? source.url.pathComponents
                : nil
        }

        return sources
            .filter { source in
                !directoryPaths.contains { directoryPath in
                    isDescendant(
                        source.url.pathComponents,
                        of: directoryPath
                    )
                }
            }
            .sorted { $0.url.path < $1.url.path }
    }

    private struct ScanAttempt: Sendable {
        var entries: [NotebookImportEntry] = []
        var skippedPaths: [String] = []
        var stagedIDs: [UUID] = []
        var error: (any Error)?
    }

    private func coordinatedRootDirectory(
        _ url: URL, name: String, folderID: UUID
    ) throws -> ScanAttempt {
        var coordinationError: NSError?
        var attempt: ScanAttempt?
        NSFileCoordinator().coordinate(
            readingItemAt: url, options: [], error: &coordinationError
        ) { coordinatedURL in
            attempt = Self.walkRootDirectory(
                coordinatedURL, name: name, folderID: folderID,
                includeAttachments: false,
                write: { _, _ in throw NotebookAttachmentError.unsupportedSource }
            )
        }
        if let coordinationError { throw coordinationError }
        guard let attempt else { throw NotebookImportScannerError.invalidName(path: name) }
        return attempt
    }

    private static func walkRootDirectory(
        _ url: URL,
        name: String,
        folderID: UUID,
        includeAttachments: Bool,
        write: (URL, UUID) throws -> NotebookAttachmentDescriptor
    ) -> ScanAttempt {
        var attempt = ScanAttempt()
        do {
            try validate(name: name, path: name)
            let values = try url.resourceValues(forKeys: resourceKeys)
            attempt.entries.append(NotebookImportEntry(
                id: folderID, kind: .folder, name: name,
                parentID: nil, text: nil,
                createdAt: values.creationDate,
                modifiedAt: values.contentModificationDate
            ))
            try walkDirectory(
                url, parentID: folderID, relativePath: name,
                includeAttachments: includeAttachments,
                write: write, attempt: &attempt
            )
        } catch { attempt.error = error }
        return attempt
    }

    private static func walkDirectory(
        _ directoryURL: URL,
        parentID: UUID,
        relativePath: String,
        includeAttachments: Bool,
        write: (URL, UUID) throws -> NotebookAttachmentDescriptor,
        attempt: inout ScanAttempt
    ) throws {
        try Task.checkCancellation()
        let children = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: []
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        for child in children {
            try Task.checkCancellation()
            let name = child.lastPathComponent
            let childPath = relativePath + "/" + name
            let values = try child.resourceValues(forKeys: resourceKeys)
            if shouldSkip(values, name: name) {
                attempt.skippedPaths.append(childPath)
            } else if values.isDirectory == true {
                let folderID = UUID()
                try validate(name: name, path: childPath)
                attempt.entries.append(NotebookImportEntry(
                    id: folderID, kind: .folder, name: name,
                    parentID: parentID, text: nil,
                    createdAt: values.creationDate,
                    modifiedAt: values.contentModificationDate
                ))
                try walkDirectory(
                    child, parentID: folderID, relativePath: childPath,
                    includeAttachments: includeAttachments,
                    write: write, attempt: &attempt
                )
            } else if values.isRegularFile == true, isMarkdown(child) {
                try appendNote(
                    at: child, parentID: parentID,
                    relativePath: childPath, entries: &attempt.entries
                )
            } else if values.isRegularFile == true, includeAttachments {
                try validate(name: name, path: childPath)
                let id = UUID()
                attempt.stagedIDs.append(id)
                let descriptor = try write(child, id)
                attempt.entries.append(NotebookImportEntry(
                    id: id, kind: .attachment, name: name,
                    parentID: parentID, text: nil,
                    createdAt: values.creationDate,
                    modifiedAt: values.contentModificationDate,
                    attachment: descriptor
                ))
            } else {
                attempt.skippedPaths.append(childPath)
            }
        }
    }

    private static func appendCoordinatedNote(
        at url: URL,
        parentID: UUID?,
        relativePath: String,
        entries: inout [NotebookImportEntry]
    ) throws {
        var coordinationError: NSError?
        var scanningError: Error?
        NSFileCoordinator().coordinate(
            readingItemAt: url, options: [], error: &coordinationError
        ) { coordinatedURL in
            do {
                try appendNote(
                    at: coordinatedURL, parentID: parentID,
                    relativePath: relativePath, entries: &entries
                )
            } catch { scanningError = error }
        }
        if let coordinationError { throw coordinationError }
        if let scanningError { throw scanningError }
    }

    private static func appendNote(
        at url: URL,
        parentID: UUID?,
        relativePath: String,
        entries: inout [NotebookImportEntry]
    ) throws {
        try Task.checkCancellation()
        let name = url.lastPathComponent
        try validate(name: name, path: relativePath)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        try Task.checkCancellation()
        let text = String(decoding: data, as: UTF8.self)
        guard Data(text.utf8) == data else {
            throw NotebookImportScannerError.invalidUTF8(path: relativePath)
        }
        let values = try url.resourceValues(
            forKeys: [.creationDateKey, .contentModificationDateKey]
        )
        entries.append(
            NotebookImportEntry(
                id: UUID(),
                kind: .note,
                name: name,
                parentID: parentID,
                text: text,
                createdAt: values.creationDate,
                modifiedAt: values.contentModificationDate
            )
        )
    }

    private static func validate(name: String, path: String) throws {
        do {
            try NotebookName.validate(name)
        } catch {
            throw NotebookImportScannerError.invalidName(path: path)
        }
    }

    private static func shouldSkip(
        _ values: URLResourceValues,
        name: String
    ) -> Bool {
        name.hasPrefix(".")
            || values.isHidden == true
            || values.isSymbolicLink == true
            || values.isPackage == true
    }

    private static func isMarkdown(_ url: URL) -> Bool {
        let extensionName = url.pathExtension.lowercased()
        return extensionName == "md" || extensionName == "markdown"
    }

    private func isDescendant(
        _ candidate: [String],
        of ancestor: [String]
    ) -> Bool {
        candidate.count > ancestor.count
            && candidate.starts(with: ancestor)
    }
}
