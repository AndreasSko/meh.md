# Sync backends

iCloud is the default sync backend, and [S3](s3-sync.md) is a beta. We want
to be able to add others, such as WebDAV, without changing how notes are
merged or how the app schedules sync. This page describes what a backend has
to provide and where it plugs in.

## What a backend stores

Sync does not ask a backend to merge anything. Each note and the notebook
catalog is an Automerge document. A backend stores immutable snapshots of
these documents as `SyncRecord` values, keyed by a hash of their content.
Devices merge on their own, so records may arrive twice, late, or out of
order. See the [notebook sync contract](notebook-sync-contract.md) for the
record format.

A backend implements `SyncTransport` (`Sources/NoteCore/SyncTransport.swift`):

- `bootstrap(proposing:)` stores the first catalog only if none exists yet,
  and otherwise returns the existing one. Every device must get the same seed.
  This is the only write that needs a conditional check on the server.
- `publish(_:)` and `publishBatch(_:)` store records. Returning means the
  record is stored durably. Publishing a stored record again succeeds.
- `fetch(after:)` returns records in pages. The cursor is opaque to everyone
  except the backend, and a fetch after a cursor returns only newer records.
- `scope` names the account and storage location, never a credential. It
  must be the same on every device that shares a notebook.
- `purgeDeletedNotes(_:notebookID:)` removes note bodies after a permanent
  deletion. The default implementation reports that the backend cannot.

Snapshot cleanup, maintenance status, progress handlers, and retry deadlines
have defaults and are optional.

## Optional capabilities

A transport adopts these protocols only when they apply:

- `HaltableSyncTransport` reports when it stopped accepting work, as a
  `SyncHaltStatus`, and lets the app replace it with a fresh instance.
- `ActiveSyncTransport` syncs on its own, for example after a push
  notification. It reports `SyncActivity`, can be asked to check the server
  directly, and exposes its last failure. A backend that only syncs when asked
  does not need it; the app already schedules exchanges on edits, foreground,
  and Sync Now.
- `recoveryEvents()` lists repairs made while opening saved state, for the
  sync event log.

## Errors

Shared sync code does not know any backend's error types. A backend that
throws its own errors adds a `SyncBackendErrors` type and registers it in
`SyncBackends.errors`. It answers, for errors it recognizes, with a stable
event log code, whether to retry, a plain-language explanation, and which
document is too large to upload. `CloudKitSyncErrors` and `S3SyncErrors` are
examples. Network errors from `URLSession` and shared `SyncError` values are
already handled.

A test fails if a NoteCore file outside the CloudKit backend imports
CloudKit, so shared code stays usable by every backend.

## Choosing a backend in the app

`NotebookWorkspace.Mode` selects the kind of build, and in iCloud builds
`NotebookSyncStorage` selects iCloud, S3, or no sync. Settings › Sync changes
it while the app runs; `prepareNotebookTransport` creates the transport. A
mode can name a notification to observe for account changes through
`Mode.accountChangedNotification`.

Each backend keeps its own sync state next to the notebook, chosen by the
scope: `notebook-sync-state.json` for iCloud and `notebook-sync-state-s3.json`
for S3. That is what lets a notebook move between them. A notebook that is
bound to one backend never silently joins a different notebook on another;
the coordinator stops with `NotebookStorageMismatch` before changing
anything. The user can then combine the notebooks or use the stored one,
which the replica records as a choice on the offline-join receipt, bound to
that backend's scope. The next exchange applies it with the same durable
steps as a first offline join.

## Testing a backend

`SyncTransportContractTests` runs the same checks against every backend:
in-memory, CloudKit on the fake server, S3 on an in-process fake, the
[local HTTP service](local-sync-service.md) when `MEH_NOTEBOOK_HTTP_URL` is
set, and a real S3-compatible service such as MinIO when the
`MEH_S3_TEST_ENDPOINT`, `MEH_S3_TEST_BUCKET`, `MEH_S3_TEST_ACCESS_KEY`, and
`MEH_S3_TEST_SECRET_KEY` variables are set. It covers the shared seed,
delivery to other devices, cursors, scope, validation, purges, and two
devices converging after concurrent edits.
A new backend joins by adding itself to `backends()` in that test.

## Still specific to iCloud

- Some shared messages, such as "Update meh.md to resume iCloud sync", and
  the toolbar symbols still name iCloud. Status text uses the chosen
  storage's name.
- The upgrade check ("Update required") and redundant snapshot cleanup are
  implemented per backend. CloudKit and S3 each have their own; a new
  backend needs both, or it keeps every snapshot it receives.
