# Development iCloud recovery

The owner permits a clean break from the pre-notebook single-note system.
Existing version 2 notebooks and imported notes remain the current data model.
The application no longer needs the old note's cloud workspace, migration
receipt, or compatibility bridge to open or synchronize a notebook.

## Local access comes first

An existing local catalog opens before cloud account discovery. A cloud error
pauses synchronization and offers retry; it must not hide the local notebook
or disable local editing. Corrupt local data is a separate recovery problem
and must not be described as an iCloud failure.

A fresh device with no local notebook still needs to join a valid remote
notebook. It must not silently replace an unavailable remote notebook with an
empty one. A future recovery flow should offer an explicitly separate local
notebook when joining is impossible.

## Proposed reset action

A development-only **Reset iCloud Data…** control is useful, but clearing
records alone is insufficient. Other devices retain queued uploads, old sync
cursors, and copies of the old catalog. They could repopulate the workspace.

The proposed action is **Rebuild iCloud from This Device…**:

1. Show which local notebook becomes authoritative, with note/folder counts.
   Require readable, durably saved local bodies before proceeding. Export a
   recovery copy before destructive remote work.
2. Confirm that remote-only changes can be lost. Explain that other devices
   will need to join the rebuilt notebook; do not promise remote erasure from
   offline devices or backups.
3. Establish a new cloud generation and local sync binding. Old clients must
   not upload into that generation. Clearing caches alone is not a generation
   change.
4. Upload the saved local notebook, acknowledge its records, and verify that
   a fresh client can join it before reporting recovery complete.
5. On another device, preserve its old local notebook until the user chooses
   to join the rebuilt generation or export/recover local-only changes.

Generation fencing must be enforced through the cloud layout and client
binding, rather than trusting an old client to respect a newly added flag.
The exact layout belongs in a separate implementation decision. The existing
CloudKit notebook zone and bootstrap are not reset by the Empty Trash work.

This is a proposed follow-up, not an implemented reset button. It must have
its own interruption, offline-device, and physical iCloud acceptance checks.
