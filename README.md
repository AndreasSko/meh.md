# meh.md
Stupid, minimalist, vibe-coded Note taking app that hopefully has better sync
than Obsidian 🤞

Personal native Markdown notes for Mac, iPhone, and iPad. Currently in
early development, with milestone 1 complete and milestone 2 in progress. One
note saves locally as an Automerge document and reopens after quitting. The app
also maintains a user-visible Markdown copy as a one-way, read-only product
output. Use the `meh.md Local` or `meh.md iCloud Dev` Xcode scheme to choose
local editing or development iCloud sync. The iCloud build installs separately
and keeps syncing when reopened normally.

The app shows when the current text is saved on this device and offers retry
after a save failure. Damaged storage requires an explicit recovery choice;
the app retains a previous saved file and preserves damaged bytes.

The Automerge document is the editing source. External changes to a managed
Markdown copy are overwritten when the app next publishes, activates, or
reopens, and deletion causes the copy to be recreated. The app does not ingest
external edits or create conflict copies. An unrelated `note.md` already in a
newly selected destination remains untouched.

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
- [Architecture notes](docs/architecture.md): proposed technical approach and
  open decisions.
- [Editor investigation](docs/editor-investigation.md): FSNotes findings and
  editor-spike evidence.
- [Editor decision](docs/decisions/001-native-text-editor.md): why the app uses
  thin native text views inside SwiftUI.
- [Document decision](docs/decisions/002-document-persistence-boundary.md):
  where editing, authoritative state, and Markdown copies are separated.
