# Redundant iCloud snapshot cleanup

Now that #214 accepts retirement of covered snapshots, this follow-up to #34
removes redundant immutable note and catalog records after a successful
notebook exchange. The surviving snapshots retain complete Automerge history.
Concurrent branches remain until a confirmed merged snapshot covers them.

## Deletion proof

Discovery groups records by notebook, document, kind, and protocol version.
Every victim's full change-hash set must be a subset of its survivor's full
history. Matching text, timestamps, and current heads are insufficient.

Coverage strictly increases the pair `(history count, immutable record ID)`.
Equal histories use the record ID as a deterministic tie-breaker. Independent
cleaners therefore cannot form a deletion cycle. The canonical bootstrap
record is excluded, as are pending uploads, known remote deletions, and
permanently purged bodies.

The canonical payload's snapshot ID differs from its reserved CloudKit record
name. Bootstrap acceptance persists that ID, including creation, existing
record, and conflict paths. Cleanup excludes it as both victim and survivor.
Older saved state backfills the identity from an authoritative bootstrap read
before cleanup or retirement checks. That read clears only false absence
evidence for the exact canonical payload and drops plans referencing it;
unrelated deletion evidence remains. Retirement reads covering canonical
payloads through the reserved record name, while real bootstrap loss still
stops sync.

The transport persists victim-to-survivor plans before issuing cloud requests.
It directly reads and validates each survivor's exact immutable payload, then
rechecks current local evidence after any suspension or throttle. A pass sends
at most 100 deletions in one non-atomic batch. Per-record successes are saved
before reporting partial failures. Missing acknowledgments remain retryable;
an already absent victim completes the intention without counting a deletion.

A missing survivor becomes durable remote deletion evidence. Existing
retirement validation must confirm another remote record covers its history
before cleanup continues. Uncovered history stops the exchange. Transient
maintenance outages leave plans retryable without changing an otherwise
acknowledged exchange into a sync failure.

## Scope and cost

Normal notebook synchronization runs cleanup after uploads and permanent note
purges. After the one-time bootstrap identity backfill, empty passes make no
account or zone requests. Successive exchanges continue the bounded queue.
Discovery considers every eligible document so a large earlier group cannot
hide later groups.

History parsing is cached within each discovery or proof pass. Comparisons
never cross document boundaries. A document with many incomparable snapshots
can still require quadratic subset comparisons during initial discovery; the
100-record limit bounds cloud deletion work, not discovery CPU or memory.

Local inbox payloads, generations, and cursor positions are retained. This PR
reduces cloud copies and fresh-join transfer, not local replay storage or the
size of each surviving full-history document. Local inbox compaction remains
separate work. Device registration and old-build compatibility gates are
outside this rollout's scope, as agreed for #34.

## Verification

State tests exercise full-history coverage, deterministic ties, identity
boundaries, pending uploads, deletion evidence, and restart validation.
Transport tests exercise full History readback after a fresh join, concurrent
offline branches, concurrent cleaners, missing survivors, uncertain and
partial acknowledgments, throttling, and progress beyond 100 victims. Existing
unit and sync validation cover this behavior without additional UI tests.

Six deterministic race tests pause one transport after a successful survivor
read or immediately before its cloud deletion request. A second transport
then retires that survivor to a covering successor, or publishes an
acknowledged permanent-deletion marker and purges the note. Immediate and
delayed deletion notifications exercise both proof rejection and idempotent
deletion. Fresh receivers and restarts verify complete surviving history,
permanent deletion, and preservation of an unrelated note. The pauses belong
only to the test database wrapper; no production hooks or UI tests are added.

Canonical catalog regressions cover creator and existing bootstrap paths,
older saved plans, false digest-absence recovery without a prior bootstrap,
and real older-catalog retirement covered only by the reserved bootstrap
record. They check preserved unrelated absence evidence and healthy restarts.

The fictional long-edit fixture compares server record counts, compressed
asset bytes, and fresh receiver transfer before and after cleanup. The lab's
`cleanup` phase performs a separate smoke test in a fresh UUID Development
CloudKit zone with isolated local stores. Measurements count compressed
snapshot payloads, not billed iCloud quota or wire overhead. Live results and
deterministic fake-server results must be reported separately.

The [recorded smoke evidence][evidence]
shows logical received snapshots falling from 26 to 2 and compressed payloads
from 16,045 to 1,313 bytes in the live lab. All 24 past versions are identical.
Fresh fetches took 1.66 seconds before and 1.06 seconds after in this single
run. The separate fake-server fixture reduced 34 physical records to 2 and
retained all 32 past versions plus the current body. These are fixture results,
not a general latency or quota guarantee.

[evidence]: benchmarks/snapshot-cleanup-2026-10-10.json
