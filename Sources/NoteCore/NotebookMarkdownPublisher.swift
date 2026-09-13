import Darwin
import Foundation

public enum NotebookMarkdownPublisherError: Error, Equatable, LocalizedError {
    case destinationNotOwned
    case notebookIdentityMismatch
    case invalidCatalog
    case missingNote(UUID)
    case invalidNote(UUID)
    case unsafeManagedContent

    public var errorDescription: String? {
        switch self {
        case .destinationNotOwned:
            "The Markdown copy folder contains files that are not owned by "
                + "this notebook."
        case .notebookIdentityMismatch:
            "The Markdown copy folder belongs to a different notebook."
        case .invalidCatalog:
            "The notebook catalog is invalid, so Markdown copies were not "
                + "updated."
        case let .missingNote(noteID):
            "Note \(noteID.uuidString) is unavailable, so Markdown copies "
                + "were not updated."
        case let .invalidNote(noteID):
            "Note \(noteID.uuidString) is invalid, so Markdown copies were "
                + "not updated."
        case .unsafeManagedContent:
            "The managed Markdown hierarchy was changed outside the app. "
                + "Review it before trying again."
        }
    }
}

enum NotebookMarkdownPublishStage: CaseIterable {
    case pendingRecorded, stageBuilt, contentSwapped, manifestCommitted
}

/// Replaces one app-owned Markdown hierarchy from persisted notebook snapshots.
public actor NotebookMarkdownPublisher {
    public nonisolated let directory: URL

    private static let manifestName = ".notebook-markdown-manifest.json"
    private static let contentName = "Markdown"
    private static let generationName = ".notebook-generation"
    private static let stagePrefix = ".notebook-stage-"

    private let fileManager = FileManager.default

    public init(directory: URL) {
        self.directory = directory
    }

    public func publish(
        catalog: NotebookCatalogSnapshot,
        placements suppliedPlacements: [NotebookPlacement],
        notes: [NoteSnapshot]
    ) throws {
        try publish(
            catalog: catalog,
            placements: suppliedPlacements,
            notes: notes,
            afterStage: { _ in }
        )
    }

    func publish(
        catalog: NotebookCatalogSnapshot,
        placements suppliedPlacements: [NotebookPlacement],
        notes: [NoteSnapshot],
        afterStage: (NotebookMarkdownPublishStage) throws -> Void
    ) throws {
        let document: NotebookCatalogDocument
        do {
            document = try NotebookCatalogDocument(snapshot: catalog)
        } catch {
            throw NotebookMarkdownPublisherError.invalidCatalog
        }
        let placements = try document.placements()
        guard placements == suppliedPlacements else {
            throw NotebookMarkdownPublisherError.invalidCatalog
        }
        let plan = try makePlan(placements: placements, notes: notes)
        try prepareRoot()
        var manifest = try loadOrCreateManifest(notebookID: catalog.notebookID)
        try recover(&manifest)
        try validateManagedContent(manifest.current)
        if try matchesPublishedContent(plan, generation: manifest.current) {
            return
        }

        let generation = UUID()
        let stageName = Self.stagePrefix + generation.uuidString
        let stageURL = directory.appending(path: stageName)
        manifest.pending = Generation(
            id: generation,
            stageName: stageName,
            entries: plan.map(\.entry)
        )
        try save(manifest)
        try afterStage(.pendingRecorded)
        try beginStage(generation: generation, at: stageURL)
        try build(plan, at: stageURL)
        try afterStage(.stageBuilt)

        let contentURL = directory.appending(path: Self.contentName)
        if manifest.current == nil {
            try rename(stageURL, to: contentURL)
            try DurableFileIO.syncDirectory(directory)
            try afterStage(.contentSwapped)
            manifest.current = manifest.pending
            manifest.pending = nil
            try save(manifest)
            try afterStage(.manifestCommitted)
        } else {
            try exchange(stageURL, contentURL)
            try DurableFileIO.syncDirectory(directory)
            try afterStage(.contentSwapped)
            let previous = manifest.current!
            manifest.current = manifest.pending
            manifest.pending = nil
            manifest.cleanup = Cleanup(
                stageName: stageName,
                generationID: previous.id
            )
            try save(manifest)
            try afterStage(.manifestCommitted)
            try removeCleanup(&manifest)
        }
    }

    private struct PlannedFile {
        let entry: Entry
        let data: Data?
    }

    private func makePlan(
        placements: [NotebookPlacement],
        notes: [NoteSnapshot]
    ) throws -> [PlannedFile] {
        let noteMap = Dictionary(grouping: notes, by: \.noteID)
        var children = Dictionary(grouping: placements.filter { !$0.isInTrash }) {
            $0.parentID
        }
        for key in children.keys {
            children[key]!.sort { $0.item.id.uuidString < $1.item.id.uuidString }
        }
        var plan: [PlannedFile] = []

        func appendChildren(parent: UUID?, path: String) throws {
            var used: Set<String> = [
                NotebookName.collisionKey(Self.generationName)
            ]
            for placement in children[parent] ?? [] {
                var name = placement.displayName
                if placement.item.kind == .note,
                   !hasMarkdownExtension(name) {
                    name += ".md"
                }
                name = uniqueName(
                    name,
                    id: placement.item.id,
                    used: &used
                )
                do {
                    try NotebookName.validate(name)
                } catch {
                    throw NotebookMarkdownPublisherError.invalidCatalog
                }
                let relative = path.isEmpty ? name : path + "/" + name
                switch placement.item.kind {
                case .folder:
                    plan.append(
                        PlannedFile(
                            entry: Entry(path: relative, kind: .directory),
                            data: nil
                        )
                    )
                    try appendChildren(parent: placement.item.id, path: relative)
                case .note:
                    guard let candidates = noteMap[placement.item.id],
                          candidates.count == 1 else {
                        throw NotebookMarkdownPublisherError.missingNote(
                            placement.item.id
                        )
                    }
                    let note: NoteDocument
                    do {
                        note = try NoteDocument(snapshot: candidates[0])
                    } catch {
                        throw NotebookMarkdownPublisherError.invalidNote(
                            placement.item.id
                        )
                    }
                    plan.append(
                        PlannedFile(
                            entry: Entry(path: relative, kind: .file),
                            data: Data((try note.text).utf8)
                        )
                    )
                }
            }
        }
        try appendChildren(parent: nil, path: "")
        return plan
    }

    private func hasMarkdownExtension(_ name: String) -> Bool {
        let lowercased = name.lowercased(
            with: Locale(identifier: "en_US_POSIX")
        )
        return lowercased.hasSuffix(".md")
            || lowercased.hasSuffix(".markdown")
    }

    private func matchesPublishedContent(
        _ plan: [PlannedFile],
        generation: Generation?
    ) throws -> Bool {
        guard let generation, generation.entries.count == plan.count else {
            return false
        }
        let content = directory.appending(path: Self.contentName)
        for (expected, published) in zip(plan, generation.entries) {
            guard expected.entry.path == published.path,
                  expected.entry.kind == published.kind else {
                return false
            }
            let url = content.appending(path: expected.entry.path)
            let values = try url.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ]
            )
            guard values.isSymbolicLink != true else { return false }
            switch expected.entry.kind {
            case .directory:
                guard values.isDirectory == true else { return false }
            case .file:
                guard values.isRegularFile == true,
                      try Data(contentsOf: url) == expected.data else {
                    return false
                }
            }
        }
        return true
    }

    private func uniqueName(
        _ proposed: String,
        id: UUID,
        used: inout Set<String>
    ) -> String {
        var candidate = proposed
        var attempt = 0
        while !used.insert(NotebookName.collisionKey(candidate)).inserted {
            attempt += 1
            candidate = NotebookName.collisionName(
                proposed,
                id: id,
                attempt: attempt
            )
        }
        return candidate
    }

    private func build(
        _ plan: [PlannedFile],
        at stageURL: URL
    ) throws {
        for item in plan where item.entry.kind == .directory {
            try fileManager.createDirectory(
                at: stageURL.appending(path: item.entry.path),
                withIntermediateDirectories: true
            )
        }
        for item in plan where item.entry.kind == .file {
            let url = stageURL.appending(path: item.entry.path)
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try DurableFileIO.writeAndSync(item.data!, to: url)
        }
        let directories = Set(plan.flatMap { item -> [URL] in
            let url = stageURL.appending(path: item.entry.path)
            if item.entry.kind == .directory { return [url] }
            return [url.deletingLastPathComponent()]
        }).sorted { $0.path.count > $1.path.count }
        for directory in directories { try DurableFileIO.syncDirectory(directory) }
        try DurableFileIO.syncDirectory(stageURL)
    }

    private func beginStage(generation: UUID, at stageURL: URL) throws {
        try fileManager.createDirectory(
            at: stageURL,
            withIntermediateDirectories: false
        )
        try DurableFileIO.writeAndSync(
            Data(generation.uuidString.utf8),
            to: stageURL.appending(path: Self.generationName)
        )
        try DurableFileIO.syncDirectory(stageURL)
        try DurableFileIO.syncDirectory(directory)
    }

    private func prepareRoot() throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw NotebookMarkdownPublisherError.destinationNotOwned
            }
            return
        }
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try DurableFileIO.syncDirectory(directory.deletingLastPathComponent())
    }

    private func loadOrCreateManifest(notebookID: UUID) throws -> Manifest {
        let url = manifestURL
        if let data = try? Data(contentsOf: url) {
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard manifest.version == 1 else {
                throw NotebookMarkdownPublisherError.destinationNotOwned
            }
            guard manifest.notebookID == notebookID else {
                throw NotebookMarkdownPublisherError.notebookIdentityMismatch
            }
            return manifest
        }
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        guard entries.isEmpty else {
            throw NotebookMarkdownPublisherError.destinationNotOwned
        }
        let manifest = Manifest(version: 1, notebookID: notebookID)
        try save(manifest)
        return manifest
    }

    private func recover(_ manifest: inout Manifest) throws {
        if let pending = manifest.pending {
            let contentGeneration = generation(
                at: directory.appending(path: Self.contentName)
            )
            let stageURL = directory.appending(path: pending.stageName)
            if contentGeneration == pending.id {
                let prior = manifest.current
                manifest.current = pending
                manifest.pending = nil
                if let prior {
                    manifest.cleanup = Cleanup(
                        stageName: pending.stageName,
                        generationID: prior.id
                    )
                }
                try save(manifest)
            } else {
                if !fileManager.fileExists(atPath: stageURL.path) {
                    manifest.pending = nil
                    try save(manifest)
                    try removeCleanup(&manifest)
                    return
                }
                guard generation(at: stageURL) == pending.id else {
                    throw NotebookMarkdownPublisherError.unsafeManagedContent
                }
                try fileManager.removeItem(at: stageURL)
                manifest.pending = nil
                try save(manifest)
            }
        }
        try removeCleanup(&manifest)
    }

    private func removeCleanup(_ manifest: inout Manifest) throws {
        guard let cleanup = manifest.cleanup else { return }
        let url = directory.appending(path: cleanup.stageName)
        if fileManager.fileExists(atPath: url.path) {
            guard generation(at: url) == cleanup.generationID else {
                throw NotebookMarkdownPublisherError.unsafeManagedContent
            }
            try fileManager.removeItem(at: url)
            try DurableFileIO.syncDirectory(directory)
        }
        manifest.cleanup = nil
        try save(manifest)
    }

    private func validateManagedContent(_ current: Generation?) throws {
        let allowedRoot = Set(
            [Self.manifestName, Self.contentName]
        )
        let rootNames = try fileManager.contentsOfDirectory(atPath: directory.path)
        guard Set(rootNames).isSubset(of: allowedRoot) else {
            throw NotebookMarkdownPublisherError.destinationNotOwned
        }
        guard let current else {
            guard !rootNames.contains(Self.contentName) else {
                throw NotebookMarkdownPublisherError.unsafeManagedContent
            }
            return
        }
        let content = directory.appending(path: Self.contentName)
        guard generation(at: content) == current.id else {
            throw NotebookMarkdownPublisherError.unsafeManagedContent
        }
        let expected = Set(current.entries.map(\.path)).union([Self.generationName])
        let actual = try relativePaths(in: content)
        guard actual == expected else {
            throw NotebookMarkdownPublisherError.unsafeManagedContent
        }
    }

    private func relativePaths(in root: URL) throws -> Set<String> {
        let paths = try fileManager.subpathsOfDirectory(atPath: root.path)
        for path in paths {
            let url = root.appending(path: path)
            let values = try url.resourceValues(
                forKeys: [.isSymbolicLinkKey]
            )
            guard values.isSymbolicLink != true else {
                throw NotebookMarkdownPublisherError.unsafeManagedContent
            }
        }
        return Set(paths)
    }

    private func generation(at root: URL) -> UUID? {
        guard let data = try? Data(
            contentsOf: root.appending(path: Self.generationName)
        ), let value = String(data: data, encoding: .utf8) else { return nil }
        return UUID(uuidString: value)
    }

    private func save(_ manifest: Manifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try SyncFileIO.replace(try encoder.encode(manifest), at: manifestURL)
    }

    private func rename(_ source: URL, to destination: URL) throws {
        guard Darwin.rename(source.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func exchange(_ left: URL, _ right: URL) throws {
        let status = left.withUnsafeFileSystemRepresentation { leftPath in
            right.withUnsafeFileSystemRepresentation { rightPath in
                renameatx_np(AT_FDCWD, leftPath, AT_FDCWD, rightPath, UInt32(RENAME_SWAP))
            }
        }
        guard status == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private var manifestURL: URL {
        directory.appending(path: Self.manifestName)
    }
}

private struct Manifest: Codable {
    let version: Int
    let notebookID: UUID
    var current: Generation?
    var pending: Generation?
    var cleanup: Cleanup?

    init(version: Int, notebookID: UUID) {
        self.version = version
        self.notebookID = notebookID
        current = nil
        pending = nil
        cleanup = nil
    }
}

private struct Generation: Codable {
    let id: UUID
    let stageName: String
    let entries: [Entry]
}

private struct Cleanup: Codable {
    let stageName: String
    let generationID: UUID
}

private struct Entry: Codable {
    enum Kind: String, Codable, Equatable { case file, directory }
    let path: String
    let kind: Kind
}
