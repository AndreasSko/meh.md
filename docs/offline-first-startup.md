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
  template settings, former link locations, pins, Trash, and permanent deletion
  markers survive. Existing filename collision handling distinguishes items
  with the same name; it does not overwrite either note.
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

The implementation passed the full Swift regression suite: 943 tests
discovered, 937 run, six expected skips, and no failures. The skips are five
opt-in benchmarks and the native insertion-indicator check requiring a native
test host. A running isolated HTTP service included the exchange regressions.

Core tests cover empty and existing clouds, both connection orders, unchanged
note history and editor sessions, all seven interrupted handoff stages,
reopening, scope changes, damaged receipts, retained import cleanup, and
Markdown-copy ownership. App-model tests cover startup without an account,
local saving and reopening, availability and foreground recovery, account
switch protection, old backups, and disabling automatic sync.

The signed iCloud Dev CloudKit lab also passed `offline-join` against a fresh
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

Run the live lab only with a signed Development lab build; the runner checks
its identity, entitlements, and isolated entry point:

```sh
python3 Tools/CloudKit/run_notebook_lab.py "$LAB_APP" "$EVIDENCE_DIR" \
  --phase offline-join --allow-development-cloud --timeout 120
```
