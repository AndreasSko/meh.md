# Milestone 2 synchronization verification

Date: 2026-09-13.
Status: local synchronization verified; iCloud/device acceptance remains open.

## Delivered behavior

- A shared coordinator exchanges immutable Automerge snapshots through a
  pluggable remote record-store interface.
- In-process replicas, a persistent localhost HTTP service, and a CloudKit
  adapter use the same document/save boundary.
- A durable bootstrap proposal prevents uncertain first responses from
  creating another identity. Existing independent notes are preserved.
- Saved edits remain discoverable after restart. Received changes are saved
  before cursor advancement. Restoring a previous local file triggers replay
  when its history no longer contains the saved sync checkpoint.
- Native edits use the revision actually displayed. Remote changes received
  during composition are merged, and failed native commits retain their
  visible unsaved text.
- Remote replacement clears native undo/redo history. Subsequent local undo
  works. Advanced undo across remote changes is intentionally deferred.
- Local-save, Markdown-copy, and sync status are separate. The app exposes
  an explicit Sync Now action. Debug foreground polling runs every 3 seconds
  when enabled; this is not evidence of CloudKit background delivery timing.
- Local test workspaces have separate internal storage and Markdown copies.
  Ordinary milestone 1 notes are not used by the simulator test runner.

## Automated evidence

- `swift test --disable-sandbox`: 73 core and 22 native editor tests passed.
  These include 15 coordinator tests, 7 CloudKit state tests, 4 local transport
  tests, and 8 remote-editor tests.
- Coordinator checks cover three independent persisted replicas, offline
  edits, process-owner reconstruction, reordered/duplicate records, lost
  upload and bootstrap responses, failed download saves, current-file
  corruption followed by explicit previous-file recovery, account-scope
  changes, invalid cursors, and stale editor revisions.
- Same-position concurrent insertion converges with both insertions retained.
  Their relative order is determined by Automerge; do not assume which writer
  appears first. Separate-position edits retain their expected content.
- CloudKit tests cover durable inbox/account binding, pagination and replay,
  a changed inbox generation, corrupt state, unsafe record IDs, and rejection
  of engine-state advancement after a failed inbox commit. They do not contact
  an iCloud account.
- Python service suite: 7 tests passed, including live loopback HTTP,
  first-writer bootstrap, idempotent publish, restart from persisted state,
  scoped cursors, byte-bounded pagination, and the process lock.
- macOS app build and iOS Simulator build-for-testing passed. Xcode emitted
  only the standard skipped-AppIntents-metadata warning for the app build.

## Actual simulator checks

The clean run used newly isolated app workspaces on iPhone 17 and iPad Pro
11-inch (M5), both running iOS 27. It passed all three UI-test phases:

1. Type the Unicode iPhone text, save, upload, terminate, and reopen.
2. Download that text on iPad, append the iPad reply through the native editor,
   save, upload, and update the Markdown copy.
3. Download the reply on the original iPhone, terminate, reopen, and verify
   the final text and save/copy status.

An independent file read confirmed that both Markdown copies matched all 63
expected UTF-8 bytes. The test runner creates a unique workspace for every run;
it does not reset either simulator or modify the ordinary note.

Evidence from the final run is under `/tmp/meh-sync-complete-20260913`: result
bundles, phase logs, and `verification.json`. The workspace was
`ui-7b8e208006d7`. Temporary evidence is useful for inspection but is not a
permanent repository artifact; these notes retain the verified result.

The runner also handles XCTest shutting down a previous simulator destination
before the independent copy check. It boots only the explicitly supplied
device and then reads its existing data; it never erases the simulator.

The localhost service was also killed with SIGKILL after accepted writes and
restarted using its existing data directory. All three records from the prior
workspace remained fetchable. This checks process restart after acknowledged
writes, not interruption at every write instruction or sudden power loss.

## Issues caught and corrected

- Independent review found the lost-bootstrap-response identity problem and
  the stale cursor after local fallback recovery. Both have regression tests.
- An actual iPad run crashed in UIKit's undo manager when undo registration
  was restored after replacing its text storage. External replacement now
  clears the current undo manager after the change without retaining a
  disable/enable pairing across UIKit's internal reset. An unfocused-editor
  regression was added, and the clean simulator handoff run passed.
- CloudKit review found that a failed inbox write must stop subsequent token
  persistence. The adapter is poisoned after that failure until recreated
  from its last durable state.

## Remaining acceptance and limits

- Configure the real CloudKit container, app capabilities, and signing, then
  test signed Mac/iPhone/iPad sync. No live iCloud exchange has been verified.
- Physical-device persistence, iPad hardware-keyboard use, background/push
  delivery, fresh-install/restore behavior, account transitions, quota/errors,
  and measured handoff latency remain open.
- A fresh offline device can retain its independently created note. If a
  different note already exists remotely, sync pauses. Choosing which note
  to adopt while retaining the other still needs a user-facing resolution
  flow before those existing independent device notes can be joined.
- Full-history snapshots and their remote history are retained. Long-note
  transfer cost and long-term storage growth need measurement before daily
  adoption. There is no compaction or remote deletion in this milestone.
- Existing local notes open independently while CloudKit account discovery
  runs. First cloud bootstrap and actual Apple failure timing still require
  signed-device validation.
- The default release app remains local-only. Transport selection is an
  explicit Debug launch configuration, pending the iCloud acceptance work.

Implementation commits: `2bc1779` (shared replication and transports) and
`36dfdfa` (native editor and app integration).

See [the execution plan](milestone-2-plan.md),
[local service instructions](local-sync-service.md), and
[CloudKit setup](cloudkit-sync-setup.md) before continuing.
