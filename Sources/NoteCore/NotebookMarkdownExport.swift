import Foundation

/// A portable Markdown tree. Selection includes descendants and keeps ancestors,
/// except a single imported root whose contents form the exported root. Resolved
/// note links are translated only when their exported destinations change.
public enum NotebookMarkdownExport {
    /// Supply live link descriptors to include historical location resolution.
    /// Backups set `preserveSource` to retain the exact source text and tree.
    public static func makeWrapper(
        placements: [NotebookPlacement], notes: [NoteSnapshot],
        selectedIDs: Set<UUID>, originalLinkNotes: [NotebookLinkNote]? = nil,
        preserveSource: Bool = false
    ) throws -> FileWrapper {
        let active = placements.filter { !$0.isInTrash }
        var children = Dictionary(grouping: active, by: \.parentID)
        for parent in children.keys {
            children[parent]!.sort { $0.item.id.uuidString < $1.item.id.uuidString }
        }
        let snapshots = Dictionary(grouping: notes, by: \.noteID)
        let byID = Dictionary(uniqueKeysWithValues: active.map { ($0.item.id, $0) })
        func folderPath(_ parent: UUID?) -> String {
            guard let parent, let placement = byID[parent] else { return "" }
            let ancestor = folderPath(placement.parentID)
            return ancestor.isEmpty ? placement.displayName
                : ancestor + "/" + placement.displayName
        }
        let originalNotes = originalLinkNotes ?? active.filter { $0.item.kind == .note }.map { placement in
            let rootID = placement.item.importRootID
            return NotebookLinkNote(
                id: placement.item.id, name: placement.displayName,
                path: folderPath(placement.parentID), rootID: rootID,
                rootPath: rootID.map { folderPath($0) })
        }
        // An imported vault can be exported as a standalone Markdown tree.
        // Other selections keep ancestors, as in the existing export contract.
        let selectedRoot = !preserveSource && selectedIDs.count == 1 ? selectedIDs.first.flatMap { byID[$0] } : nil
        let exportRoot = selectedRoot.flatMap { placement in
            placement.item.kind == .folder && placement.item.importRootID == placement.item.id
                ? placement.item.id : nil
        }
        var exportedNotes: [NotebookLinkNote] = []
        var exportedFiles: [UUID: FileWrapper] = [:]
        var exportedTexts: [UUID: String] = [:]
        func build(_ parent: UUID?, inherited: Bool) throws -> FileWrapper {
            var files: [String: FileWrapper] = [:]
            var used = Set<String>()
            for placement in children[parent] ?? [] {
                let id = placement.item.id
                let selected = inherited || selectedIDs.contains(id)
                let wrapper: FileWrapper
                var name = placement.displayName
                if placement.item.kind == .folder {
                    wrapper = try build(id, inherited: selected)
                    guard selected || !(wrapper.fileWrappers ?? [:]).isEmpty else { continue }
                } else {
                    guard selected else { continue }
                    guard let matches = snapshots[id], matches.count == 1 else {
                        throw NotebookMarkdownPublisherError.missingNote(id)
                    }
                    let document = try NoteDocument(snapshot: matches[0])
                    let text = try document.text
                    wrapper = FileWrapper(regularFileWithContents: Data(text.utf8))
                    exportedFiles[id] = wrapper
                    exportedTexts[id] = text
                    if !name.lowercased().hasSuffix(".md") && !name.lowercased().hasSuffix(".markdown") {
                        name += ".md"
                    }
                }
                let original = name
                var attempt = 0
                while used.contains(NotebookName.collisionKey(name)) || name.utf8.count > 255 {
                    attempt += 1
                    name = NotebookName.collisionName(original, id: id, attempt: attempt)
                }
                try NotebookName.validate(name)
                used.insert(NotebookName.collisionKey(name))
                files[name] = wrapper
            }
            return FileWrapper(directoryWithFileWrappers: files)
        }
        let result = try build(exportRoot, inherited: exportRoot != nil)
        guard !preserveSource else { return result }
        let fileIDs = Dictionary(uniqueKeysWithValues: exportedFiles.map { (ObjectIdentifier($0.value), $0.key) })
        func collect(_ wrapper: FileWrapper, path: String) {
            for (name, child) in wrapper.fileWrappers ?? [:] {
                if child.isDirectory {
                    collect(child, path: path.isEmpty ? name : path + "/" + name)
                } else if let id = fileIDs[ObjectIdentifier(child)] {
                    exportedNotes.append(NotebookLinkNote(id: id, name: name, path: path))
                }
            }
        }
        collect(result, path: "")
        let exportedByID = Dictionary(uniqueKeysWithValues: exportedNotes.map { ($0.id, $0) })
        let originalLookup = NotebookLinkResolver.Lookup(notes: originalNotes)
        let exportedLookup = NotebookLinkResolver.Lookup(notes: exportedNotes)
        var rewrittenTexts: [UUID: String] = [:]
        for source in exportedNotes {
            guard let text = exportedTexts[source.id] else { continue }
            var edits: [(NSRange, String)] = []
            for occurrence in NotebookLinkParser.parse(text) {
                guard case .resolved(let targetID, let fragment) = originalLookup.resolve(
                    occurrence, sourceID: source.id),
                    let target = exportedByID[targetID] else { continue }
                func resolves(_ destination: String) -> Bool {
                    let candidate = NotebookLinkOccurrence(
                        range: occurrence.range, destinationRange: occurrence.destinationRange,
                        destination: destination, label: occurrence.label,
                        kind: occurrence.kind, isEmbed: occurrence.isEmbed)
                    return exportedLookup.resolve(
                        candidate, sourceID: source.id)
                        == .resolved(noteID: targetID, fragment: fragment)
                }
                guard !resolves(occurrence.destination) else { continue }
                let parts = NotebookLinkParser.literalDestinationParts(occurrence.destination)
                let includeExtension = !(NotebookLinkResolver.path(of: occurrence) as NSString)
                    .pathExtension.isEmpty
                var destination = NotebookLinkDestination.make(
                    target: target, source: source, kind: occurrence.kind,
                    fragment: parts.fragment, includeExtension: includeExtension)
                if destination.map(resolves) != true, occurrence.kind == .wiki {
                    // An explicit relative wiki path avoids suffix ambiguities.
                    let relativeSource = NotebookLinkNote(
                        id: source.id, name: source.name, path: source.path, rootID: source.id)
                    destination = NotebookLinkDestination.make(
                        target: target, source: relativeSource, kind: .wiki,
                        fragment: parts.fragment, includeExtension: includeExtension)
                }
                guard let destination, resolves(destination) else { continue }
                edits.append((occurrence.destinationRange, destination))
            }
            let rewritten = NSMutableString(string: text)
            for (range, destination) in edits.sorted(by: { $0.0.location > $1.0.location }) {
                rewritten.replaceCharacters(in: range, with: destination)
            }
            if !edits.isEmpty {
                // Replace only the exported copy; snapshots remain untouched.
                rewrittenTexts[source.id] = rewritten as String
            }
        }
        func rewrittenWrapper(_ wrapper: FileWrapper) -> FileWrapper {
            if let id = fileIDs[ObjectIdentifier(wrapper)], let text = rewrittenTexts[id] {
                return FileWrapper(regularFileWithContents: Data(text.utf8))
            }
            guard wrapper.isDirectory else { return wrapper }
            return FileWrapper(directoryWithFileWrappers:
                (wrapper.fileWrappers ?? [:]).mapValues(rewrittenWrapper))
        }
        return rewrittenWrapper(result)
    }
}
