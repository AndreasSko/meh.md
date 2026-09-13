#if DEBUG
import NoteCore

/// Opt-in fault injection for physical-device persistence and merge checks.
/// Retains the real transport's scope but never contacts the remote store.
struct UnavailableDevelopmentTransport: SyncTransport {
    let scope: String

    func bootstrap(proposing record: SyncRecord) async throws -> SyncRecord {
        throw SyncError.unavailable("Simulated network outage")
    }

    func publish(_ record: SyncRecord) async throws {
        throw SyncError.unavailable("Simulated network outage")
    }

    func fetch(after cursor: String?) async throws -> SyncPage {
        throw SyncError.unavailable("Simulated network outage")
    }
}
#endif
