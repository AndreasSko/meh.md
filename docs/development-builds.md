# Choosing a development build

Use the shared scheme menu beside Xcode's Run button:

| Scheme | Installed app | Default behavior |
| --- | --- | --- |
| `meh.md Local` | `meh.md` | Local editing |
| `meh.md iCloud Dev` | `meh.md iCloud Dev` | Foreground iCloud sync |

The legacy `meh.md` scheme is an alias for the local build, so existing build
commands continue to work. All schemes use the same app target.

## Test iCloud yourself

1. Select `meh.md iCloud Dev` and run it on your Mac.
2. Select the same scheme and run it on your iPhone. Both devices must use the
   same iCloud account.
3. Type in either editor while both apps are open. Changes are checked every
   three seconds; Sync Now is also available.
4. Quit and reopen the installed `meh.md iCloud Dev` app normally. The build
   keeps using iCloud without Xcode or launch environment variables.

The first connected device creates the shared note. A fresh second install
joins that same note. A fresh install needs iCloud for its initial setup and
shows a retry action if setup fails. Once joined, the note opens for local
editing even when iCloud is unavailable.

The iCloud Dev build has bundle identifier `de.andreas-sk.meh-md.icloud-dev`,
its own sandbox, and the visible app name `meh.md iCloud Dev`. It coexists with
`meh.md` and does not import or replace the original app's local note.

`Debug-iCloud` compiles in the iCloud default and uses CloudKit's Development
environment. This is a development build, including when archived through its
scheme. Production distribution and background delivery are separate work.
The regular Local scheme archives its Release configuration.

## Automated acceptance checks

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
