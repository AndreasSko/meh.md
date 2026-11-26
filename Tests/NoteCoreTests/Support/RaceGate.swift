import Foundation

@testable import NoteCore

/// A one-shot rendezvous. Timeouts bound failures, never arrange the race.
actor RaceGate {
    private var reached = false
    private var released = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var parked: [UUID: CheckedContinuation<Void, Error>] = [:]

    func waitUntilPaused() async throws {
        if reached { return }
        try await wait(arrival: true)
    }

    func pause() async throws {
        reached = true
        let arrivals = waiters.values
        waiters.removeAll()
        for arrival in arrivals { arrival.resume() }
        if !released { try await wait(arrival: false) }
    }

    func release() {
        released = true
        let continuations = parked.values
        parked.removeAll()
        for continuation in continuations { continuation.resume() }
    }

    private func wait(arrival: Bool) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                if arrival { waiters[id] = continuation }
                else { parked[id] = continuation }
                Task {
                    try? await Task.sleep(for: .seconds(15))
                    self.finish(id, arrival: arrival,
                                error: SyncError.unavailable("Race gate timed out"))
                }
            }
        } onCancel: {
            Task { await self.finish(id, arrival: arrival,
                                     error: CancellationError()) }
        }
    }

    private func finish(_ id: UUID, arrival: Bool, error: Error) {
        let continuation = arrival
            ? waiters.removeValue(forKey: id)
            : parked.removeValue(forKey: id)
        continuation?.resume(throwing: error)
    }
}
