# Documentation

Start with the [project README](../README.md) for the app's purpose. These
pages separate product direction, current behavior, development instructions,
and the evidence collected along the way.

## Direction and design

- [Product brief](product.md): personal goals and scope.
- [Roadmap](plan.md): milestone status and follow-up issues.
- [Architecture](architecture.md): the current notebook design.
- [Native editor decision](decisions/001-native-text-editor.md).
- [Document boundary](decisions/002-document-persistence-boundary.md).
- [Automerge save-state decision](decisions/003-automerge-save-state.md).

## Build and validate

- [Development builds](development-builds.md): Local, development-cloud, and
  production-cloud schemes.
- [CloudKit setup](cloudkit-sync-setup.md): signing and container setup.
- [Internal TestFlight delivery](testflight-ci.md): CI triggers, credentials,
  signing assets, and first-run verification.
- [Local sync service](local-sync-service.md): account-free replication tests.
- [Notebook sync validation](notebook-sync-validation.md): local checks, CI,
  and recorded scale measurements.
- [Automatic sync](notebook-sync-scheduling.md): scheduling behavior and a
  physical-device checklist.

## Notebook behavior and contracts

- [Notebook core](notebook-core-contract.md): identity, folders, and Trash.
- [Local search](notebook-search.md): matching, Quick Open, and native Find.
- [Navigation and preview](notebook-navigation-preview.md): app interaction
  and the isolated Debug workspace.
- [Markdown import](notebook-import-contract.md): source-preserving import.
- [Markdown copies](markdown-copy-contract.md): portable, one-way output.
- [Local durability](durability-contract.md): per-note save and recovery rules.
- [Notebook sync](notebook-sync-contract.md): bootstrap and durable
  replication.
- [Sync progress](notebook-sync-progress.md): batching, status, and
  diagnostics.
- [Permanent deletion](notebook-permanent-deletion.md): confirmed cleanup.
- [Notebook organization](notebook-browser-operations.md): manual order,
  batch actions, browser undo, and portable dates.

## Execution and verification records

These are dated plans and observations. Earlier checkpoints describe the app
as it existed then, including the retired single-note workflow. Use the
roadmap and linked issues for follow-up status, and the contracts above for
current notebook behavior. Passing historical checks does not establish
acceptance of later implementations.

- [Editor investigation](editor-investigation.md): alternatives and spike
  tests.
- [Automerge spike](automerge-spike.md): local persistence experiments.
- [Milestone 1](milestone-1-plan.md) and
  [local note verification](local-note-verification.md): one durable note.
- [Milestone 2](milestone-2-plan.md),
  [sync verification](sync-verification.md), and
  [live iCloud verification](icloud-live-verification.md): single-note sync.
- [Milestone 3](milestone-3-plan.md): notebook stages and closeout evidence.
- [Wave 2](wave-2-plan.md): ordering, dates, and batch browser operations.

## Proposals

- [Development iCloud recovery](notebook-cloud-recovery.md): proposed remote
  reset behavior. This is a proposal, not an available recovery command.
