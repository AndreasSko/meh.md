import Foundation

/// The delegate's asynchronous batch path. Eligibility is checked after each
/// suspension so a halt never publishes work read before the halt occurred.
/// Assets are leased while the batch is built, only for the records it
/// includes; `leased` reports them so a late halt can release them.
struct CloudKitOutgoingBatchPreparer {
    static func assemble<Record: Sendable, Batch: Sendable>(
        allowed: @escaping @Sendable () async -> Bool,
        readOutbox: @escaping @Sendable () async -> [String: SyncRecord],
        stage: @escaping @Sendable ([String: SyncRecord]) async throws
            -> [String: Record],
        construct: @escaping @Sendable ([String: Record]) async -> Batch?,
        leased: @escaping @Sendable (Batch) -> Set<String>,
        release: @escaping @Sendable (Set<String>) async -> Void
    ) async throws -> (batch: Batch, leasedIDs: Set<String>)? {
        guard await allowed() else { return nil }
        let outbox = await readOutbox()
        guard await allowed() else { return nil }
        let records = try await stage(outbox)
        guard await allowed() else { return nil }
        guard let batch = await construct(records) else { return nil }
        let ids = leased(batch)
        guard await allowed() else {
            await release(ids)
            return nil
        }
        return (batch, ids)
    }
}
