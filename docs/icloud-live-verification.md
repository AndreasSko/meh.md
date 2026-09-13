# Live iCloud verification

This work is stacked on the local sync foundation in PR #6. Live checks use
CloudKit's Development environment in `iCloud.de.andreas-sk.meh-md`.

## Isolation

The Mac smoke check uses the private `meh-md-smoke-v1` zone. It does not open
or upload the ordinary local note and does not use the app's normal
`meh-md-sync-v1` zone. Each run uses fresh writer and reader state directories.
The test uploads a uniquely marked disposable snapshot, fetches it through a
fresh adapter, and compares its Automerge bytes and decoded text.

The development test records remain in the smoke zone for inspection. The
check does not delete records, reset a container, or deploy a production
schema. The single smoke mode uses two adapters on this Mac. The phase mode
below
checks a real Mac/iPhone round trip through the same development zone.

## Signing

Xcode automatic provisioning uses the existing team `9YFM7J3EH3`. Debug builds
select Development; Release builds select Production. Cloud sync remains a
Debug-only opt-in. The project includes CloudKit entitlements for macOS and
iOS. Signing for a physical iPhone still needs that device to be available.

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

## Remaining checks

- Verify concurrent offline edits and restart recovery on physical devices.
- Configure and verify push-driven background scheduling separately; the
  prototype currently uses manual foreground exchanges.
- Verify account changes and production provisioning before release.
