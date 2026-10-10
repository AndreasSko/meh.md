# Snapshot retirement compatibility

This is the first part of #34. Updated clients can receive deletion of a
redundant immutable note or catalog snapshot without losing editing history.
It does not select or remove redundant records, compact the local inbox, or
truncate Automerge history.

## Acceptance rule

A deleted snapshot is safe to retire only when a surviving snapshot for the
same notebook, document, and kind contains every change hash from its full
Automerge history. Upload time, matching text, and matching document IDs are
not sufficient. Concurrent branches require coverage of each branch.

The transport retains deleted payloads for replay and records their remote
absence separately from permanent note deletion. Inbox membership and unsent
outbox records therefore cannot prove that a replacement survives in iCloud.
After the engine finishes fetching, the transport directly reads a candidate
cloud record, validates it, rechecks current deletion evidence, and durably
resolves only the history it covers. A missing candidate becomes another
unresolved deletion. A transient read failure leaves the obligation retryable.

Engine callbacks report durable receipt and request synchronization. They do
not issue nested cloud requests or approve snapshot retirement. Returning a
sync page still requires every known deletion to be resolved.

Canonical bootstrap deletion and deletion of an already joined zone retain
their existing protections. Permanent note deletion continues to use catalog
tombstones. Payloads, local cursor offsets, and inbox generations remain
unchanged. New bookkeeping decodes with an empty default in older state files.
An older build's ambiguous fatal deletion flag requires the separate
[verified legacy recovery](legacy-sync-halt-recovery.md) before it is cleared.

## Verification

Core state tests check complete history coverage, concurrent branches, both
event orders, missing coverage, identity boundaries, deletion during a read,
sequential retirement, restart, and stable cursors. Transport tests use the
in-process CloudKit server for fresh joins, note and catalog retirement,
offline edits, pending uploads, interrupted fetches, disappearing survivors,
and transient reads. Existing sync CI runs these tests without new UI tests.

These tests establish deterministic transport behavior. They do not establish
live CloudKit delivery timing or account-dependent behavior.

## Follow-up cleanup

The [cleanup follow-up](snapshot-cleanup.md) confirms complete remote snapshots
before deleting covered records, preserves concurrent branches and deletion
markers, and keeps the canonical bootstrap discoverable. Device registration
and old-build compatibility gates are outside the agreed rollout scope. Local
inbox compaction and its cursor protocol remain separate work. Storage and
transfer savings are measured using fictional long-history fixtures.
