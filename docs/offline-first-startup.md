# Offline-first startup

Opening meh.md does not require an available iCloud account or network. A fresh
installation creates a durable notebook immediately. Notes, folders, imports,
templates, search, Trash, Markdown copies, and local backups use the same local
storage as an established notebook.

The existing cloud warning shows unavailable sync. Its details explain that
notes stay on the device. There is no separate local mode to choose. Account
availability notifications and returning to the foreground retry automatically
when automatic sync is enabled. Sync Now remains available for manual use.

## First connection

- An empty cloud notebook adopts the local catalog and its existing history.
- An existing cloud notebook receives local items alongside its own. Note and
  folder IDs, body bytes, body history, open editor sessions, folder structure,
  template and snippet settings, former links, pins, hidden Recents, item
  order, Trash, and permanent deletion markers survive. Collision handling
  distinguishes items with the same name; it does not overwrite either note.
- Two independently created offline notebooks converge whichever connects
  first. Later connections use ordinary Automerge replication.
- A bound notebook never joins another account automatically. Account identity
  checks still precede bootstrap, download, and upload. Restoring the original
  account can resume a halted transport; another account leaves sync paused.

Only `createNotebookForSync()` creates the receipt permitting first joining.
Existing unrelated catalogs and explicit local-only notebooks retain strict
identity checks. A receipt must contain the initial empty catalog and prove
that the current local catalog descends from it. Missing or damaged receipts
never authorize replacing another notebook.

## Durable handoff

When the cloud already exists, first joining forks its canonical catalog and
copies the local item metadata into that history. Note documents are neither
recreated nor rewritten. Catalog writes serialize the operation, and the
coordinator binds to the canonical identity before publishing records.

Before replacing local catalog files, `offline-notebook.json` records the
account scope, source and destination snapshots, and local deletion IDs. Import
recovery ownership, deletion-ledger ownership, and both catalog copies are
installed from this plan. Reopening resumes an interrupted installation. If a
partial installation fails, editing pauses until restart rather than allowing
new edits against the old catalog identity. Pending editor saves finish before
the restart guidance appears. An interrupted import must be
resumed or discarded through its existing recovery controls before joining.

After the coordinator saves its binding, the full receipt is removed. A small
`first-sync-binding.json` record retains the original local identity, account
scope, canonical identity, and installed history heads. It authorizes adopting
only the app's own Markdown-copy manifest, after checking its managed files and
recovering unfinished output generations. Foreign destinations and external
files keep their existing refusal behavior. The operation is retryable after
restart without copying notes twice.

Earlier immutable backups retain their original identity and remain visible
as the notebook's last backup. New backups use the canonical identity. Normal
retention prunes the current identity; earlier offline backups remain intact.

## Validation

The October 10 rebase passed the full Swift regression suite: 1134 tests
discovered, 1125 run, nine expected skips, and no failures. The skips are eight
opt-in benchmarks and the native insertion-indicator check requiring a native
test host. A running isolated HTTP service included the exchange regressions.

Core tests cover empty and existing clouds, both connection orders, unchanged
note history and editor sessions, all seven interrupted handoff stages,
reopening, scope changes, damaged receipts, retained import cleanup, and
Markdown-copy ownership. App-model tests cover repeated cold starts without
ever enabling an account, exact Unicode saves, Markdown copies, local backups,
availability and foreground recovery, account switch protection, old backups,
and disabling automatic sync. The join tests also preserve hidden Recents,
new-note placement, and folder/note snippet registrations through upload and
reopening. A production CloudKit-adapter test joins after older cloud snapshots
have been cleaned up, retaining both notes' exact bodies and cloud History
through another restart. It uses the deterministic in-process server.

These deterministic regressions run on every pull request and weekly through
`scripts/run_notebook_sync_validation.sh`. The repository's Protect Main rule
requires its `Deterministic replica and loopback checks` job before merging,
alongside both Release builds. The offline account-transition UI test and live
Apple Account login remain manual checks; CI does not sign into iCloud. Main
also runs selected native editor and UI regression goals on pull requests.

The signed iCloud Dev CloudKit lab passed `offline-join` again after the
October 10 rebase, including main's snapshot cleanup, against a fresh
Development zone. Two clients on one Mac joined first an empty cloud and then
an existing one, converged, retained exact Markdown bodies and history heads,
updated their Markdown copies, and reopened without duplicates. This run
exercised actual CloudKit transport; it did not change the user's account or
use the app's ordinary notebook zone.

Simulator UI checks cover first launch with an unavailable service, writing,
reopening, automatic joining after restoration, and sync details at large text
sizes. The physical iPhone transition from disabled iCloud to enabled iCloud
remains a separate acceptance check. Simulator and same-Mac CloudKit results
do not prove physical-device account notifications or push delivery.

The interactive live account test also passed. Two notes created in the
signed-out simulator survived relaunch before login. Signing in triggered
account notifications and an automatic foreground refresh. It joined the
preexisting fictional cloud note, retained both offline note IDs and exact
Markdown and Automerge bytes, and reopened with exactly three notes. The Mac
lab then downloaded the offline notes through CloudKit, with matching text
and history heads and the same canonical notebook identity. One initial
`CKError.1` recovered through an automatic follow-up; no Sync Now was used.

Run the live lab only with a signed Development lab build; the runner checks
its identity, entitlements, and isolated entry point:

```sh
python3 Tools/CloudKit/run_notebook_lab.py "$LAB_APP" "$EVIDENCE_DIR" \
  --phase offline-join --allow-development-cloud --timeout 120
```

## Interactive simulator account test

Use a dedicated, initially signed-out simulator named
`meh.md Offline iCloud Test`. The normal editor must be built with
`NOTEBOOK_CLOUD_UI_LAB`, `DEBUG`, `ICLOUD_DEV`, and `ICLOUD_ENABLED` in the
iCloud Dev scheme. Bundle a fresh UUID as `MehCloudLabRunID` in a temporary
copy of `Info-iCloud.plist`, and pass that copy as `INFOPLIST_FILE` when
building. Check the finished app's plist; arbitrary generated plist keys
passed as build settings may be omitted by Xcode.

This build always stores its notebook, copies, and backups below
`CloudKitUITests/<UUID>` and uses only the matching
`meh-md-notebook-lab-v2-<UUID>` zone. The identity is bundled, so opening the
app from its icon after login retains the isolation. Missing or malformed
identities stop cloud setup and never select an ordinary notebook. The lab
also restricts automatic CloudKit fetches to its own zone, excluding ordinary
Dev notebook records.

The installer verifies the signed iCloud Dev app, embedded simulator
Development entitlements, compiled isolation guard, bundled UUID, and exact
dedicated simulator. It refuses to overwrite an ordinary Dev app:

```sh
python3 Tools/CloudKit/prepare_offline_icloud_test.py \
  "$UI_LAB_APP" "$SIMULATOR_ID" "$INSTALL_EVIDENCE" \
  --run-id "$RUN_ID" --dedicated-simulator --allow-development-cloud
```

Before simulator login, seed the same UUID using the signed Mac lab entry:

```sh
python3 Tools/CloudKit/run_notebook_lab.py "$LAB_APP" "$SEED_EVIDENCE" \
  --phase offline-ui-seed --run-id "$RUN_ID" --allow-development-cloud
```

This creates one fictional `Already in iCloud.md` note. Create two more
fictional notes in the simulator's normal editor while signed out. Record
their IDs, bodies, history heads, and owned Markdown copies. Relaunch the app
without launch variables and check that the notes remain editable and sync
remains unavailable.

The user signs into the simulator with the same Apple Account used by the
Mac lab, then returns to meh.md. Without pressing Sync Now, all three notes
should appear, with the offline IDs and bodies unchanged. Relaunch again
and check that no duplicates appear. Download into the original Mac fixture:

```sh
python3 Tools/CloudKit/run_notebook_lab.py "$LAB_APP" "$VERIFY_EVIDENCE" \
  --phase offline-ui-verify --run-id "$RUN_ID" --allow-development-cloud
```

Compare its reported note IDs, bodies, and history heads with the offline
capture. The phase checks the original cloud note and reports every note;
the three-note identity and content comparison is a separate acceptance
check. This is a live account test requiring user login. CI runs the
deterministic join and account-recovery tests and the installer guards;
it also builds the guarded workspace and checks its storage isolation.
It does not sign into a real Apple Account.
