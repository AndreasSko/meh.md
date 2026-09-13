# Permanent deletion and Empty Trash

This follows the recoverable Trash and durable catalog markers introduced in
Milestone 3. Moving an item to Trash remains reversible. Permanent deletion
is a separate, confirmed action.

## Interaction

- A trashed note or folder has a **Delete Permanently…** action.
- Expanded Trash offers **Empty Trash…**, also available from its context menu.
- Confirmation shows note/folder counts and the first few names. A folder
  selection includes its currently known descendants, even when collapsed.
- Confirmation captures exact identities. It never expands to include items
  that arrive while the confirmation is open. If a selected item has been
  restored meanwhile, the operation stops and asks for a fresh selection.
- Deleted items disappear after their permanent intent is saved locally.
  Connected devices receive that intent through the normal sync flow.
- Files originally imported into the notebook remain unchanged.

## Durability and convergence

An independent, notebook-bound deletion ledger survives recovery of an older
catalog. The catalog also carries permanent markers for replication. Neither
record contains note bodies. A permanent marker wins over later edits or
restores of the same identity.

A newly discovered child of a deleted folder is recovered at the notebook
root. Deleting the folder does not authorize deleting previously unseen
children. Such a child can be moved to another folder normally.

Local cleanup drains in-flight note writes before removing note directories,
including previous and recovery files. It also removes deleted bodies from
retained import jobs and the notebook bootstrap proposal. Startup and later
refreshes retry interrupted cleanup. Filesystem errors remain visible, while
durable deletion markers can still synchronize.

Managed Markdown publication removes deleted output and old staging
generations through its existing interruption-recovery mechanism. A copy
publication failure stays visible until it can be retried safely.

The sync service must acknowledge a catalog containing the deletion markers
before remote body cleanup starts. Cleanup retains all catalog records and
canonical notebook identity. Stable cursor positions survive removed body
records. Late uploads cannot restore the notebook item and remain subject to
cleanup. Remote failures are reported through sync status and the event log;
they do not reverse permanent intent.

## Development compatibility cut

The app no longer migrates or synchronizes the earlier single-note system.
Existing notebooks and imported notes remain intact. Old migration sources
and version 1 cloud data are not required to open or sync this notebook.

Original import files, the old standalone workspace, user exports, backups,
and filesystem snapshots are outside notebook cleanup. Catalog metadata and
deletion identities remain so offline devices can converge. See the separate
[cloud recovery proposal](notebook-cloud-recovery.md) for a deliberate remote
reset, rather than treating Empty Trash as an iCloud reset.

## Validation

Regression coverage includes exact confirmation scope, restore while a
confirmation is open, ledger/catalog interruptions and recovery, in-flight
writes, import journal cleanup, marker acknowledgement before cloud cleanup,
retry after failure and restart, late uploads, previously unseen children,
and interrupted Markdown generation cleanup.

Local deterministic tests and app compilation do not establish physical
CloudKit delivery. Use disposable notes for the Mac/iPhone owner check: sync
an item, trash and permanently delete it, then reconnect a device that edited
it offline. The item should stay deleted, while an unconfirmed new child
survives at the root.
