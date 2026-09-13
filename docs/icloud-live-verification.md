# Live iCloud verification

This work is stacked on the local sync foundation in PR #6. Live checks use
CloudKit's Development environment in `iCloud.de.andreas-sk.meh-md`.

Most of this record covers the earlier version 1 single-note app. The default
app now activates the version 2 notebook. The activation check below records
the newer signed Mac evidence; cross-device notebook delivery and physical
iPad behavior remain unverified.

## Notebook activation check

On 2026-09-13 a signed Mac iCloud Dev build joined the existing canonical
version 1 note, activated the version 2 notebook, and synchronized a newly
created folder named `iCloud activation check`. The UI displayed its latest
sync state. This proves one signed Mac activation against live Development
CloudKit. It does not prove delivery to another physical device.

## Isolation

The Mac smoke check uses the private `meh-md-smoke-v1` zone. It does not open
or upload the ordinary local note and does not use the app's normal
`meh-md-sync-v1` zone. Each run uses fresh writer and reader state directories.
The test uploads a uniquely marked disposable snapshot, fetches it through a
fresh adapter, and compares its Automerge bytes and decoded text.

The development test records remain in the smoke zone for inspection. The
check does not delete records, reset a container, or deploy a production
schema. The single smoke mode uses two adapters on this Mac. The phase mode
below checks a real Mac/iPhone round trip through the same development zone.

## Signing

Xcode automatic provisioning uses the existing team `9YFM7J3EH3`. Debug builds
select Development; Release builds select Production. Cloud sync remains
development-only, selected by the iCloud Dev scheme or the legacy Debug smoke
environment flags. The project includes CloudKit entitlements for macOS and
iOS. The available physical iPhone is signed through automatic provisioning.

The first signed Mac build and signature verification succeeded on
2026-09-13. Its embedded development profile authorizes the expected container.
The iOS Simulator build also succeeded with signing disabled. All 98 Swift
regression tests passed.

## Live result

On 2026-09-13, the signed Mac smoke check passed in approximately five seconds.
The fresh reader fetched three records and found the newly uploaded snapshot.
Its serialized Automerge bytes, metadata, and decoded text matched exactly.
The process exited successfully.

The verified marker was:

```text
meh.md CloudKit smoke 16B50B15-DA62-430E-ACED-C75A66512B45
```

The uploaded snapshot ID was:

```text
5f316ef0d04c223e74840bc3c81ebafbe0f487a615891aff5ee0a5607ff0f6a9
```

The harness emits JSON progress and the final report to stdout and writes
`cloudkit-smoke-report.json` inside its selected directory. The stdout copy
allows verification without giving the terminal access to protected app
container files.

To reproduce, build a signed Debug Mac app with `-allowProvisioningUpdates`.
Run its `Contents/MacOS/meh.md` executable with
`MEH_CLOUDKIT_SMOKE_DIR` pointing
to a fresh directory inside the app's container, for example:

```text
~/Library/Containers/de.andreas-sk.meh-md/Data/Library/Application Support/
CloudKitSmoke/<run-name>
```

Join the displayed path lines and expand `~` before setting the variable.
The harness bypasses the normal editor. Run it only with the intended iCloud
account signed in. It keeps the ordinary local note untouched.

## Physical iPhone round trip

On 2026-09-13, three signed Debug phases passed using this Mac and an iPhone
12 Pro Max running iOS 27. The phone was connected through Xcode's wireless
device connection. All remote snapshot transfer used live CloudKit.

The run token was `phone-20260913-0834`. Mac publish took about four seconds,
iPhone receive/reply five seconds, and fresh Mac verification three seconds.
All phases reported the same canonical seed and note identity. The incoming
snapshot IDs matched the preceding phase's acknowledged outgoing IDs exactly:

```text
Mac to iPhone:
57a8151f9f371893ae78d2ecbf8338c90c49e4b2cc5880a31de3eb49e760998f

iPhone to Mac:
97d39e98466364b19e10cc7e6b892e7fff3528be97a056f10fe0750885071d0b
```

Final verification merged the fetched history and found both the Mac and
phone markers. Each phase used fresh local transport state. The normal note
was not opened or uploaded. The test app exited successfully on both devices.

To reproduce with a new unique run token:

1. Build signed Debug apps for macOS and iOS, and install the iOS app with
   `xcrun devicectl device install app`.
2. Launch the Mac executable with `MEH_CLOUDKIT_SMOKE_PHASE=publish-mac` and
   `MEH_CLOUDKIT_SMOKE_RUN=<token>`. Save its final JSON report from stdout.
3. Launch the phone app through `xcrun devicectl device process launch` with
   `--console` and `--environment-variables`. Set the same run token,
   `MEH_CLOUDKIT_SMOKE_PHASE=reply-phone`, and
   `MEH_CLOUDKIT_SMOKE_EXPECTED_RECORD` to the Mac's `uploadedRecordID`.
4. Launch the Mac executable again with `MEH_CLOUDKIT_SMOKE_PHASE=verify-mac`,
   the same run token, and `MEH_CLOUDKIT_SMOKE_EXPECTED_RECORD` set to the
   phone's `uploadedRecordID`.
5. Require `status=passed` in all three reports and compare each outgoing ID
   with the next report's `receivedRecordID`. Check matching note and seed IDs.

On iOS the report directory is inside Application Support. On Mac,
`MEH_CLOUDKIT_SMOKE_DIR` optionally selects the parent report directory;
otherwise the app uses Application Support. Phase reports are nested below
`<run-token>/<phase>`. Use exact expected record IDs to distinguish a new
handoff from any older snapshot containing the same marker.

This proves foreground transport and Automerge handoff on physical devices.
It does not exercise manual typing in the phone editor, offline concurrent
edits on physical devices, or background delivery. Existing local/simulator
checks cover those editor and merge paths to the extent documented separately.

## Review follow-up

After the PR #6 review, the full stack passed 98 Swift tests, including asset
retry/cleanup coverage and stronger cursor-replay assertions. The signed Mac
smoke check passed again with exact uploaded/fetched snapshot identity after
the asset cleanup changes. That follow-up used a fresh local state directory
and uploaded snapshot
`e7e13b06a883540f78feb4c76b3d8665f18840cdf089ec03452e90634bbb7a46`.

## Owner acceptance

On 2026-09-13 the owner tested the normal editor on Mac and iPhone and
confirmed that syncing works and the experience is satisfactory. This is
separate from the automated smoke and UI checks.

## Remaining checks

- Test actual radio loss and Apple network timeout behavior separately from
  the injected transport outage below.
- Configure and verify push-driven background scheduling separately; the
  prototype currently uses foreground polling and manual exchanges.
- Verify account changes and production provisioning before release.

## Normal editor and outage recovery

The shared `meh.md iCloud Dev` scheme installs a separate app whose compiled
configuration selects CloudKit on every launch. The UI tests use the ordinary
editor and canonical `meh-md-sync-v1` zone. They append disposable text to the
development note; the original Local app's note remains separate.

On 2026-09-13 all eight phases passed on the Mac and physical iPhone 12 Pro
Max. The run `device-d8281798a42b` first proved normal Mac publish, phone
receive/reply, and Mac receive, including app relaunches. Each device then
made an independent edit while record-store requests failed with an injected
outage, and retained its edit after terminating and relaunching with the
outage still active. Restoring live CloudKit on both devices preserved both
edits after merge and another relaunch.

The outage is injected at the transport boundary with the verified real
account/workspace scope. Account discovery still contacts CloudKit; no device
radios are changed. This verifies persisted application state and merge
recovery on physical devices, not Apple's airplane-mode timeout behavior.
The run's result bundles and `verification.json` are under
`/tmp/meh-cloud-device-20260913-final`. Reproduce with the runner described in
[development builds](development-builds.md).

Live editor checks exposed an idempotent-upload case absent from the isolated
smoke run: an unchanged remote snapshot already existed under its content
hash. A CloudKit conflict now fetches and validates the complete stored
record, including its asset, before acknowledging the upload and clearing
its durable outbox and engine pending entry. The normal editor sequence
passed after this correction.

## Final regression and review

After the development schemes, strict first join, immutable-upload correction,
and throttle handling, all 104 Swift tests passed: 82 core and 22 native
editor tests. The signed iCloud Dev Mac and physical iPhone test builds passed,
as did the Local Mac build. The smaller counts above describe earlier smoke
checkpoints, not the final suite. Independent review found no remaining
correctness blockers after the startup cooldown gap was closed.

Cooldown tests use injected time and error metadata, including startup
account discovery, nested record errors, missing retry delays, and durable
pending uploads. They do not induce Apple's actual rate limits. CloudKit
scheduling, batching, and push delivery are recorded for milestone 3.

The final build repeated all eight UI phases with run `device-065d54999b4e`.
After the final relaunches, the runner compared SHA-256 hashes of the complete
UTF-8 editor text from both devices. They matched exactly:

```text
a5a0e2d8a86a449f72bc5e1aecbae0a6e23bb794bc16eec3345e4050b7009e23
```

Final result bundles, digest attachments, and `verification.json` are under
`/tmp/meh-cloud-device-20260913-digest`. These hashes verify full-text
convergence; the isolated smoke phases above separately verify acknowledged
Automerge snapshot identities.
