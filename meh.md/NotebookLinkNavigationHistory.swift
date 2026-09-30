import Foundation
import Observation

/// A bounded, in-memory back/forward history for link-driven note visits.
@MainActor
@Observable
public final class NotebookLinkNavigationHistory {
    public struct Visit: Equatable, Sendable {
        public let noteID: UUID
        public let position: Data?

        public init(noteID: UUID, position: Data? = nil) {
            self.noteID = noteID
            self.position = position
        }
    }

    @ObservationIgnored public let limit: Int
    private var backStack: [Visit] = []
    private var forwardStack: [Visit] = []

    public init(limit: Int = 100) {
        self.limit = max(1, limit)
    }

    public var backTarget: Visit? { backStack.last }
    public var forwardTarget: Visit? { forwardStack.last }

    /// Native Back menus can return through several link visits at once.
    public func backTarget(steps: Int) -> Visit? {
        guard steps > 0, steps <= backStack.count else { return nil }
        return backStack[backStack.count - steps]
    }

    @discardableResult
    public func commitBack(current: Visit, steps: Int) -> Visit? {
        guard backTarget(steps: steps) != nil else { return nil }
        var visit = current
        for _ in 0..<steps {
            guard let destination = commitBack(current: visit) else { return nil }
            visit = destination
        }
        return visit
    }

    /// Records the current visit when a new link destination has opened.
    public func recordDeparture(_ visit: Visit) {
        backStack.append(visit)
        trim(&backStack)
        forwardStack.removeAll(keepingCapacity: true)
    }

    /// Commits a back navigation after the destination has opened successfully.
    @discardableResult
    public func commitBack(current: Visit) -> Visit? {
        guard let destination = backStack.popLast() else { return nil }
        forwardStack.append(current)
        trim(&forwardStack)
        return destination
    }

    /// Commits a forward navigation after the destination has opened successfully.
    @discardableResult
    public func commitForward(current: Visit) -> Visit? {
        guard let destination = forwardStack.popLast() else { return nil }
        backStack.append(current)
        trim(&backStack)
        return destination
    }

    public func clear() {
        backStack.removeAll(keepingCapacity: false)
        forwardStack.removeAll(keepingCapacity: false)
    }

    private func trim(_ stack: inout [Visit]) {
        let excess = stack.count - limit
        if excess > 0 {
            stack.removeFirst(excess)
        }
    }
}
