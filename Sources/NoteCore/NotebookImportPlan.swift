import Foundation

public struct NotebookImportEntry: Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: NotebookItemKind
    public let name: String
    public let parentID: UUID?
    public let text: String?

    public init(
        id: UUID,
        kind: NotebookItemKind,
        name: String,
        parentID: UUID?,
        text: String?
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.parentID = parentID
        self.text = text
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
    public init() {}

    public func scan(urls: [URL]) async throws -> NotebookImportPlan {
        let selections = try selectedSources(from: urls)
        var entries: [NotebookImportEntry] = []
        var skippedPaths: [String] = []

        for selection in selections {
            try Task.checkCancellation()
            let name = selection.url.lastPathComponent
            if shouldSkip(selection.values, name: name) {
                skippedPaths.append(name)
            } else if selection.values.isDirectory == true {
                let folderID = UUID()
                try validate(name: name, path: name)
                entries.append(
                    NotebookImportEntry(
                        id: folderID,
                        kind: .folder,
                        name: name,
                        parentID: nil,
                        text: nil
                    )
                )
                try scanDirectory(
                    selection.url,
                    parentID: folderID,
                    relativePath: name,
                    entries: &entries,
                    skippedPaths: &skippedPaths
                )
            } else if selection.values.isRegularFile == true,
                isMarkdown(selection.url)
            {
                try appendNote(
                    at: selection.url,
                    parentID: nil,
                    relativePath: name,
                    entries: &entries
                )
            } else {
                skippedPaths.append(name)
            }
        }

        return NotebookImportPlan(
            id: UUID(),
            entries: entries,
            skippedPaths: skippedPaths
        )
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
                && !shouldSkip(
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

    private func scanDirectory(
        _ directoryURL: URL,
        parentID: UUID,
        relativePath: String,
        entries: inout [NotebookImportEntry],
        skippedPaths: inout [String]
    ) throws {
        try Task.checkCancellation()
        let children = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(Self.resourceKeys),
            options: []
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        for child in children {
            try Task.checkCancellation()
            let name = child.lastPathComponent
            let childPath = relativePath + "/" + name
            let values = try child.resourceValues(forKeys: Self.resourceKeys)

            if shouldSkip(values, name: name) {
                skippedPaths.append(childPath)
            } else if values.isDirectory == true {
                let folderID = UUID()
                try validate(name: name, path: childPath)
                entries.append(
                    NotebookImportEntry(
                        id: folderID,
                        kind: .folder,
                        name: name,
                        parentID: parentID,
                        text: nil
                    )
                )
                try scanDirectory(
                    child,
                    parentID: folderID,
                    relativePath: childPath,
                    entries: &entries,
                    skippedPaths: &skippedPaths
                )
            } else if values.isRegularFile == true, isMarkdown(child) {
                try appendNote(
                    at: child,
                    parentID: parentID,
                    relativePath: childPath,
                    entries: &entries
                )
            } else {
                skippedPaths.append(childPath)
            }
        }
    }

    private func appendNote(
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
        entries.append(
            NotebookImportEntry(
                id: UUID(),
                kind: .note,
                name: name,
                parentID: parentID,
                text: text
            )
        )
    }

    private func validate(name: String, path: String) throws {
        do {
            try NotebookName.validate(name)
        } catch {
            throw NotebookImportScannerError.invalidName(path: path)
        }
    }

    private func shouldSkip(
        _ values: URLResourceValues,
        name: String
    ) -> Bool {
        name.hasPrefix(".")
            || values.isHidden == true
            || values.isSymbolicLink == true
            || values.isPackage == true
    }

    private func isMarkdown(_ url: URL) -> Bool {
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
