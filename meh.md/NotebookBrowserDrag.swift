import Foundation
import Observation
import NoteCore

/// A local drag captures identity and ancestry, never note contents or paths.
struct NotebookBrowserDrag {
    let token = UUID()
    let notebookID: UUID
    let sources: [NotebookBrowserPlacementExpectation]

    var itemIDs: [UUID] { sources.map(\.itemID) }
}

struct NotebookBrowserDropTarget: Equatable {
    enum Position: Equatable { case before, after, into, root }
    let rowID: UUID?
    let position: Position
    let parentID: UUID?
    let beforeID: UUID?
}

enum NotebookBrowserDragPlacement {
    static func target(
        rowID: UUID?, position: NotebookBrowserDropTarget.Position,
        drag: NotebookBrowserDrag, placements: [NotebookPlacement]
    ) -> NotebookBrowserDropTarget? {
        let byID = Dictionary(uniqueKeysWithValues: placements.map { ($0.item.id, $0) })
        let sources = Set(drag.itemIDs)
        guard !sources.isEmpty, sources.count == drag.sources.count,
              drag.sources.allSatisfy({ expected in
                  guard let current = byID[expected.itemID] else { return false }
                  return !current.isInTrash && !current.item.isPermanentlyDeleted
                      && !current.issues.contains(.concurrentMove)
                      && current.item.parentID == expected.parentID
              }) else { return nil }

        let parentID: UUID?
        let beforeID: UUID?
        if position == .root {
            parentID = nil
            beforeID = nil
        } else {
            guard let rowID, let row = byID[rowID], !row.isInTrash,
                  !sources.contains(rowID) else { return nil }
            if position == .into {
                guard row.item.kind == .folder else { return nil }
                parentID = rowID
                beforeID = nil
            } else {
                // Recovered roots require an explicit repair move first.
                guard row.parentID == row.item.parentID else { return nil }
                parentID = row.parentID
                let siblings = NotebookOrdering.orderedChildren(
                    placements, parentID: parentID, inTrash: false
                ).filter { $0.parentID == $0.item.parentID }.map(\.item.id)
                guard let index = siblings.firstIndex(of: rowID) else { return nil }
                beforeID = position == .before ? rowID
                    : siblings.dropFirst(index + 1).first { !sources.contains($0) }
            }
        }
        guard allowsDestination(parentID, excluding: sources, byID: byID)
        else { return nil }
        return NotebookBrowserDropTarget(
            rowID: rowID, position: position, parentID: parentID, beforeID: beforeID
        )
    }

    /// Display recovery must not hide ancestry that a durable move rejects.
    static func allowsDestination(
        _ parentID: UUID?, excluding sources: Set<UUID>,
        byID: [UUID: NotebookPlacement]
    ) -> Bool {
        var ancestor = parentID
        var visited = Set<UUID>()
        while let id = ancestor {
            guard !sources.contains(id), visited.insert(id).inserted,
                  let folder = byID[id], folder.item.kind == .folder,
                  !folder.isInTrash, !folder.item.isTrashed,
                  !folder.item.isPermanentlyDeleted,
                  folder.parentID == folder.item.parentID
            else { return false }
            ancestor = folder.item.parentID
        }
        return true
    }
}

/// Item-provider file representations expire as soon as their callback returns.
/// Copy while the callback owns access; the scanner later validates each item.
enum NotebookBrowserFileStaging {
    // Provider and file-coordination callbacks run outside the UI actor.
    nonisolated static func copy(
        _ source: URL, into root: URL, preferredName: String? = nil
    ) throws -> URL {
        guard source.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        var name = preferredName ?? source.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let directory = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        do {
            let readAndCopy: (URL) throws -> URL = { coordinatedURL in
                if preferredName != nil, (name as NSString).pathExtension.isEmpty,
                   !source.pathExtension.isEmpty,
                   try coordinatedURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true {
                    name += "." + source.pathExtension
                }
                let copy = directory.appendingPathComponent(name)
                try FileManager.default.copyItem(at: coordinatedURL, to: copy)
                return copy
            }
            #if canImport(Darwin)
            var coordinationError: NSError?
            var result: Result<URL, Error>?
            NSFileCoordinator().coordinate(
                readingItemAt: source, options: [], error: &coordinationError
            ) { coordinatedURL in
                result = Result { try readAndCopy(coordinatedURL) }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw CocoaError(.fileReadUnknown) }
            return try result.get()
            #else
            return try readAndCopy(source)
            #endif
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

@MainActor @Observable
final class NotebookBrowserDropLifetime {
    private(set) var generation = UUID()
    private(set) var isVisible = true

    func appear() { isVisible = true }
    func disappear() { isVisible = false; generation = UUID() }
    func accepts(_ expected: UUID) -> Bool { isVisible && generation == expected }
}
