# meh.md
Stupid, minimalist, vibe-coded Note taking app that hopefully has better sync
than Obsidian 🤞

Personal native Markdown notes for Mac, iPhone, and iPad. The default app now
opens the milestone 3 notebook: multiple Automerge-backed notes, nested
folders, Trash, local durability, and notebook synchronization. Use the
`meh.md Local` or `meh.md iCloud Dev` Xcode scheme to choose local editing or
development iCloud sync. The iCloud build installs separately and keeps its
sync mode when reopened normally.

The app shows when the current text is saved on this device and offers retry
after a save failure. Damaged storage requires an explicit recovery choice;
the app retains a previous saved file and preserves damaged bytes.

Use the Import Markdown toolbar action to copy existing Markdown files or a
folder tree into the notebook. The review lists skipped items, and interrupted
imports can resume from a saved copy without changing the source.

Automerge documents are the editing source. The notebook publishes active
notes as structured, one-way copies under
`Documents/Notebook Copies/Markdown`. External edits are not imported. Copies
from the earlier single-note app are preserved, but the activated notebook no
longer maintains them.

Existing single-note data is imported through the one-way
`Notebook/LegacyBridge`. Later edits made by an older client can be imported,
but the notebook never writes changes back to the source `Notes` directory.
An existing activated notebook opens offline. A first iCloud notebook join
needs a connection so it can join the canonical version 1 note before
activating version 2 notebook sync.

- [Product brief](docs/product.md): requirements and scope.
- [Milestone plan](docs/plan.md): implementation order and acceptance criteria.
- [Local durability](docs/durability-contract.md): save and recovery rules.
- [Markdown copy contract](docs/markdown-copy-contract.md): ownership and
  replacement rules for the user-visible copy.
- [Local note checks](docs/local-note-verification.md): delivered behavior,
  verification, and remaining limits.
- [Sync execution plan](docs/milestone-2-plan.md): shared replication contract
  and the local-to-iCloud testing sequence.
- [Local sync service](docs/local-sync-service.md): account-free development
  transport and simulator configuration.
- [Development builds](docs/development-builds.md): choosing schemes and
  testing iCloud in the normal editor.
- [CloudKit setup](docs/cloudkit-sync-setup.md): capabilities and remaining
  signed-device checks.
- [Sync verification](docs/sync-verification.md): replica tests, simulator
  handoff evidence, and remaining acceptance work.
- [Notebook execution plan](docs/milestone-3-plan.md): staged delivery and
  behavior feedback checkpoints.
- [Notebook core contract](docs/notebook-core-contract.md): metadata, Trash,
  collision rules, and migration boundaries.
- [Sync progress](docs/notebook-sync-progress.md): active-only status, durable
  upload counts, retry delays, and batched library transfers.
- [Notebook sync contract](docs/notebook-sync-contract.md): bootstrap, record
  isolation, durable replay, and deletion boundaries.
- [Markdown import](docs/notebook-import-contract.md): copying files and
  folders, source preservation, skipped items, and interrupted import recovery.
- [Notebook navigation](docs/notebook-navigation-preview.md): activated UI,
  legacy preview switch, and interaction checks.
- [Architecture notes](docs/architecture.md): proposed technical approach and
  open decisions.
- [Editor investigation](docs/editor-investigation.md): FSNotes findings and
  editor-spike evidence.
- [Editor decision](docs/decisions/001-native-text-editor.md): why the app uses
  thin native text views inside SwiftUI.
- [Document decision](docs/decisions/002-document-persistence-boundary.md):
  where editing, authoritative state, and Markdown copies are separated.
