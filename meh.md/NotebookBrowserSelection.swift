import Foundation

/// Scene-local browser selection, independent from the open editor note.
nonisolated struct NotebookBrowserSelection: Equatable, Sendable {
    private(set) var selectedIDs: Set<UUID> = []

    var isEmpty: Bool { selectedIDs.isEmpty }
    var count: Int { selectedIDs.count }

    func contains(_ id: UUID) -> Bool {
        selectedIDs.contains(id)
    }

    mutating func selectOnly(_ id: UUID) {
        selectedIDs = [id]
    }

    mutating func toggle(_ id: UUID) {
        if !selectedIDs.insert(id).inserted {
            selectedIDs.remove(id)
        }
    }

    mutating func selectAll(_ activeIDs: [UUID]) {
        selectedIDs = Set(activeIDs)
    }

    mutating func prune(to activeIDs: Set<UUID>) {
        selectedIDs.formIntersection(activeIDs)
    }

    mutating func clear() {
        selectedIDs.removeAll()
    }

    /// Returns selected IDs in the caller's current tree or sidebar order.
    func orderedIDs(in displayOrder: [UUID]) -> [UUID] {
        displayOrder.filter(selectedIDs.contains)
    }
}
