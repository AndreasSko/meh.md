# Notebook sync progress and batching

The cloud toolbar button shows sync activity, waiting changes, and paused or
failed synchronization. Open it for transfer progress, the latest exchange
result, and manual sync. Routine sync progress no longer takes space below
the writing screen. Markdown-copy failures, deletion-cleanup errors, and
recovery actions remain visible in the bottom status area.

The button border shows estimated completion of one finite exchange. It uses
fixed phase budgets and known work counts, rather than elapsed time. An initial
wait without measured work uses the syncing cloud icon. Later waits hold the
earned fraction. The status popover groups the bar under "Syncing with iCloud"
and shows the current phase beneath it, followed by available work counts and
elapsed iCloud wait time. This keeps overall progress distinct from the number
of notes sent in the current phase, without spinning the button border.

## What progress means

| Work | Exchange budget |
| --- | --- |
| Check local records and saved history | 0-20% |
| Receive and apply changes | 20-50% |
| Compare outgoing local records | 50-55% |
| Send saved note revisions | 55-78% |
| Send notebook metadata | 78-80% |
| Remove copies of deleted notes | 80-85% |
| Verify and remove redundant snapshots | 85-98% |
| Verify the final local state | 98-100% |

These weights describe completion of planned work, not remaining time. Each
phase starts where the preceding budget ends. Empty phases skip forward;
progress never decreases within a pass. Only successful final verification
can complete the pass. New edits may require another pass, and a failed retry
starts a new attempt with its own counters.

- Local scans count the eligible IDs and catalog already being read. History
  comparisons count existing checkpoints. Reporting is throttled to about
  100 updates per scan; it adds no discovery scan or CloudKit count query.
- Upload progress counts current saved note revisions acknowledged by the
  service in this pass, not bytes or notes delivered to every other device.
  Acknowledged heads are checkpointed before the displayed count advances.
- Folder metadata is a separate catalog document and has its own final phase.
- Receiving counts valid changes applied from fetched pages. CloudKit provides
  batch contents and whether more changes remain, but no overall change total.
  Non-final pages display batch counts without advancing the receiving budget.
  The final page can advance that budget, with its end reserved for the durable
  cursor checkpoint. Network waits never advance because time has passed.
- Cleanup counts existing survivor checks and planned deletion work. Confirmed
  deletions are logged separately from absent records and rejected plans.
- Partial failure keeps the acknowledged portion durable. Details retain those
  counts and the error. A retry starts a new pass with reset counters and
  reconstructs remaining uploads from the saved acknowledgements.
- Edits made during upload remain pending when they differ from the captured
  revision. A queued permanently deleted note is removed from the notes-to-send
  count and resolves its original work unit; it is never reported as uploaded.
  The weighted work denominator remains fixed for that attempt.
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

Actual scene phases (active, inactive, background) are logged separately from
refresh triggers, with the number of active windows. iOS background execution
leases log acquisition, expiration and release. Returning to an unfinished
exchange records its phase and monotonic elapsed time. These events establish
requested background execution, not continuous execution while iOS suspends
the app; there is no callback at the instant the process becomes suspended.

Phase and scan boundaries, fetch return before application, bootstrap, cleanup
work counts, publish-lease wait completion, and CloudKit request outcomes help
locate delays. Request durations exclude retry cooldown, which has separate
wait events. New duration measurements use a monotonic clock. No per-document
scan events are written, and the existing 500-event limit remains in place.

Exports include app version/build and OS version, timestamps, event names,
counts, and sanitized error categories/codes. They exclude note text, titles,
paths, document IDs, revision hashes, account identifiers, and raw error
descriptions. Nothing is sent automatically; sharing is initiated by the user.

For an unexpected upload, copy the log soon after the event on each affected
device. A completed batch followed by a failed pass and another smaller batch
target identifies a retry. Logs begin with this build and cannot reconstruct
events from earlier builds.
