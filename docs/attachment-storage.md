# Attachments

Attachments are ordinary notebook items beside Markdown notes, in any folder.
Their names, parents, ordering, and Trash state belong to the Automerge
catalog. Their bytes stay outside Automerge and JSON import journals.

## Import and organization

In Files, tap the plus button to create a note. Hold it on iPhone or iPad,
or open its menu on Mac, to choose Import Files or Import Folder. A folder's
context menu imports directly into that folder. The toolbar imports into the
selected folder, or beside the selected item; an ambiguous selection uses
the notebook root.

Drop files or folders from Finder into the Mac browser, or from Files and
other file providers on iPhone and iPad. Dropping onto a folder imports into
it; dropping beside a note imports into its parent. Drops import immediately,
and choosing files in the system picker starts their import directly. The
browser shows the imported items without a confirmation or completion dialog.

The file picker accepts Markdown and other regular files together. Markdown
becomes editable notes; other files become immutable attachments. Import
coordinates access to file-provider sources and copies attachments into the
notebook while source access is available. Import progress and errors remain
visible. Resuming an interrupted import does not need its original source
files.

Attachments support rename, move, manual ordering, Trash, restore, and
permanent deletion. Selecting a file displays its native Quick Look preview
directly in the detail pane. Share or export it from the toolbar through the
system share sheet. Both actions use a verified copy with the displayed
filename and extension. Selecting a
remote attachment requests its download; downloaded content remains available
offline. Markdown export and current Markdown copies contain Markdown only.
Backups also default to Markdown only. In Settings, enable Include attachments
to copy all active files into each dated backup beside their notes. Missing
files download from iCloud before publication; an unavailable or damaged file
stops the backup and keeps previous backups intact. Trash is excluded. See
[automatic backups](markdown-backups.md) for retention and storage details.
Export individual attachments from their detail view.

The catalog upgrades from schema 1 to schema 2 when its first attachment is
added. Schema 2 stores the attachment UUID, SHA-256 digest, and byte count
alongside the normal item fields. Devices running the prerequisite pause
sync until updated to a compatible reader. No migration of existing Markdown
documents or their history is needed.

### Older-client compatibility

This release depends on the [upgrade safety prerequisite][upgrade]. Deploy its
optional CloudKit fields and install the prerequisite on every participating
device before enabling attachments. The optional Production schema was
deployed and verified on 2026-10-11; PR #186 is merged. The prerequisite
retains format 1 while introducing the reader requirement and conditional
publication boundary.

The first attachment creates a format 2 catalog locally. Its remote
publication atomically updates the canonical requirement with that catalog
snapshot. A competing writer must re-read the accepted requirement; only one
operation accepts the format transition. Compatible devices can then merge
and publish their independently prepared changes.

A device running the prerequisite pauses foreground and background sync with
**Update required**. Its existing notes remain editable, and pending changes
and history stay local. After updating to this release, it merges format 2
and publishes those retained edits. Receiving a future unsupported format
also pauses attachment work without clearing transfer progress.

Apps released before the prerequisite cannot gain this behavior remotely.
They ignore the control fields and may still publish queued format 1 records.
A new installation using an older reader cannot download a format 2 notebook.
Downgrading after saving format 2 locally cannot restore format 1 readability.
Do not rewrite a format 2 history's version register to claim compatibility.

[upgrade]: notebook-upgrade-safety.md

## Local storage and durability

Each immutable attachment uses `attachments/<UUID>/content` and a small
`manifest.json` beneath the notebook directory. The manifest has its own
format version. Unknown formats fail without replacing existing data. Equal
bytes imported as separate items keep separate identities and storage, making
deletion independent of other items.

`NotebookAttachmentStore` copies and hashes files in 64 KiB chunks. It rejects
symbolic links and nonregular files, and detects source identity, size, or
modification-time changes during copying. Content and metadata are synced to
disk in a staging directory before exclusive publication. A retry with the
same UUID verifies existing bytes and repeats durability steps. Different
bytes for that UUID fail without overwriting the saved item.

Downloads must match the catalog checksum and byte count before publication.
Verified transfer copies tolerate changes to the source metadata change time
(`ctime`), which can change during CloudKit reads. File identity, size, and
modification time must still remain stable, and every byte must match the
known checksum. Original file imports retain their strict metadata checks.
Export also streams, verifies, and publishes without replacing a destination.
This bounds memory use, but uploads, downloads, and previews need temporary
disk space in addition to the stored file. Cancellation and ordinary errors
remove operation-owned staging files. A process crash can leave staging or
preview copies; automatic orphan reclamation is not implemented. Such copies
are never treated as saved attachments.

## CloudKit transfers

Catalog references synchronize through the existing notebook transport.
Attachment bytes use file-backed `CKAsset` records in a separate private
CloudKit zone. There is no second iCloud Drive folder synchronization system.
See [CloudKit setup](cloudkit-sync-setup.md) for record and zone definitions.

`NotebookAttachmentSyncCoordinator` persists transfer progress separately from
Markdown sync. It permits one upload and one requested download at a time.
Missing local bytes are normal: receiving metadata does not automatically
download every file. Explicit download requests survive restart, and accepted
bytes are durable before the download is acknowledged. Upload retries verify
an existing remote asset after a lost acknowledgement.

Transient failures retry with backoff. CloudKit retry-after deadlines survive
restart and cannot be bypassed by manual retry. A file transfer failure does
not block Markdown exchange. The sync detail screen reports file activity and
errors separately and offers a retry action. Transfers use the notebook's
bound iCloud account; switching accounts pauses them. The local HTTP test
service does not implement attachment transfers; tests use a file-backed
in-memory attachment service alongside the metadata transport.

Permanent deletion removes local content and item-specific transfer/preview
copies. Remote cleanup waits until the catalog deletion is acknowledged, then
replaces the asset with a tombstone at the same remote identity. Conditional
writes prevent delayed uploads from resurrecting a deleted attachment. Trash
alone retains content. See the
[permanent deletion contract](notebook-permanent-deletion.md).

## Scope and release checks

Imported contents are immutable. External editing, replacing file contents,
binary merge histories, automatic cache eviction, and resumable chunk-level
transfers are separate future work. Transfers run while the app has execution
time; this does not promise completion after iOS suspends or terminates it.

Automated tests cover a streamed 200 MiB round trip, interrupted writes,
conflicting identities, corrupt data, mixed imports, missing source files,
metadata arriving before bytes, on-demand download, restart, lost upload
acknowledgements, server throttling, account-scope isolation, and deletion.
CloudKit record tests validate the envelope without contacting the service.
Fault injection is not a physical power-loss test.

Apple's [native CloudKit asset guidance][asset-limits] states that one asset
can contain up to 50 GB, subject to the user's available iCloud storage.
This implementation preserves local files when quota or transfer errors occur.
The archived Web Services 50 MB limit describes a different API.

[asset-limits]: https://developer.apple.com/forums/thread/827897

The additive Production record schema has been deployed. Development checks
below use the real CloudKit service with two local replicas on one signed-in
simulator. They do not establish physical cross-device delivery, push timing,
or a Production attachment-size guarantee.

## Current validation

On 2026-10-11, the full Swift suite with iCloud Dev compilation flags and an
isolated loopback service ran 1,275 tests: 1,266 passed, nine skipped, and none
failed. The skips cover eight optional benchmarks and one insertion-indicator
check that requires an app host. Attachment accounting covers resident bytes,
metadata-only files, inherited Trash, deletion, and orphan content. An offline
attachment join into a format 1 notebook preserves files without putting
binary bytes in the catalog.

Actual iCloud Dev Mac and iOS builds passed. Three iPhone recordings show the
native Files picker, folder context import and destination placement,
rendered Quick Look, mixed note/file browsing, and attachment Storage counts.
The folder test also verified that collapsing the destination hides its
imported child. Durable readback matched the imported PDF checksum and
preserved the note's literal Markdown. The recordings and matching fictional
before/after captures are attached to PR #187.

File-provider staging tests cover callback lifetime, displayed filenames, and
failed-copy cleanup. Six real filesystem fault tests cover metadata-only
changes, strict original-file imports, bounded retries, persistent mutation,
and corrupt bytes. Same-size corruption with the original modification time
restored still fails the expected checksum before publication.

A live Development CloudKit run transferred and verified 200 MiB. It observed
an upload cancellation, resumed from saved coordinator state, downloaded on
demand, checked a cached local read, rejected a format 1 reader, and verified
idempotent upload and tombstone behavior. A previously failing 200 MiB asset
also passed after the verified-copy fix. Each run used fresh fictional zones;
the dedicated simulator's original scoped app was restored afterward.

The cached read used the local API without a network call. The cancellation
restarted the coordinator, rather than terminating the simulator process.
The old-reader check used the real transport configured for format 1. Lost
acknowledgements and concurrent deletion races have fault-test coverage;
this live run did not force those network races. Physical-device and iPad
cross-app drag gestures remain outside the automated evidence.

CI selects the three browser regressions on iPhone and a native Finder test
on Mac. The Finder test covers direct folder drop, internal note move, literal
Markdown, and relaunch; its compiled plan enables the opt-in and retains native
video. It passed locally and on the earlier PR head. CI rejects missing,
skipped, duplicate, or failed selected tests.

Independent Mac computer use exposed a context-menu regression caused by
replacing SwiftUI's native list data source. File imports now use SwiftUI's
public file-URL drop handler, and native row menus were verified manually.
The long-list test retains the real held-edge gesture, exact parent and sibling
placement, relaunch, and literal Markdown checks. On Mac it opens the cached
source identity through Quick Open to inspect its parent, avoiding a click on
a partly clipped sidebar row.

## Repeat the Development attachment lab

Build a signed iCloud Dev app with the `SYNC_LAB` compilation condition. Use
an empty, dedicated simulator signed into a test iCloud account. The runner
checks the Development entitlements and isolated entry point, and refuses to
replace a normal Dev app. It leaves the lab installed for follow-up phases.
Never run this workflow on a simulator used for personal or dev notebooks.

```sh
python3 Tools/CloudKit/run_notebook_lab_simulator.py \
  "$attachment_lab_app" "$attachment_lab_simulator" \
  /tmp/attachment-lab-evidence --phase attachments \
  --allow-development-cloud --dedicated-simulator --timeout 1200
```

The runner creates a fresh run UUID. Both CloudKit zones derive from that
UUID; attachment contents never enter the normal notebook or asset zones.
The report records checksums, timings, and individual acceptance flags.

The `attachments-local` phase performs ten strict 200 MiB local copies and
verified reads without writing cloud records. `attachments-download` retries
only an asset from a prior attachment run; it requires that original
`--run-id` and validates the saved report and notebook identity. The Mac
runner accepts the same phases. Reusing an initial attachment run is rejected
before modifying its files or contacting CloudKit.
