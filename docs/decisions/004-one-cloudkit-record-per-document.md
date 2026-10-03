# ADR 004: Keep one CloudKit record per document

- Status: Proposed
- Date: 2026-09-29

## Context

- Today every uploaded version of a note or of the catalog becomes a new
  CloudKit record. Its name is a hash of the bytes, and each record holds the
  document's full Automerge history. Old versions are only deleted when a
  note is permanently deleted.
- The local CloudKit state keeps every received version in one JSON file and
  rewrites it on each engine state update. On one development Mac, 0.68 MB of
  notes had produced a 13 MB state file: 461 stored versions for 255
  documents, one note with 83 versions and the catalog with 74.
- So iCloud storage, first-sync downloads and local write cost all grow with
  every edit session, not with the size of the notebook. Quota errors are not
  retried, so sync would eventually stop.
- The inbox, outbox, paging cursor and acknowledgement bookkeeping exist
  mainly to manage these immutable versions (see the code review, P0-1).

## Decision

We will store each document in one CloudKit record with a fixed name and
merge on conflict.

- Record names: `note-<note UUID>` for note bodies and `catalog` for the
  notebook catalog. The asset is the document's current Automerge save.
- Sending: the record provider reads the current local file. We keep each
  record's last known system fields locally, so a save normally carries its
  change tag and does not conflict.
- Conflict: on `serverRecordChanged`, merge the attached server record into
  the local document, persist it, and queue the save again, as in Apple's
  [CKSyncEngine sample](https://github.com/apple/sample-cloudkit-sync-engine).
  An Automerge merge never loses changes, so saving after a merge is safe.
- Receiving: merge each fetched asset into the local file and persist it
  before the next engine state update is persisted. A crash leads to a
  refetch; merging the same bytes again changes nothing.
- Joining: the first device to save `catalog` defines the notebook. A device
  that loses the race receives the server catalog through the conflict and
  adopts it; a catalog for a different notebook stays an identity conflict.
- Deletion: permanent deletion deletes the note's record. The catalog marker
  keeps preventing resurrection. Other record deletions still halt sync.

## Consequences

- iCloud and local sync state hold one copy per document. A new device
  downloads the notebook once, not its whole upload history.
- Most of the inbox, outbox, cursor and acknowledgement code in
  `CloudKitSyncTransport` and `NotebookSyncCoordinator` can go.
- Each document's own Automerge history still grows. Compacting history is a
  separate decision.
- The `SyncTransport` protocol is built around immutable versions and
  cursors. The in-memory and localhost HTTP transports must follow the new
  model or be retired; the CloudKit fake in `NoteCoreTests` should become the
  main test backend.
- Migration uses a new zone, `meh-md-notebook-v3`. Each updated device
  uploads what it has and merges on conflict; after one last fetch of the old
  zone, the old zone can be deleted. Devices on older builds stop seeing new
  changes, which is acceptable while the app is on TestFlight.

## Alternatives considered

- Keep versioned records but delete superseded ones: bounds cloud storage,
  but keeps the inbox, cursor and acknowledgement machinery and its cost.
- Upload Automerge change chunks instead of full saves: smaller uploads, but
  needs ordering and compaction on top of CloudKit. It can follow later if
  full saves become too large.
- `NSPersistentCloudKitContainer` or iCloud Drive files: neither can merge
  Automerge documents, so concurrent edits would conflict or be lost.

## Open questions

- Confirm with a spike that the join race behaves as described on real
  CloudKit, including two fresh devices joining at the same time.
- Decide how long the new build reads the old zone before deleting it.
