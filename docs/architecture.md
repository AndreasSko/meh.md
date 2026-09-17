# Architecture notes

Updated: 2026-09-13

This overview describes the notebook implementation on main after milestone
3. Detailed behavior lives in the linked contracts; dated verification
records describe what was tested at each checkpoint.

## App and editor

The app targets Mac, iPhone, and iPad, currently on macOS 27 and iOS/iPadOS 27.
SwiftUI owns navigation and presentation. Thin AppKit and UIKit text views
use TextKit 2 for editing, with shared Markdown syntax and document behavior.
The Local and iCloud Dev schemes have separate app identities and stores. The
regular Release app uses the production identity and CloudKit environment; see
[development builds](development-builds.md) for configuration.

The editor keeps literal Markdown as its backing text. Derived styling must
not rewrite source or introduce formatting-only undo entries. Paint-only
styles use rendering attributes; layout-affecting fonts use text-storage
attributes with undo registration suppressed. Native ranges use UTF-16, so
conversion, Unicode, composition, selection, and undo need focused coverage.

The independent native editor followed an
[FSNotes investigation](editor-investigation.md). The choice of native text
views inside SwiftUI is recorded in
[ADR 001](decisions/001-native-text-editor.md).

Native views retain the revision they display. Whole-text commits branch from
that revision and merge into the live document, retaining remote edits
received during composition. Remote buffer replacement clears stale native
undo/redo entries; subsequent local edits start a new undo history. Failed
commits retain the visible buffer.

Each notebook view now owns its selection/session through a small scene-local
navigation model. Recents, collapse state, last-note selection, and native
positions are device-local preferences; see the [local navigation
contract](notebook-local-navigation.md). Multiple windows remain separate work.

## Document core and local storage

`Sources/NoteCore` owns stable identities, literal note text, metadata,
persistence, and replication. Native editor adapters do not persist files.
[ADR 002](decisions/002-document-persistence-boundary.md) defines this
boundary.

Each note is an Automerge document. A separate Automerge catalog holds note
and folder identities, names, placement, and trash intent. Identity is
independent of filenames. The [notebook core
contract](notebook-core-contract.md)
defines collision handling, concurrent operations, and recovery placement.

Internal Automerge files are authoritative. Local saves validate identity and
history, retain a previous known-good file, and acknowledge saved state using
Automerge heads. Damaged storage requires an explicit recovery choice and
preserves damaged bytes. Separate document writes are not one transaction.
See the [durability contract](durability-contract.md) and
[save-state decision](decisions/003-automerge-save-state.md).

## Import, Markdown copies, and deletion

[Markdown import](notebook-import-contract.md) copies selected files or a
folder tree without changing the source. A durable import journal supports
retry and restart after interruption.

The notebook publishes active notes under
`Documents/Notebook Copies/Markdown`, preserving the folder hierarchy.
These are one-way, readable outputs; external edits are not ingested.
Trashed notes are omitted. Earlier single-note copies remain where they were
created but are no longer maintained. The
[copy contract](markdown-copy-contract.md) defines publication and recovery.

Managed copies are not independent backups. In particular, uninstalling an
iOS or iPadOS app can remove its Documents directory. Explicit offline export
and restore remain follow-up work in the [roadmap](plan.md).

Trash retains recoverable content. Confirmed permanent deletion records
durable identity markers before retryable local and remote cleanup. These
markers prevent an offline device from resurrecting deleted notes. See the
[permanent deletion contract](notebook-permanent-deletion.md).

## Synchronization

`NotebookSyncCoordinator` exchanges catalog and note documents through a
pluggable record-store transport. CloudKit uses CKSyncEngine with a private
database. An in-process store and a
[localhost HTTP service](local-sync-service.md) exercise replication without
an iCloud account; the service is a development tool.

Records contain immutable full-history Automerge snapshots. Version 2 record
digests bind document kind, notebook identity, document identity, and bytes.
A canonical catalog establishes shared history. Fresh iCloud installations
join online; existing notebooks open locally before cloud discovery.
The running app no longer migrates or syncs the version 1 single-note system.

Downloads are durably applied before advancing progress. Upload acknowledgments
cover only captured heads, so edits made during an upload remain pending.
Recovery of older local state triggers replay. CloudKit assets enter a durable
inbox before engine progress is persisted. Account and workspace binding
prevent transport-state reuse across scopes. See the
[notebook sync contract](notebook-sync-contract.md) and
[progress and batching contract](notebook-sync-progress.md).

Cloud builds use automatic CKSyncEngine scheduling and silent notifications,
plus explicit exchanges on activation, saved changes, and Sync Now. App-level
foreground polling remains only for the loopback HTTP test mode. Automatic
scheduling is implemented; actual system delivery still needs device evidence.
The [scheduling contract](notebook-sync-scheduling.md) explains triggers,
retry behavior, and validation limits.

Application-level end-to-end encryption is outside initial scope. The current
approach uses CloudKit's private database and platform data protection.

## Remaining validation and decisions

The [roadmap](plan.md) and linked GitHub issues track recovery, export/restore,
large-notebook performance, and device acceptance. Automated coverage does
not establish physical-device notification delivery or power-loss guarantees.
A user-facing history retention policy also remains separate work.

See [notebook sync validation](notebook-sync-validation.md) for repeatable
checks and recorded measurements. Earlier single-note tests remain useful
historical evidence, but do not establish current notebook acceptance.
