import Foundation

/// A portable Markdown tree. Selection includes descendants and keeps ancestors.
public enum NotebookMarkdownExport {
    public static func makeWrapper(
        placements: [NotebookPlacement], notes: [NoteSnapshot],
        selectedIDs: Set<UUID>
    ) throws -> FileWrapper {
        let active = placements.filter { !$0.isInTrash }
        let children = Dictionary(grouping: active, by: \.parentID)
        let snapshots = Dictionary(grouping: notes, by: \.noteID)
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
                    wrapper = FileWrapper(regularFileWithContents: Data(try document.text.utf8))
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
        return try build(nil, inherited: false)
    }
}
