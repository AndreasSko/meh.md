import Foundation

/// An immutable copy, so a receiver never reads a file that the editor changes.
nonisolated struct NotebookSharedFile: Identifiable, Sendable {
    let id: UUID
    let url: URL

    nonisolated static func markdown(
        text: String, filename: String,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> Self {
        let lower = filename.lowercased()
        let name = lower.hasSuffix(".md") || lower.hasSuffix(".markdown")
            ? filename : filename + ".md"
        return try create(data: Data(text.utf8), filename: name,
                          temporaryDirectory: temporaryDirectory)
    }

    nonisolated static func create(
        data: Data, filename: String,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> Self {
        guard !filename.isEmpty, filename != ".", filename != "..",
              !filename.contains("/"), !filename.contains("\\") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let manager = FileManager.default
        let root = temporaryDirectory.appendingPathComponent(
            "meh.md-shares", isDirectory: true
        )
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        // Extensions may read after the sheet closes. Retain recent copies and
        // only remove old, app-owned share directories on a subsequent share.
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let previous = (try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.creationDateKey]
        )) ?? []
        for directory in previous where UUID(uuidString: directory.lastPathComponent) != nil {
            if let created = try? directory.resourceValues(forKeys: [.creationDateKey]).creationDate,
               created < cutoff {
                try? manager.removeItem(at: directory)
            }
        }
        let id = UUID()
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
        return Self(id: id, url: url)
    }
}
