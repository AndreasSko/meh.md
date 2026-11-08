import Foundation

/// Scene-local browser selection, independent from the open editor note.
nonisolated struct NotebookBrowserSelection: Equatable, Sendable {
    private(set) var selectedIDs: Set<UUID> = []
    /// Where a Shift-click range starts: the row last clicked on its own or
    /// with Command.
    var anchorID: UUID?

    enum Click: Sendable { case plain, command, shift }

    var isEmpty: Bool { selectedIDs.isEmpty }
    var count: Int { selectedIDs.count }

    func contains(_ id: UUID) -> Bool {
        selectedIDs.contains(id)
    }

    mutating func selectOnly(_ id: UUID) {
        selectedIDs = [id]
        anchorID = id
    }

    mutating func toggle(_ id: UUID) {
        if !selectedIDs.insert(id).inserted {
            selectedIDs.remove(id)
        }
        anchorID = id
    }

    /// Adds every row between the anchor and `id` in the caller's display
    /// order. Without a visible anchor, selects only `id`.
    mutating func extend(to id: UUID, in displayOrder: [UUID]) {
        guard anchorID.flatMap(displayOrder.firstIndex(of:)) != nil else {
            selectOnly(id)
            return
        }
        selectedIDs.formUnion(range(to: id, in: displayOrder))
    }

    private func range(to id: UUID, in displayOrder: [UUID]) -> Set<UUID> {
        guard let anchorID,
              let start = displayOrder.firstIndex(of: anchorID),
              let end = displayOrder.firstIndex(of: id) else { return [id] }
        return Set(displayOrder[min(start, end)...max(start, end)])
    }

    /// Applies a pointer click on `id`. iPadOS List reports every click as
    /// a new single selection, so only a plain click keeps its proposal.
    /// Returns false, changing nothing, when the list's proposal can't come
    /// from a click on `id`, such as an arrow key moving to another row.
    ///
    /// With nothing selected, the open note's row looks selected, so a
    /// Command- or Shift-click starts from it, as in Finder.
    @discardableResult
    mutating func click(
        _ id: UUID, _ click: Click, proposed: Set<UUID>, in displayOrder: [UUID],
        openNoteID: UUID? = nil
    ) -> Bool {
        var start = self
        if click != .plain, isEmpty, let openNoteID, displayOrder.contains(openNoteID) {
            start.selectOnly(openNoteID)
        }
        // For Shift, the list proposes some of the rows up to the anchor.
        let clicked = click == .shift ? start.range(to: id, in: displayOrder) : [id]
        guard proposed.isSubset(of: clicked)
            || proposed == selectedIDs.subtracting([id]) else { return false }
        self = start
        switch click {
        case .plain:
            selectedIDs = proposed
            anchorID = id
        case .command:
            toggle(id)
        case .shift:
            extend(to: id, in: displayOrder)
        }
        return true
    }

    /// A plain click opens its row. It leaves a Command or Shift
    /// selection, as on the Mac, and starts the range of a later
    /// Shift-click.
    mutating func activate(_ id: UUID) {
        if count > 1 {
            selectOnly(id)
        } else {
            anchorID = id
        }
    }

    /// Opening another note drops a single row left selected from the
    /// previous one. It would keep looking current, and arrow keys would
    /// start from it.
    mutating func noteOpened(_ id: UUID) {
        if count == 1, !contains(id) { clear() }
    }

    /// Works like Finder: a click on empty space first drops a selection of
    /// other rows. Returns true once only the open note is left, when the
    /// click should close that note.
    mutating func clickEmptySpace(openNoteID: UUID?) -> Bool {
        let openNote: Set<UUID> = openNoteID.map { [$0] } ?? []
        let clearsOthers = !isEmpty && selectedIDs != openNote
        clear()
        return !clearsOthers && openNoteID != nil
    }

    enum Highlight: Equatable, Sendable { case none, open, selected }

    /// How a row looks. The open note keeps its own fill while it isn't
    /// part of the selection, however it was opened.
    func highlight(of id: UUID, openNoteID: UUID?) -> Highlight {
        if contains(id) { return .selected }
        return id == openNoteID ? .open : .none
    }

    mutating func selectAll(_ activeIDs: [UUID]) {
        selectedIDs = Set(activeIDs)
        anchorID = nil
    }

    mutating func prune(to activeIDs: Set<UUID>) {
        selectedIDs.formIntersection(activeIDs)
        if let anchorID, !activeIDs.contains(anchorID) { self.anchorID = nil }
    }

    mutating func clear() {
        selectedIDs.removeAll()
        anchorID = nil
    }

    /// Returns selected IDs in the caller's current tree or sidebar order.
    func orderedIDs(in displayOrder: [UUID]) -> [UUID] {
        displayOrder.filter(selectedIDs.contains)
    }
}
