# Milestone 2: prove synchronization

Started: 2026-09-12. Branch: `codex/milestone-2-sync`.

Checkpoint on 2026-09-13: local replication, native simulator handoff, and
signed Mac/iPhone CloudKit exchange are verified. The owner has confirmed
normal Mac/iPhone editing and handoff. Shared Local and iCloud Dev schemes
keep existing local notes separate from the canonical cloud note. See
[local evidence](sync-verification.md) and
[live device evidence](icloud-live-verification.md) for exact coverage.

## Outcome and boundaries

Synchronize one Automerge note across Mac, iPhone, and iPad. Local saving and
the one-way Markdown copy remain independent of network availability. Prove
the shared replication logic locally before using iCloud for device checks.

Keep multiple notes, folders, import, deletion, history compaction, and
provider switching out of this milestone. A small transport interface permits
another backend later without creating a general plugin system now.

## Delivery sequence

1. Establish the shared record-store contract and inspect CKSyncEngine early
   for constraints that would invalidate it.
2. Exercise independent sessions and real local stores against a deterministic
   in-process service: offline edits, replay, lost responses, and restart.
3. Connect two running simulator apps to a persistent localhost service.
   Exercise native editor updates, composition, undo, and Markdown copies.
4. Add the CloudKit adapter using the same record payload and coordinator.
   Keep CloudKit inbox and engine progress durable and account scoped.
5. Build on both platforms and review persistence and editor behavior
   independently. Record actual process interruptions separately from
   in-process fault injection.
6. Run signed CloudKit checks and owner acceptance on physical devices when
   the container, account, and devices are available. Measure handoff latency.

## Shared replication contract

The core owns edits, document validation, merges, and serialized local saving.
The coordinator owns upload discovery, download application, and progress.
Transports implement a shared remote record store with bootstrap, publish,
and paginated fetch operations. They never mutate the live editor directly.

The first payload format is an immutable full-history Automerge snapshot.
Its SHA-256 identifier makes uncertain uploads safe to retry. This deliberately
trades bandwidth and remote storage for a small, inspectable first protocol.
Do not delete older records or compact history during this milestone.

An atomic first-writer bootstrap publishes one canonical seed. Other fresh
online installations load its actual document history. Equal UUIDs alone do
not establish shared history. An existing independent local note is retained
and sync pauses if the remote identity differs. The isolated iCloud Dev
build requires an online first join instead of creating an unrelated offline
root. Once joined, it remains editable offline. The Local test transport
retains its offline-first bootstrap behavior.
Persist the bootstrap proposal before contacting the service. A lost response
must reuse that proposal's identity across restart.

The local service models durable record acceptance, pagination, retries, and
bootstrap races. It does not emulate Apple account services, push delivery,
background scheduling, quotas, or the implementation of CKSyncEngine.

## Durability invariants

- Save the local document before publishing its snapshot.
- Discover pending work from the persisted document after restart. An edit
  must not depend solely on a transient callback to enter the upload queue.
- Merge downloads into the current live document, including unsaved typing.
- Persist the merged document before recording download cursor advancement.
- Tie progress to applied document heads. After previous-file recovery, replay
  if the restored document no longer contains the progress checkpoint.
- Record only the heads of the snapshot actually acknowledged remotely.
  Typing during an upload remains pending.
- Treat duplicate delivery and uncertain upload responses as normal retries.
- Bind progress to a backend/account/workspace before sending local content.
  A changed scope or corrupt binding pauses sync without replacing note data.
- Keep copy errors separate from local-save and transport failures.

## Native editor boundary

Each native view retains the serialized revision it actually displayed.
Committed text is applied to that revision and merged into the live document.
This prevents delayed SwiftUI rendering or marked-text composition from
overwriting remote changes with an older whole-string value.

Keep ordinary native local undo. When remote text changes the native buffer,
clear undo/redo entries whose offsets refer to the old buffer. Subsequent
local edits establish new undo history. More advanced remote-aware undo is
deferred; this limitation must be visible in the verification record.

## Development configuration

Shared Xcode schemes select Local or the isolated iCloud Dev build.
Local transport is a Debug launch configuration. Use a workspace-specific
Application Support directory and Markdown-copy destination so simulator
experiments cannot replace the owner's ordinary single note. Use the same
workspace name and server endpoint on the two simulated devices.

## Acceptance evidence

- Independent offline replicas converge after reopening their local stores.
- Duplicate/reordered records and lost upload responses remain idempotent.
- Failed local saves do not acknowledge downloaded state.
- Remote input during native typing/composition preserves both edit histories.
- Local undo works and old undo cannot silently remove newly received text.
- Two actual simulator processes exchange text through the local service;
  restart preserves the result and the Markdown copy matches saved text.
- Both platform builds pass, with automated and manual evidence separated.
- Actual iCloud and physical-device checks are recorded as performed or open.

## Scheduling follow-up

Milestone 2 must respect CloudKit retry-after deadlines and retain pending
work during throttling. Milestone 3 will replace fixed foreground polling
with engine scheduling and change notifications, batch local uploads, and
measure responsiveness and battery impact. No fixed cloud latency is promised.

## Agent ownership

The coordinator owns the core contract, save/sync coordinator, app wiring,
Xcode configuration, integration checks, and final review. Bounded agents own
the localhost transport/service, native editor changes, and CloudKit adapter.
Use a separate review pass after implementations exist. Keep commits coherent
and retain the pre-existing Xcode configuration edits.
