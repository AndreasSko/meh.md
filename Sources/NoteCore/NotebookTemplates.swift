import Foundation

/// Template metadata stays in the catalog; Markdown remains ordinary text.
public enum NotebookTemplateDestination: Codable, Hashable, Sendable {
    case inherit
    case root
    case folder(UUID)
}

public struct NotebookTemplateSettings: Codable, Equatable, Sendable {
    public var destination: NotebookTemplateDestination
    public var filenamePattern: String?

    public init(destination: NotebookTemplateDestination = .inherit,
                filenamePattern: String? = nil) {
        self.destination = destination
        self.filenamePattern = filenamePattern
    }
}

public struct NotebookTemplateSource: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: NotebookItemKind
    public let name: String
    /// Full notebook-relative path, including the source's name.
    public let path: String
}

public struct NotebookTemplate: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let path: String
    public let inheritedFromID: UUID?
    public let settings: NotebookTemplateSettings
    public let effectiveSettings: NotebookTemplateSettings
}

public enum NotebookTemplateError: Error, Equatable, LocalizedError {
    case sourceUnavailable
    case destinationUnavailable
    case unsupportedVariable(String)

    public var errorDescription: String? {
        switch self {
        case .sourceUnavailable: "This template is no longer available."
        case .destinationUnavailable:
            "The template's destination folder is unavailable. Choose another folder."
        case .unsupportedVariable(let variable):
            "Unknown filename variable \(variable). Use {{date}}, {{time}}, or {{template}}."
        }
    }
}

public enum NotebookTemplateFilename {
    /// Filename-only substitutions. Template bodies are never transformed.
    public static func preview(
        pattern: String?, templateName: String, date: Date = Date(),
        timeZone: TimeZone = .current
    ) throws -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        formatter.dateFormat = "HH-mm"
        let time = formatter.string(from: date)
        let template = stemAndExtension(templateName).stem
        var name = pattern ?? day
        if pattern != nil {
            try validateVariables(name)
            name = name.replacingOccurrences(of: "{{date}}", with: day)
                .replacingOccurrences(of: "{{time}}", with: time)
                .replacingOccurrences(of: "{{template}}", with: template)
        }
        return try literal(name)
    }

    static func literal(_ input: String) throws -> String {
        var name = input
        let lower = name.lowercased()
        if !lower.hasSuffix(".md") && !lower.hasSuffix(".markdown") { name += ".md" }
        try NotebookName.validate(name)
        guard !stemAndExtension(name).stem.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw NotebookName.Error.empty
        }
        return name
    }

    static func validateVariables(_ pattern: String) throws {
        var literal = pattern
        for token in ["{{date}}", "{{time}}", "{{template}}"] {
            literal = literal.replacingOccurrences(of: token, with: "")
        }
        if literal.contains("{{") || literal.contains("}}") {
            throw NotebookTemplateError.unsupportedVariable(literal)
        }
    }

    static func unique(_ name: String, existing: [String]) -> String {
        let occupied = Set(existing.map(NotebookName.collisionKey))
        if !occupied.contains(NotebookName.collisionKey(name)) { return name }
        let parts = stemAndExtension(name)
        var number = 2
        while true {
            let suffix = " (\(number))" + parts.ext
            var stem = parts.stem
            while stem.utf8.count + suffix.utf8.count > 255 { stem.removeLast() }
            let candidate = stem + suffix
            if !occupied.contains(NotebookName.collisionKey(candidate)) { return candidate }
            number += 1
        }
    }

    private static func stemAndExtension(_ name: String) -> (stem: String, ext: String) {
        let lower = name.lowercased()
        let count = lower.hasSuffix(".markdown") ? 9 : lower.hasSuffix(".md") ? 3 : 0
        return (String(name.dropLast(count)), String(name.suffix(count)))
    }
}

struct NotebookTemplateMetadata {
    var sources: Set<UUID> = []
    var settings: [UUID: NotebookTemplateSettings] = [:]

    func projection(_ placements: [NotebookPlacement])
        -> (sources: [NotebookTemplateSource], templates: [NotebookTemplate]) {
        guard !sources.isEmpty else { return ([], []) }
        let active = placements.filter { !$0.isInTrash && !$0.item.isPermanentlyDeleted }
        let byID = Dictionary(uniqueKeysWithValues: active.map { ($0.item.id, $0) })
        func ancestry(_ placement: NotebookPlacement) -> [UUID] {
            var result: [UUID] = []
            var parent = placement.parentID
            var seen: Set<UUID> = [placement.item.id]
            while let id = parent, seen.insert(id).inserted, let folder = byID[id] {
                result.append(id)
                parent = folder.parentID
            }
            return result
        }
        func path(_ placement: NotebookPlacement) -> String {
            let parents = ancestry(placement).reversed().compactMap { byID[$0]?.displayName }
            return (parents + [placement.displayName]).joined(separator: "/")
        }
        let sourceRows = active.filter { sources.contains($0.item.id) }.map {
            NotebookTemplateSource(id: $0.item.id, kind: $0.item.kind,
                                   name: $0.displayName, path: path($0))
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let templates = active.compactMap { placement -> NotebookTemplate? in
            guard placement.item.kind == .note else { return nil }
            let registeredParents = ancestry(placement).filter { sources.contains($0) }
            let id = placement.item.id
            guard sources.contains(id) || !registeredParents.isEmpty else { return nil }
            let raw = settings[id] ?? NotebookTemplateSettings()
            var effective = raw
            for parent in registeredParents {
                let inherited = settings[parent] ?? NotebookTemplateSettings()
                if effective.destination == .inherit { effective.destination = inherited.destination }
                if effective.filenamePattern == nil { effective.filenamePattern = inherited.filenamePattern }
            }
            return NotebookTemplate(id: id, name: placement.displayName, path: path(placement),
                                    inheritedFromID: registeredParents.first,
                                    settings: raw, effectiveSettings: effective)
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return (sourceRows, templates)
    }
}
