import Foundation

public enum NotebookStorageCategory: String, CaseIterable, Sendable {
    case notesAndHistory, attachments, recoveryCopies, markdownCopies, backups, other
}

public enum NotebookStorageReportError: Error, Sendable {
    case duplicateDocumentID(UUID)
    case duplicateAttachmentID(UUID)
    case rootOutsideTrustedBoundary(URL)
    case invalidTrustedBoundary(URL)
}

public struct NotebookStorageCategoryTotal: Sendable, Equatable {
    public let category: NotebookStorageCategory
    public let byteCount: Int64
}

public struct NotebookStorageDocument: Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let path: String
    public let isInTrash: Bool

    public init(id: UUID, name: String, path: String, isInTrash: Bool) {
        self.id = id
        self.name = name
        self.path = path
        self.isInTrash = isInTrash
    }
}

/// Catalog identity and effective trash state, including files not downloaded yet.
public struct NotebookStorageAttachment: Sendable, Equatable {
    public let id: UUID
    public let isInTrash: Bool

    public init(id: UUID, isInTrash: Bool) {
        self.id = id
        self.isInTrash = isInTrash
    }
}

public struct NotebookStorageDocumentUsage: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let path: String
    public let isInTrash: Bool
    public let currentAndHistoryBytes: Int64
    public let recoveryBytes: Int64
    public var totalBytes: Int64 { currentAndHistoryBytes + recoveryBytes }
}

/// Logical sizes of regular files owned by the selected notebook workspace.
/// This does not measure unique physical blocks, app binaries, or cloud usage.
public struct NotebookStorageReport: Sendable {
    public let totalBytes: Int64
    public let categories: [NotebookStorageCategoryTotal]
    public let documents: [NotebookStorageDocumentUsage]
    public let activeNoteCount: Int
    public let trashNoteCount: Int
    public let activeAttachmentCount: Int
    public let trashAttachmentCount: Int
    /// Counts managed content files present locally, including empty files.
    public let residentAttachmentCount: Int
    public let measuredAt: Date

    public static func scan(
        trustedBoundary: URL,
        notebookDirectory: URL,
        markdownCopiesDirectory: URL,
        backupDirectory: URL,
        documents: [NotebookStorageDocument],
        attachments: [NotebookStorageAttachment] = []
    ) async throws -> NotebookStorageReport {
        let worker = Task.detached(priority: .utility) {
            try measure(
                trustedBoundary: trustedBoundary,
                notebookDirectory: notebookDirectory,
                markdownCopiesDirectory: markdownCopiesDirectory,
                backupDirectory: backupDirectory,
                documents: documents, attachments: attachments
            )
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let report = try await worker.value
            try Task.checkCancellation()
            return report
        } onCancel: {
            worker.cancel()
        }
    }

    private static func measure(
        trustedBoundary: URL,
        notebookDirectory: URL,
        markdownCopiesDirectory: URL,
        backupDirectory: URL,
        documents: [NotebookStorageDocument],
        attachments: [NotebookStorageAttachment]
    ) throws -> NotebookStorageReport {
        let manager = FileManager.default
        let boundary = normalizedRoot(trustedBoundary)
        var knownIDs = Set<UUID>()
        for document in documents {
            guard knownIDs.insert(document.id).inserted else {
                throw NotebookStorageReportError.duplicateDocumentID(document.id)
            }
        }
        var knownAttachments = Set<UUID>()
        for attachment in attachments {
            guard knownAttachments.insert(attachment.id).inserted else {
                throw NotebookStorageReportError.duplicateAttachmentID(attachment.id)
            }
        }
        var residentAttachments = Set<UUID>()
        let notebook = normalizedRoot(notebookDirectory)
        // Most specific roots win when callers supply overlapping locations.
        let roots: [(url: URL, category: NotebookStorageCategory)] = [
            (normalizedRoot(markdownCopiesDirectory), .markdownCopies),
            (normalizedRoot(backupDirectory), .backups),
            (notebook, .other)
        ].sorted {
            if $0.url.path.count != $1.url.path.count {
                return $0.url.path.count > $1.url.path.count
            }
            return $0.category.rawValue < $1.category.rawValue
        }
        for root in roots {
            guard root.url.path == boundary.path
                || root.url.path.hasPrefix(boundary.path == "/" ? "/" : boundary.path + "/")
            else { throw NotebookStorageReportError.rootOutsideTrustedBoundary(root.url) }
        }
        var totals = Dictionary(uniqueKeysWithValues:
            NotebookStorageCategory.allCases.map { ($0, Int64(0)) })
        var current: [UUID: Int64] = [:]
        var recovery: [UUID: Int64] = [:]
        var visited = Set<String>()

        func attributes(_ url: URL) throws -> [FileAttributeKey: Any]? {
            do { return try manager.attributesOfItem(atPath: url.path) }
            catch let error as NSError
                where error.domain == NSCocoaErrorDomain
                    && [NSFileNoSuchFileError, NSFileReadNoSuchFileError]
                        .contains(error.code) { return nil }
        }

        func hasSafeAncestors(_ url: URL) throws -> Bool {
            var ancestor = url
            while true {
                try Task.checkCancellation()
                guard let values = try attributes(ancestor) else { return false }
                guard values[.type] as? FileAttributeType == .typeDirectory
                else { return false }
                if ancestor.path == boundary.path { return true }
                let parentPath = (ancestor.path as NSString).deletingLastPathComponent
                ancestor = URL(fileURLWithPath: parentPath.isEmpty ? "/" : parentPath)
            }
        }

        guard let boundaryValues = try attributes(boundary),
              boundaryValues[.type] as? FileAttributeType == .typeDirectory else {
            throw NotebookStorageReportError.invalidTrustedBoundary(boundary)
        }

        func contains(_ root: URL, _ file: URL) -> Bool {
            file.path == root.path || file.path.hasPrefix(root.path + "/")
        }

        func visit(_ url: URL) throws {
            try Task.checkCancellation()
            guard visited.insert(url.path).inserted,
                  let values = try attributes(url) else { return }
            let type = values[.type] as? FileAttributeType
            if type == .typeDirectory {
                guard try hasSafeAncestors(url) else { return }
                // No skipsHiddenFiles: crash leftovers consume storage too.
                for child in try manager.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil
                ) { try visit(normalizedRoot(child)) }
                return
            }
            guard type == .typeRegular else { return }
            let parentPath = (url.path as NSString).deletingLastPathComponent
            guard try hasSafeAncestors(URL(fileURLWithPath: parentPath)) else { return }
            guard let size = values[.size] as? NSNumber else {
                throw CocoaError(.fileReadUnknown)
            }
            let bytes = size.int64Value
            var category = roots.first { contains($0.url, url) }?.category ?? .other
            if category == .other, contains(notebook, url) {
                let relative = String(url.path.dropFirst(notebook.path.count + 1))
                if relative == "catalog.previous.automerge"
                    || isQuarantineFilename(relative, document: "catalog") {
                    category = .recoveryCopies
                }
                let parts = relative.split(separator: "/")
                if parts.count == 3, parts[0] == "attachments",
                   let id = UUID(uuidString: String(parts[1])),
                   knownAttachments.contains(id), parts[2] == "content" {
                    category = .attachments
                    residentAttachments.insert(id)
                }
                if parts.count == 3, parts[0] == "notes",
                   let id = UUID(uuidString: String(parts[1])), knownIDs.contains(id) {
                    if parts[2] == "note.automerge" {
                        category = .notesAndHistory
                        current[id, default: 0] += bytes
                    } else if parts[2] == "note.previous.automerge"
                        || isQuarantineFilename(String(parts[2]), document: "note") {
                        category = .recoveryCopies
                        recovery[id, default: 0] += bytes
                    }
                }
            }
            totals[category, default: 0] += bytes
        }

        for root in roots where try hasSafeAncestors(root.url) {
            try visit(root.url)
        }
        try Task.checkCancellation()
        let usages = documents.map {
            NotebookStorageDocumentUsage(
                id: $0.id, name: $0.name, path: $0.path,
                isInTrash: $0.isInTrash,
                currentAndHistoryBytes: current[$0.id, default: 0],
                recoveryBytes: recovery[$0.id, default: 0]
            )
        }.sorted {
            if $0.totalBytes != $1.totalBytes { return $0.totalBytes > $1.totalBytes }
            if $0.path != $1.path { return $0.path < $1.path }
            return $0.id.uuidString < $1.id.uuidString
        }
        return NotebookStorageReport(
            totalBytes: totals.values.reduce(0, +),
            categories: NotebookStorageCategory.allCases.map {
                NotebookStorageCategoryTotal(category: $0, byteCount: totals[$0, default: 0])
            },
            documents: usages,
            activeNoteCount: documents.filter { !$0.isInTrash }.count,
            trashNoteCount: documents.filter(\.isInTrash).count,
            activeAttachmentCount: attachments.filter { !$0.isInTrash }.count,
            trashAttachmentCount: attachments.filter(\.isInTrash).count,
            residentAttachmentCount: residentAttachments.count,
            measuredAt: Date()
        )
    }

    private static func isQuarantineFilename(
        _ filename: String, document: String
    ) -> Bool {
        let prefix = document + ".quarantine-"
        let suffix = ".automerge"
        guard filename.hasPrefix(prefix), filename.hasSuffix(suffix) else {
            return false
        }
        let identifier = String(filename.dropFirst(prefix.count).dropLast(suffix.count))
        return identifier.count == 36 && UUID(uuidString: identifier) != nil
    }

    /// macOS exposes these fixed system aliases. Normalize only these prefixes;
    /// arbitrary links inside a supplied workspace remain forbidden.
    private static func normalizedRoot(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        for alias in ["/tmp", "/var"] {
            if standardized.path == alias
                || standardized.path.hasPrefix(alias + "/") {
                return URL(fileURLWithPath: "/private" + standardized.path)
            }
        }
        return standardized
    }
}
