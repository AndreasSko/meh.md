# Notebook sync contract

Milestone 3 stage 2 first implemented replication independently. The Local and
iCloud Dev builds now activate the notebook coordinator by default.

## Identity and old-build isolation

A canonical catalog establishes the notebook identity and shared history.
Fresh clients persist a proposal before bootstrap and join the winning seed.
An existing unrelated notebook fails explicitly instead of being overwritten.
A durable proposal retains any legacy body across retries. Adoption merges
that body idempotently, including after a local file rollback. Legacy writers
must be flushed and stopped before notebook storage activates. The one-way
bridge then imports newer version 1 source edits without writing notebook
changes back to `Notes`.

A first iCloud activation must be online to join the canonical version 1 note
before proposing or joining its version 2 notebook. An already activated
notebook opens from its local durable state while CloudKit is unavailable.

Version 1 note records retain their original JSON and snapshot hashes.
Version 2 records explicitly identify protocol, notebook, and document kind.
The digest binds kind, notebook ID, document ID, and snapshot bytes. Validation
checks the Automerge identity, kind, and heads as well as the envelope.

Local HTTP uses isolated `/v2` routes and storage; publication requires a
canonical bootstrap. CloudKit uses zone `meh-md-notebook-v2`, record type
`AutomergeNotebookSnapshotV2`, and bootstrap ID `canonical-notebook-v2`.
Version 1 clients cannot consume these catalog records. CloudKit transport
state rejects reuse across protocol modes; account/workspace scope changes
fail before exchanging notebook data.

## Local durability and exchange ordering

`NotebookReplica` stores the catalog and ID-based note files. It loads editor
sessions only when opened and merges unopened notes directly into storage.
Concurrent opening and downloading share the same session load. Missing
referenced content is unavailable, never replaced by a blank note.

`NotebookSyncCoordinator` performs one finite exchange per invocation. It
persists applied document heads before advancing a download cursor. A local
rollback invalidates progress and replays history. Upload acknowledgements
cover only the captured heads; edits made during an upload remain pending.
Bodies upload before catalog references, but download works in either order.

A body received before its catalog entry is retained and included in recovery
checkpoints, but is not uploaded until listed. This prevents accidental
publication while ensuring that a lost staged body triggers replay.
Overlapping exchanges are prevented. See the
[progress and batching contract](notebook-sync-progress.md) for current
upload grouping and foreground checks. Background scheduling remains separate
work; no background delivery or large-library performance claim is made.

## Permanent deletion boundary

Permanent markers apply only to confirmed IDs and survive offline edits and
restores. Durable sync state remembers deleted IDs across catalog rollback.
Existing editor sessions become noneditable and deleted bodies are excluded
from publication. An unknown child of a deleted folder survives at a flagged
recovery root.

This stage does not erase content bytes. Cleanup must later remove note files,
recovery versions, managed copies, legacy/proposal bodies where applicable,
transport inbox/outbox copies, and cloud snapshots with retryable progress.
Do not expose Delete Permanently or Empty Trash before that work is complete.

## Verification

The stage passed 190 Swift tests, including 22 native-editor regressions,
13 Python service tests, and Local Mac/iOS Simulator builds. Tests inject
save and transport failures; they do not simulate power loss or process kills.
CloudKit checks exercise codecs and durable state locally, not live delivery.

The HTTP regression uses two replicas in one test process, reopening their
stores around independent edits. Run a disposable local service, then provide
its loopback URL to include that test (otherwise it is explicitly skipped):

```sh
python3 Tools/LocalSyncServer/local_sync_server.py \
  --port 8765 --data-dir /tmp/meh-notebook-test-service
MEH_NOTEBOOK_HTTP_URL=http://127.0.0.1:8765 swift test --disable-sandbox
python3 -m unittest discover -s Tools/LocalSyncServer -p 'test_*.py'
```

Navigation and app activation are integrated. A signed Mac iCloud Dev launch
joined the existing canonical note and synced a newly created folder. Physical
cross-device notebook sync, iPad behavior, library import, cleanup, scale, and
energy acceptance remain later milestone work.
