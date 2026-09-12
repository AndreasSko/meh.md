# ADR 003: Track saved state with Automerge heads

- Status: Accepted for the authorized milestone 1 implementation
- Date: 2026-09-12

## Context

- Automerge already identifies document states and retains change history.
- Typing can continue while a serialized snapshot is written to disk.
- A previous internal file protects against damaged storage; Markdown remains
  a derived copy with independent failure handling.

## Decision

We will identify save snapshots by Automerge heads and serialize file writes.

- One app-owned session owns the mutable document. It captures matching bytes
  and heads without an intervening edit. Only immutable snapshots cross to the
  file writer; a custom document revision counter is unnecessary.
- A successful file write acknowledges only its snapshot's heads. Current
  heads must match persisted heads before the session displays saved status.
  On startup, derive persisted heads from the authoritative file itself.
- Retain one previous serialized document for storage recovery. Restoring
  earlier text in a healthy document creates a new Automerge change; fallback
  from damaged storage explicitly reports possible loss of later changes.
- Keep destination and external-change bookkeeping local to the Markdown
  writer. Writing a Markdown copy must not itself change the shared document.

## Consequences

- Save completion cannot overwrite the editor or acknowledge later typing.
- A killed process can leave a valid newer file even if success was never
  reported; startup reads that file's actual heads.
- The first increment proves local process-interruption recovery. Sudden power
  loss and physical-device behavior require separate evidence.
- [ADR 002](002-document-persistence-boundary.md) remains the architectural
  boundary. The [durability contract](../durability-contract.md) specifies the
  local implementation rules.

## Alternatives considered

- A second revision history would duplicate Automerge's state identity.
- A database or custom journal would add storage mechanisms without a measured
  need in the single-note increment.
- Recreating documents from Markdown would discard their merge history.
