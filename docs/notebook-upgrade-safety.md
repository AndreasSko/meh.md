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

## Prerequisite release acceptance

The prerequisite can ship while attachment support is still being refined.
It keeps catalog format 1 and does not upgrade existing notebook data.

Before releasing the prerequisite:

1. Deploy the five optional control fields listed in
   [CloudKit setup](cloudkit-sync-setup.md) to Production. Ordinary format 1
   publications use those fields too.
2. Verify format 1 synchronization in both directions between the current
   release and the prerequisite, including edits after initial publication.
3. Verify the rebased prerequisite with the Swift suite and iCloud Dev builds.
4. Run a Production smoke test with a dedicated test iCloud account through
   TestFlight.

## Production smoke test and rollout

Use a dedicated test iCloud account on two devices. Keep personal notebooks
out of this test. Use the currently released app and the prerequisite
TestFlight build; local automated builds remain iCloud Dev.

### Schema check

1. Open CloudKit Console and select `iCloud.de.andreas-sk.meh-md`.
2. Compare Development and Production schemas. On
   `AutomergeNotebookSnapshotV2`, check the five optional fields and types in
   [CloudKit setup](cloudkit-sync-setup.md). Review the entire proposed schema
   diff before deployment, including unrelated Development additions.
3. Deploy the reviewed schema changes and inspect Production again. Schema
   deployment copies types, fields, and indexes, not notebook records.
4. If using `cktool`, export both schemas to files and keep the reviewed diff
   with the release evidence. An app signing profile does not supply the
   CloudKit management token needed by this command.

Use [CloudKit Console](https://icloud.developer.apple.com/) for schema review
and deployment.

### Device checks

1. Establish sync in both directions with the released app. Create two
   fictional notes, edit them, and check their exact text on both devices.
2. Install the prerequisite on one device. Keep the released app on the other.
   Repeat creation, edits, folder renaming, and Trash/restore in both
   directions. Confirm old notes and folders remain intact.
3. Install the prerequisite on the second device. Create distinct notes on
   both devices at the same time. Check every note on both devices and watch
   for repeated conflicts or uploads that never finish.
4. Take one device offline. Create and edit fictional notes, quit the app,
   reopen it, then restore connectivity. Check every saved edit on the peer.
5. Permanently delete one fictional note. Restart both apps and verify that
   the deletion persists and all remaining notes retain their exact text.
6. Leave one app in the background while editing on the other. Reopen it and
   check whether sync catches up without Sync Now. Capture Sync Event Logs
   from both devices. This is a physical scheduling check; explicit lab
   exchanges do not establish notification delivery.

Record app versions, schema verification, exact text comparisons, pending
upload state, and any CloudKit failures. Investigate sustained retry loops,
repeated schema errors, missing edits, or deletion of a retained note before
expanding the rollout. CloudKit scheduling has no fixed delivery deadline.

### Release stages

- Wait for all required checks on the exact PR head to pass.
- Run the Production smoke test before distributing to a small TestFlight
  group. Review their sync failures and pending uploads before wider release.
- Keep attachment format 2 disabled throughout this rollout.
- Before format 2, confirm every participating device has the prerequisite.

If the prerequisite causes sync failures, stop expanding the release. Keep
local notes and pending state intact while diagnosing the error. Because this
release still writes format 1, the older app can read the notebook format;
verify an in-place rollback on the dedicated test account before using it as
an operational recovery step. Production fields must stay deployed.

## Attachment release acceptance

Install the prerequisite on every participating device before enabling
format 2. Then use disposable Development notebooks and verify:

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

## Rebased format 1 compatibility

On 2026-10-04, signed Mac iCloud Dev lab builds from main `03b41f3` and the
rebased prerequisite `fa5f204` exchanged fictional notes in two fresh,
isolated Development zones. Both directions passed publish, receive, edit,
and verification on the first attempt. Each final check matched the original
Markdown plus the published edit. Subsequent contention testing exposed the
publication retry issue described below.

After the retry correction, signed builds from `03b41f3` and `d8ef708`
repeated all eight phases in two fresh Development zones. Both directions
again published, received, edited, and verified the exact text.

These checks verify format 1 compatibility through live CloudKit for the
named builds. They do not verify Production schema deployment, notification
delivery, simultaneous format 2 upgrades, or attachment transfers. The
latest rebase onto `2950b5b` occurred after these live binaries were built.

## Concurrent publication recovery

Further Development tests used three clients with 100 fictional notes each.
Concurrent publication exposed `uploadFailed.22`: CloudKit could end a send
when another compatible publication won the canonical change-tag race. The
atomic operation rolled back all snapshots, and companion rollback errors
were reported as upload failures. The old fake engine retried within the same
send, masking this behavior.

All local notes and pending writes survived. A separate process explicitly
refreshed the restarted replicas and verified all 300 notes, 900 exact text
comparisons, identical note snapshot bytes and heads, and matching catalogs.
The original automatic run exceeded its 180-second test bound, and the
original explicit concurrent run reported batch failures. Recovery does not
make those initial runs successful.

The prerequisite now identifies that supported, complete atomic rollback and
requeues every record. Explicit publication retries up to five engine sends,
reading a fresh canonical requirement each time. Short randomized waits
between retries reduce repeated collisions while other clients publish.
Genuine record errors, future formats, and retry deadlines keep their
usual handling. This limit
bounds explicit send calls; CloudKit may perform retries within a call.
Tests cover engine return after rollback, repeated collisions, retained
outboxes, cleanup races, background sends after restart, and real rejection.

### Final contention checks

A signed iCloud Dev lab build from `d8ef708` passed a fresh three-client
concurrent publication of 300 notes in Development on 2026-10-04. The run
completed in 118 seconds. A separate cold process reopened the same replicas
and passed in 18 seconds. Both checks verified 900 exact text and note
snapshot comparisons, matching note heads, and matching catalog heads.

A separate engine scheduling test with 30 notes did not converge within its
acknowledgement window. One client saved its ten notes; two clients observed
supported canonical conflicts and retained pending work. This temporary lab
replaces the normal explicit send with a wait for automatic SDK scheduling;
it does not run the normal app or establish physical background behavior.
Its failed report is retained. Explicit publication success does not clear
this separate check.

The Production smoke test must cover background catch-up and sustained
contention before rollout. CloudKit provides no fixed delivery deadline.
The final rebase onto `2950b5b` retains the retry logic tested by `d8ef708`;
the earlier live binary predates that rebase. The rebased Swift suite passed
1,008 tests with nine existing skips and zero failures, including the live
loopback service integration tests.

## Simulator verification

On 2026-10-02, two disposable iPhone simulators ran the actual iCloud Dev
format 1 (0.9.3) and format 2 (0.10.0) binaries against the isolated HTTP
loopback service. The older apps first synchronized a fictional note. The
newer app then imported a PDF through the native picker and published its
format 2 catalog.

The older app showed **Update required**, hid Sync Now, and still allowed an
existing note to be edited and a new note to be created. Both exact bodies
survived relaunch. The server's five records and state-file SHA-256 remained
unchanged throughout that pause.

Installing the newer app over the older app preserved a marker file and both
Markdown bodies before and after the XCTest launch. Synchronization resumed,
the server advanced to nine records, and the other simulator received both
exact bodies. The imported attachment metadata also appeared on the updated
client. The six successful verification phases had no skipped tests.

The loopback adapter now retains typed update requirements through record and
page validation; it previously reduced them to generic invalid-record errors.
Its six focused regression tests passed. The integrated attachment stack's
full Swift suite passed 980 tests with nine existing skips and zero failures.

This verifies app behavior and retained local data with actual binaries. The
HTTP service does not transfer attachment bytes or implement the CloudKit
conditional control-record transaction. Live CloudKit upgrade arbitration,
background sends, and asset delivery remain attachment acceptance checks.
Production schema readiness must be checked before either release.
