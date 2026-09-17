# Choosing a development build

Use the shared scheme menu beside Xcode's Run button:

| Scheme | Installed app | Default behavior |
| --- | --- | --- |
| `meh.md Local` | `meh.md` | Local notebook |
| `meh.md iCloud Dev` | `meh.md iCloud Dev` | Notebook with iCloud |
| `meh.md` | `meh.md` | Production iCloud notebook |

All schemes use the same app target. `meh.md Local` runs and archives Debug for
local-only development. `meh.md iCloud Dev` uses `Debug-iCloud`, the separate
development identity, and CloudKit's Development environment. The regular
`meh.md` scheme runs, profiles, analyzes, and archives Release with the
production identity and CloudKit's Production environment. Its tests continue
to use Debug so the UI test target remains testable.

## Test iCloud yourself

1. Select `meh.md iCloud Dev` and run it on your Mac.
2. Select the same scheme and run it on your iPhone. Both devices must use the
   same iCloud account.
3. Edit notes or folder metadata while both apps are open. CloudKit schedules
   sync automatically. Open Sync Details from the cloud toolbar button
   for Sync Now, progress, and errors. Activity appears in the cloud button.
   Sync Event Log retains recent local diagnostics; use Copy Log or Share Log
   after an unexpected upload or retry.
4. Quit and reopen the installed `meh.md iCloud Dev` app normally. The build
   keeps using iCloud without Xcode or launch environment variables.

The first connected device establishes the version 2 notebook. A fresh second
installation must be online to join it. Existing notebooks open for local
editing before cloud account discovery, even when iCloud is unavailable.
Single-note migration and compatibility sync are no longer active.

The iCloud Dev build has bundle identifier `de.andreas-sk.meh-md.icloud-dev`,
its own sandbox, and the visible app name `meh.md iCloud Dev`. It coexists with
`meh.md`; their existing local notebook stores remain separate.

Set `MEH_NOTEBOOK_PREVIEW=1` only for the separate Debug preview workspace.
Normal Local and iCloud Dev launches use their activated notebook stores.

`Debug-iCloud` and Release both compile with `ICLOUD_ENABLED`. Only
`Debug-iCloud` also defines `ICLOUD_DEV`. Both cloud configurations include
APNs entitlements and the iOS background notification mode for
[automatic sync](notebook-sync-scheduling.md). A distribution profile selects
production APNs for TestFlight and App Store builds.

## Automated acceptance checks

The checks below record the version 1 single-note acceptance workflow. They
are historical evidence; single-note compatibility is no longer active.
They do not establish current multi-note deletion or cloud recovery behavior.

`ICloudDevelopmentUITests` are opt-in because they use the live development
container. Build for testing on the iCloud Dev scheme, choose a unique
`MEH_ICLOUD_UI_RUN` for the test runner, and run these methods in order:

1. `test01MacPublishesFromNormalEditor` on Mac.
2. `test02PhoneJoinsAndRepliesAfterRelaunch` on iPhone.
3. `test03MacReceivesPhoneReply` on Mac.

The runner token identifies disposable text appended by the tests. It does
not enable app sync. The app receives no sync-mode environment overrides.
The iCloud Dev scheme selects only this opt-in test class. Without a runner
token these tests skip and perform no cloud work. For command-line runs, pass
`-collect-test-diagnostics never` to avoid optional device sysdiagnostics and
their administrator authorization prompt after a failure.

The complete runner also checks independent edits during an injected
transport outage, relaunches with that outage still active, and then restores
live CloudKit to verify that both edits converge on both devices:

```sh
python3 Tools/CloudKit/run_device_checks.py \
  --mac-products /tmp/meh-schemes-mac/Build/Products \
  --phone-products /tmp/meh-schemes-phone/Build/Products \
  --phone <physical-device-UDID>
```

Build both destinations for testing first. The runner writes phase logs,
result bundles, and `verification.json` under its reported evidence directory.
It compares SHA-256 hashes of the complete final editor text on both devices.
It appends disposable markers to the iCloud Dev note; it does not replace the
note text. Leave both editors alone during the sequence. The outage phases
set `MEH_SYNC_SIMULATE_OFFLINE=1`, which rejects all record-store operations
while keeping the real account/workspace scope. Account discovery still uses
CloudKit. This verifies application outage recovery on real devices, without
claiming an airplane-mode or Apple network-timeout test.
