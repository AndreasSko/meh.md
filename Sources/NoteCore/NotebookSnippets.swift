import Foundation

/// A registered note or folder that contributes Markdown snippets.
public struct NotebookSnippetSource: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: NotebookItemKind
    public let name: String
    /// Full notebook-relative path, including the source's name.
    public let path: String
}

/// A folder component in a snippet's category path.
public struct NotebookSnippetCategory: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
}

/// A note body available for insertion as a Markdown snippet.
public struct NotebookSnippet: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let path: String
    /// Folder ancestry in root-to-leaf order. IDs remain stable across moves.
    public let categories: [NotebookSnippetCategory]
}

public enum NotebookSnippetError: Error, Equatable, LocalizedError {
    case sourceUnavailable

    public var errorDescription: String? {
        "This snippet source is no longer available."
    }
}

/// Expands insertion-time variables while leaving stored Markdown untouched.
public enum NotebookSnippetText {
    public static func expand(
        text: String,
        title: String,
        date: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: date)

        let values = ["date": day, "time": time, "title": title]
        var result = ""
        var cursor = text.startIndex
        while let start = text[cursor...].range(of: "{{") {
            result.append(contentsOf: text[cursor..<start.lowerBound])
            guard let end = text[start.upperBound...].range(of: "}}") else {
                result.append(contentsOf: text[start.lowerBound...])
                return result
            }
            let key = String(text[start.upperBound..<end.lowerBound])
            if let value = values[key] {
                result.append(contentsOf: value)
            } else {
                result.append(contentsOf: text[start.lowerBound..<end.upperBound])
            }
            cursor = end.upperBound
        }
        result.append(contentsOf: text[cursor...])
        return result
    }
}

struct NotebookSnippetMetadata {
    var sources: Set<UUID> = []

    func projection(_ placements: [NotebookPlacement])
        -> (sources: [NotebookSnippetSource], snippets: [NotebookSnippet]) {
        guard !sources.isEmpty else { return ([], []) }
        let active = placements.filter { !$0.isInTrash && !$0.item.isPermanentlyDeleted }
        let byID = Dictionary(uniqueKeysWithValues: active.map { ($0.item.id, $0) })

        func ancestry(_ placement: NotebookPlacement) -> [NotebookPlacement] {
            var result: [NotebookPlacement] = []
            var parent = placement.parentID
            var seen: Set<UUID> = [placement.item.id]
            while let id = parent, seen.insert(id).inserted, let folder = byID[id] {
                result.append(folder)
                parent = folder.parentID
            }
            return result.reversed()
        }

        func path(_ placement: NotebookPlacement) -> String {
            (ancestry(placement).map(\.displayName) + [placement.displayName])
                .joined(separator: "/")
        }

        let sourceRows = active.filter { sources.contains($0.item.id) }.map {
            NotebookSnippetSource(id: $0.item.id, kind: $0.item.kind,
                                  name: $0.displayName, path: path($0))
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        let snippets = active.compactMap { placement -> NotebookSnippet? in
            guard placement.item.kind == .note else { return nil }
            let parents = ancestry(placement)
            let registeredRoot = parents.firstIndex { sources.contains($0.item.id) }
            guard sources.contains(placement.item.id) || registeredRoot != nil else { return nil }
            let categories = registeredRoot.map { index in
                parents[index...].map {
                    NotebookSnippetCategory(id: $0.item.id, name: $0.displayName)
                }
            } ?? []
            return NotebookSnippet(id: placement.item.id, name: placement.displayName,
                                  path: path(placement), categories: categories)
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return (sourceRows, snippets)
    }
}
