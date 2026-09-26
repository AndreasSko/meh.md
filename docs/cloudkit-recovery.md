# CloudKit halt and recovery

An engine may still finish an operation after cancellation returns. Sync
therefore blocks new outgoing batches with application-owned health checks,
including a final synchronous check before returning a prepared batch.
Failures observed by the durable store are also visible to that final check.

The store rejects further writes after a failed durable write. Retirement
waits for the store actor to revoke its writer before the workspace opens a
replacement. Work already executing in the store can finish before retirement
returns; callbacks arriving afterward cannot write replacement state.

Manual Sync, or Retry during initial notebook setup, can reconstruct a halted
transport after a recognized storage-space or write-permission failure. The
workspace serializes recovery with its normal exchanges. It retires the old
transport, replaces its coordinator and activity subscription, checks the
original account scope and notebook identity, and reloads durable state.
Pending outbox saves are requeued even if absent from the engine checkpoint.
An unsuccessful reconstruction can be retried without clearing the original
failure or changing the expected account scope.

Corrupt state, account changes, invalid records, and unexplained remote
deletion do not authorize reconstruction. Provisional note deletions can still
be reconciled by a later catalog marker. Recovery never resets local or cloud
data, and an uncertain upload result remains pending until acknowledged.

The existing sync details show a cause and a next step. Automatic retry is
promised only when the workspace has scheduled it. Technical failure codes
remain in the event log; messages do not claim unsaved edits are durable.

## Verification

The deterministic suites cover halt transitions at batch suspension points,
asset lease release, retired writers, injected inbox/outbox/checkpoint write
failures, replayed acknowledgements, account scope rejection, failed and
repeated reconstruction, local-edit preservation, startup recovery, and stale
activity hints. The app-model tests use a shared fictional remote store.

The iPhone UI check uses an isolated loopback workspace and simulated network
unavailability. It verifies explanation layout and the retry/close controls.
These simulations do not establish actual account-switch ordering, physical
device background delivery, or sudden-power-loss behavior in CKSyncEngine.
