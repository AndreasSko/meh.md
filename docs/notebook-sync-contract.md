# Notebook sync contract

Milestone 3 stage 2 first implemented replication independently. The Local and
iCloud Dev builds now activate the notebook coordinator by default.

## Identity and old-build isolation

A canonical catalog establishes the notebook identity and shared history.
Fresh clients persist a proposal before bootstrap and join the winning seed.
An existing unrelated notebook fails explicitly instead of being overwritten.
The development app no longer migrates or synchronizes the earlier single-note
system. Ordinary notebook sync ignores and removes any legacy body embedded
in an old bootstrap proposal. Existing notebook data remains intact.

A first iCloud activation must be online to join the version 2 notebook.
An existing notebook opens from local durable state before cloud discovery,
even when CloudKit is unavailable. A failed join offers Retry without
replacing a remote notebook with an empty one.

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
upload grouping. [Automatic scheduling](notebook-sync-scheduling.md) is
implemented around these finite exchanges; actual background delivery remains
a physical-device validation item.

## Permanent deletion boundary

Permanent markers apply only to confirmed IDs and survive offline edits and
restores. Durable sync state remembers deleted IDs across catalog rollback.
Existing editor sessions become noneditable and deleted bodies are excluded
from publication. An unknown child of a deleted folder survives at a flagged
recovery root.

[Permanent deletion cleanup](notebook-permanent-deletion.md) now removes note
files, recovery versions, retained import bodies, managed copies, transport
inbox/outbox copies, and remote note snapshots. An independent local ledger
survives catalog recovery. Cloud cleanup follows acknowledged catalog markers
and preserves cursor positions. Delete Permanently and Empty Trash expose
this contract with confirmation and retryable failures.

## Stage 2 verification record

These results describe the original stage 2 checkpoint. Later coverage and
scale measurements are in [notebook sync
validation](notebook-sync-validation.md).

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

At that checkpoint, a signed Mac iCloud Dev launch joined the existing
canonical note and synced a newly created folder. Import, permanent cleanup,
and automatic scheduling were delivered later in milestone 3; see its
[closeout record](milestone-3-plan.md). Physical-device delivery and energy
acceptance are distinct from those implementation results.
