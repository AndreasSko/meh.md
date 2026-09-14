# Notebook sync progress and batching

The cloud toolbar button shows sync activity, waiting changes, and paused or
failed synchronization. Open it for transfer progress, the latest exchange
result, and manual sync. Routine sync progress no longer takes space below
the writing screen. Markdown-copy failures, deletion-cleanup errors, and
recovery actions remain visible in the bottom status area.

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
Cloud builds now use engine scheduling and change notifications instead of
periodic foreground checks. The loopback test transport still polls every
30 seconds. The cloud button indicates active checks; details describe slow
checks after two seconds. See the
[scheduling contract](notebook-sync-scheduling.md). Physical push delivery and
battery measurements require separate device checks.

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


## Local event diagnostics

Sync Details opens Sync Event Log on Mac and iPhone. Copy Log or Share Log
exports recent events from that device; Clear Log removes that local history.
The log retains the latest 500 events across app launches. It is diagnostic
state only and is not included in Automerge documents, CloudKit records, or
Markdown copies. A log persistence failure does not stop note synchronization.

Events describe refresh triggers, compatibility sync, download pages, saved
checkpoint counts, upload selection reasons, batch acknowledgements, known
cooldowns, errors, and pass outcomes. Counts distinguish notes with no saved
upload acknowledgement from revisions changed since their acknowledgement.
A match with an applied checkpoint is diagnostic evidence only: it is not
proof that the current revision already exists remotely.

Exports include app version/build and OS version, timestamps, event names,
counts, and sanitized error categories/codes. They exclude note text, titles,
paths, document IDs, revision hashes, account identifiers, and raw error
descriptions. Nothing is sent automatically; sharing is initiated by the user.

For an unexpected upload, copy the log soon after the event on each affected
device. A completed batch followed by a failed pass and another smaller batch
target identifies a retry. Logs begin with this build and cannot reconstruct
events from earlier builds.
