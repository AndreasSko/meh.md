# Automatic recovery from legacy snapshot deletion halts

An older device can receive the cleanup introduced by #215 before updating.
Pre-#214 readers treated deletion of an ordinary catalog snapshot as fatal.
They saved a broad deletion flag without identifying the removed catalog.
Updating the reader alone therefore left sync paused before verification.

This targeted migration verifies that old state automatically. It adds no
button and never resets the notebook or discards unsynced changes.

## Eligibility and completion

The migration identifier is `legacy-snapshot-deletion-halt-v1`. It runs only
for notebook protocol V2 state with the old unexpected-deletion flag, no
specific deletion reason, and no saved completion for this migration.

Fresh state starts with the migration complete. Healthy older state records
completion locally without fetching cloud records. New fatal deletions save
an explicit canonical-bootstrap or zone-deletion reason and cannot enter
this migration. A completed migration never runs again for that state.

The original transport stays halted while verification runs. Its normal
engine starts only after the migration succeeds. A transient failure leaves
the old state intact and follows the existing retry/backoff policy. Missing
history leaves sync paused. Updating is not itself evidence of safe recovery.

## Evidence and durable transition

Verification uses a temporary transport with automatic syncing disabled, an
empty outbox, a fresh fetch token, and a guard against cloud publication or
deletion. It checks the account-bound zone and canonical notebook directly;
neither can be created by recovery. A fresh fetch discovers covering records
that the offline device may never have received.

Candidates are grouped by notebook, document and kind through the same
identity and full-history rules used by snapshot retirement. Direct reads
must confirm exact immutable payloads. All previously received histories and
newly fetched histories must survive, including concurrent branches. Equal
text or matching current document IDs is insufficient. Only a confirmed
remote catalog's permanent-deletion marker can excuse a removed note body.
Pending uploads are preserved but cannot supply cloud coverage.

After direct confirmation, another engine fetch checks deletion races. A
covering successor can be confirmed in the next round. Three rounds bound
remote churn; exhausted contention remains retryable. True bootstrap or
zone loss, missing history and identity conflicts stop recovery.

Before the single durable state transition, the original transport state is
saved as `cloudkit-sync-state.before-legacy-recovery-v1.json`. This preserves
the transport inbox, outbox and replay bookkeeping; it is not a separate
Markdown notebook backup. The original state must still match the verified
input. Received records are appended, the obsolete halt is cleared, and
completion is saved together. Existing inbox slots, generation, engine state,
local replay cursors, pending uploads and permanent-deletion state remain.
An interrupted or failed write can be retried from the old durable state.

Temporary verification generations are removed after each attempt. A later
process also sweeps abandoned generations within this recovery's own root.
The sync event log records successful legacy recovery without note contents.

## Future migrations and removal

The completion ledger uses string identifiers so unknown future completions
survive decoding. Each future migration must own a distinct versioned name,
narrow eligibility, an independent proof and an atomic completion boundary.
This is a reusable bookkeeping pattern, not a general flag-reset mechanism.

Keep this compatibility path while supporting direct upgrades from old saved
state. A device can remain dormant for years. A later state migration may
replace the verifier; merely waiting a year is not a safe removal criterion.
Healthy state and completed/new halts have no recovery cloud-read overhead.

## Verification scope

Fictional in-process CloudKit tests cover upgrading after cleanup, preserved
offline edits and pending uploads, full History, permanent deletion, retry,
interrupted fetching, failed commit, cancellation, lost concurrent history,
missing bootstrap/zone, survivor races, account changes and non-recurrence.
These tests establish transport behavior, not physical-device or live
production CloudKit recovery. No owner notebook is used for verification.
