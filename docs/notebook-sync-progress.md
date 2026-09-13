# Notebook sync progress and batching

The bottom status area appears during transfers, slow/manual checks, waiting,
or errors. It disappears when synchronization is idle. The previous Markdown
copy path label is removed; copy failures remain visible. The toolbar's Sync
Details action remains available for manual sync and the latest exchange
result even when the bottom area is hidden.

## What progress means

- Upload progress counts current saved note revisions acknowledged by the
  service in this pass, not bytes or notes delivered to every other device.
  Acknowledged heads are checkpointed before the displayed count advances.
- Folder metadata is a separate catalog document and has its own final phase.
- Receiving counts valid changes durably applied from fetched pages. There is
  no invented download percentage when the service has not supplied a total.
- Partial failure keeps the acknowledged portion durable. Details retain those
  counts and the error. A retry starts a new pass with reset counters and
  reconstructs remaining uploads from the saved acknowledgements.
- Edits made during upload remain pending when they differ from the captured
  revision. A queued permanently deleted note is removed from the target count,
  never reported as uploaded.
- A received revision is treated as already remote only when its exact heads
  match the persisted local result. Locally merged changes still need upload.
- A known CloudKit cooldown is shown as a retry deadline, including persisted
  availability cooldowns encountered before transport construction completes.

Progress is transient coordinator state, separate from Automerge content and
catalog history. Durable progress continues to use document IDs, acknowledged
heads, and replay cursors. No note format or cloud zone migration is required.

## Work reduction

The notebook sends at most 50 pending notes per batch and sends catalog
metadata after the note batches are acknowledged. CloudKit validates the batch,
checks the account once, stages its assets, records one outbox update, and
requests one scoped engine send. Confirmed records update durable transport
state before acknowledgements reach the coordinator. Unconfirmed uploads stay
in the outbox for retry. Legacy and test transports retain a sequential batch
fallback with partial-acknowledgement reporting.

Buffered inbox pages drain without a new CloudKit fetch per page. Reaching the
buffer tip still performs a fresh fetch in the same exchange, so continuous
local editing cannot indefinitely hide changes from another device.

Foreground activation, saved edits, and manual sync still request exchanges.
Quiet foreground checks run every 30 seconds instead of every three seconds;
brief automatic checks do not flash the status area. Slow checks become visible
after two seconds. Full engine-driven background delivery, battery
measurements, and broader cloud scale acceptance remain separate milestone
work.

## Verification boundaries

Core tests exercise batch boundaries, partial acknowledgements, durable retry,
concurrent edits and queued deletions, receiving progress, and reset counters.
A real HTTP test pauses a 50-note batch, edits one captured note, and verifies
that the next pass publishes the new revision to another replica. An unchanged
exchange sends no new batches.

A delayed loopback service and 120 synthetic notes were used to inspect the Mac
upload indicator, folder phase, sync details, and disappearance on completion.
This establishes UI behavior without timing claims about the owner's iCloud
library. Existing saved notes and pending uploads can continue on the new
build.
