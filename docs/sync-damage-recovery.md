# Sync when something is damaged

One damaged item must not stop the rest of a notebook from syncing, and
the user must not be left with a state only a software update can fix.
This page lists what the app does when a record in the storage, a note
file on the device, or the device's own sync bookkeeping cannot be read.

Nothing here deletes notes. A skipped record is never applied, and a
damaged local file is moved aside, not removed.

## A record in the storage that cannot be understood

The notebook's format gate decides what an unreadable record means. In
iCloud the gate is on the canonical record, in S3 it is `format.json`.
See [notebook format upgrades](notebook-upgrade-safety.md).

- **The gate requires a newer app.** Sync pauses with **Update required**,
  as before. Every exchange reads the gate before it applies anything.
- **The gate allows this app.** The record is damaged. The device skips
  it, remembers its name, and keeps syncing everything else.
- **The record's downloaded file could not be read.** That says nothing
  about the record. The fetch fails and is tried again.
- **The canonical record itself is unreadable.** It carries the notebook
  identity and the gate, so it is never skipped. Sync stops.

A device reads its remembered records again once after every launch, so
an app update that understands them picks them up. A remembered record
that has since been deleted is forgotten. In S3 a record read again stays
remembered until the page that carried it was applied, so a crash in
between reads it again. A retry that fails, for example offline, is
repeated on the next exchange.

This only works when **every format change raises the gate**: a new note
schema version, catalog fields that older versions reject, or an
Automerge upgrade that changes the saved format. A change that skips the
gate looks like damage to older devices, and they skip it silently.

A skipped record can hold changes no other record has. They reach other
devices with the next upload of that note from the device that wrote it.

## A note file on the device that cannot be read

- The upload scan skips the note and syncs the others. The exchange then
  ends with an error that names the note.
- When a version of that note arrives from the storage, the device
  repairs the file from it. A valid previous file is merged in first. The
  damaged bytes stay beside the note as `note.quarantine-…`. This works
  while the note is open on its recovery screen too, which then shows
  the repaired note. If the user restores the previous copy at the same
  moment, the received version is merged into the restored note.
- While a note can't be read, the history check fails, so every
  exchange receives everything again until the note is repaired.
- A file that exists but cannot be read at all, or that a newer app
  wrote, is left alone. Neither is known to be damaged.
- Versions that arrived while the note was unreadable are received again
  once it is readable, for example after the user restored it.

## The device's own sync bookkeeping

All of it can be worked out again from the storage and the notebook, so
damaged files are set aside and replaced.

- **`notebook-sync-state.json`** is kept as `….damaged-…`. The next
  exchange receives everything again and uploads what is missing.
- **`cloudkit-sync-state.json` and its payloads:** a copy of the
  manifest is kept as `….damaged-…`, the payloads are removed, and
  iCloud is fetched again. The payload folder is renamed first and the
  manifest replaced in one step, so a rebuild that stops early runs again
  on the next launch with the same evidence.
- **Saved `CKSyncEngine` state** is dropped. A new engine fetches the zone
  again, and owed uploads are queued from the outbox.
- **`s3-device.json`** is replaced. The device continues under a new log
  name.

Two cases are refused instead of replaced, because they are not damage:
state saved by a newer app version, and a payload path that is a link. A
file that exists but cannot be read, as on a locked device, is not
replaced either.

A device that had joined before its state was replaced still never
creates the iCloud zone again. Saved payloads, or an inbox or canonical
record named in a manifest that is still JSON, show that it had joined.
A missing zone keeps meaning that the iCloud data was deleted.

## A halt without a known cause

Some failures stop the iCloud transport until it is built again, for
example an account that could not be checked while an upload was being
prepared. The app used to ask for a relaunch. It now rebuilds the
transport itself on the next refresh and retries with the usual backoff,
from 5 seconds up to 5 minutes. This is what a relaunch did. After seven
failed attempts in a row it stops trying on its own, because the cause is
then not temporary, such as missing iCloud permission. Try Again still
rebuilds it.

Halts with a known cause keep their own handling: an account change, a
required update, and deleted iCloud data are not retried this way.

## S3: checking that the bucket is complete

S3 cannot tell a record that cleanup removed from one that was lost, and
a device does not upload a note again once it was acknowledged. So once
a day, and right after it had to store the seed again, a device lists
`records/`. A document it uploaded that has no object left there loses
its acknowledgement and is uploaded again in the same exchange.

Every exchange also reads `seed.json` from the bucket. When it is gone,
the device stores its copy again along with `format.json`, so a device
that joins next finds this notebook instead of starting a new one. The
seed is only the first version of the catalog, so the device checks the
bucket right away and uploads the current catalog as well. When the
seed belongs to another notebook, because another device set one up in
the empty folder first, the device writes nothing more and sync pauses
with an identity conflict, as it does after a relaunch.

The check finds documents that lost every copy, such as a wiped folder
or an expiry rule. It does not find a document that lost only its newest
copy while an older one remains, a record whose log entry is gone, or a
stored record that is damaged. Each needs more than a listing; see
[#332](https://github.com/AndreasSko/meh.md/issues/332).

## Not covered

Deleting the app's data in iCloud settings, and switching to another
iCloud account, still pause sync with no way to continue from inside the
app. Both need a decision about what the user is offered. The proposal
is in [development iCloud recovery](notebook-cloud-recovery.md).

## Verification

`SyncDamageRecoveryTests` covers the iCloud and local cases against the
in-process CloudKit server, and `S3SyncTransportTests` the S3 ones
against the in-process S3 server. These tests show the transport's
behavior. They do not exercise live CloudKit, a real bucket, or damage
caused by power loss.
