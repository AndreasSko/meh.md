import Foundation

struct NotebookBrowserReorderRequest: Equatable, Sendable {
    let sources: [UUID]
    let parentID: UUID?
    let before: UUID?
}

enum NotebookBrowserOrdering {
    /// Maps the gap after a visible folder subtree to its last sibling slot.
    static func requestFromVisibleTree(
        sources: [UUID],
        before: UUID?,
        parentID: UUID?,
        siblingIDs: [UUID],
        endAnchor: UUID?
    ) -> NotebookBrowserReorderRequest? {
        guard before != nil || endAnchor == nil else { return nil }
        return request(
            sources: sources,
            before: before == endAnchor ? nil : before,
            parentID: parentID,
            siblingIDs: siblingIDs
        )
    }

    static func request(
        sources: [UUID],
        before: UUID?,
        parentID: UUID?,
        siblingIDs: [UUID]
    ) -> NotebookBrowserReorderRequest? {
        let sourceSet = Set(sources)
        guard !sources.isEmpty,
              sourceSet.count == sources.count,
              sourceSet.isSubset(of: Set(siblingIDs)),
              before.map({ siblingIDs.contains($0) && !sourceSet.contains($0) })
                ?? true
        else { return nil }

        let moving = siblingIDs.filter(sourceSet.contains)
        var result = siblingIDs.filter { !sourceSet.contains($0) }
        if let before, let index = result.firstIndex(of: before) {
            result.insert(contentsOf: moving, at: index)
        } else {
            result.append(contentsOf: moving)
        }
        guard result != siblingIDs else { return nil }
        return NotebookBrowserReorderRequest(
            sources: moving,
            parentID: parentID,
            before: before
        )
    }

    static func moveUpRequest(
        id: UUID,
        parentID: UUID?,
        siblingIDs: [UUID]
    ) -> NotebookBrowserReorderRequest? {
        guard let index = siblingIDs.firstIndex(of: id), index > 0 else {
            return nil
        }
        return request(
            sources: [id],
            before: siblingIDs[index - 1],
            parentID: parentID,
            siblingIDs: siblingIDs
        )
    }

    static func moveDownRequest(
        id: UUID,
        parentID: UUID?,
        siblingIDs: [UUID]
    ) -> NotebookBrowserReorderRequest? {
        guard let index = siblingIDs.firstIndex(of: id),
              index + 1 < siblingIDs.count
        else { return nil }
        let before = index + 2 < siblingIDs.count ? siblingIDs[index + 2] : nil
        return request(
            sources: [id],
            before: before,
            parentID: parentID,
            siblingIDs: siblingIDs
        )
    }
}
