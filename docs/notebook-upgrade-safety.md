# Notebook format upgrades

Ship the upgrade safety release to every participating device before enabling
attachments. This release still writes catalog format 1. Attachment support
will use format 2; the record protocol remains version 2 in both releases.

## What users see

When another device requires a newer notebook format, this release shows
**Update required** and pauses iCloud synchronization. Existing local notes
remain available for creating, editing, organizing, and saving. Pending local
changes stay on the device. Updating the app creates a fresh transport, checks
the remote requirement, and resumes the usual merge and publication process.

A new installation cannot download an incompatible notebook until updated.
Downgrading an app after it has already saved a newer local catalog does not
make that catalog readable by an older binary. Preserve those files and update
the app again.

## CloudKit publication boundary

Optional format control fields belong to the existing canonical bootstrap
record. Its original catalog seed, identity, and history are preserved. A
missing requirement means format 1. This keeps the prerequisite compatible
with existing apps while everyone installs it.

Each notebook publication includes a conditional write to the control record
and its snapshots in one atomic operation within the notebook zone. CloudKit
compares the control record's change tag. A competing publication or upgrade
invalidates a stale tag, so the losing operation cannot publish its snapshots.
The next attempt reads the current requirement before offering another batch.
Automatic engine uploads use the same boundary as explicit exchanges.

An upgrade prepares the new catalog locally, then atomically publishes its
snapshot and the new requirement. Only one operation can accept that format
transition. Another device can subsequently merge and publish compatible
changes. The original seed is never replaced with an upgraded catalog.

Unknown requirements are reported before interpreting the catalog's contents.
An incompatible fetched batch does not advance the engine checkpoint. Local
catalogs, note history, pending uploads, and import journals are retained.
There is no persistent migration lock that can remain owned by a lost device.

## Rollout limits

Apps shipped before the prerequisite cannot acquire this behavior remotely.
They ignore the optional control fields, can still publish queued snapshots,
and report generic validation failures when they encounter a newer catalog.
The private CloudKit database does not enforce an app version requirement.
Installing the prerequisite on every participating device is therefore a
rollout condition, including devices that have been offline for a long time.

CloudKit schema deployment and upgrading notebook data are separate actions.
Deploy the optional control fields before releasing the prerequisite. Deploy
attachment records before releasing attachment support. Neither PR by itself
changes the Production schema or releases an app.

## Release acceptance

In the Development container, use disposable notebooks and verify:

1. Two devices attempt the first upgrade together; one format transition is
   accepted and both converge without losing independently prepared changes.
2. A prerequisite device has queued background uploads during that upgrade.
   It pauses with **Update required**, including after restarting the app.
3. Create and edit notes while paused, then install the attachment build.
   Those edits merge and publish without clearing local state or sync history.
4. Interrupt an upgrade before and after remote acceptance. Restart and
   recover without repeating or rolling back the accepted format transition.
5. A device running the release before the prerequisite continues syncing
   format 1 data while optional control fields are present.

Local tests and simulator captures verify injected behavior. They do not prove
CloudKit's live transaction delivery, Production schema readiness, or the
rollout status of a user's other devices.
