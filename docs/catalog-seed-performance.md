# Reusing unchanged catalog seed acceptance

Now that repeated note decoding was reduced in PR #145, accepting the same
catalog seed was the largest isolated cost in settled local exchanges. The
coordinator bootstraps on every pass. Previously, even an already accepted
seed triggered catalog decoding, forking, merging, projection, and durable
writes again. At 1,000 notes that acceptance alone took about 1.33 seconds
per call.

## Reuse boundary

A replica now remembers one successfully accepted record and the installed
catalog it produced. Reuse requires all of the following:

- Exact equality of the incoming record, including snapshot bytes and heads.
- The same installed catalog and remembered deletion identities.
- Fresh reads of both current and previous catalog files, each byte-identical
  to the installed snapshot.
- A freshly read deletion ledger matching the accepted state.

The catalog write guard spans the awaited disk check. Any metadata install
or recovery invalidates the cache. Failed validation or persistence cannot
establish trust. Retained snapshot payloads are capped at 16 MiB; larger
catalogs use the full path. Restarting the replica starts cold.

Requiring both durable copies to match preserves repeat-save behavior that
establishes or repairs the previous copy. Changed, missing, corrupt, foreign,
or rolled-back files fall back to the existing validation and storage path.
New ledger identities are applied before fallback persistence, including when
one of the catalog copies is damaged. Deletion draining and cleanup still run
on a cache hit. No heads-only or file-timestamp shortcut is used.

First acceptance and real metadata changes still perform full work. This
retains the existing durable format, protocol, cursor, and acknowledgement
rules. It does not add a cross-process transaction around file reads; external
writes racing those reads remain outside the existing serialization contract.

## Release measurements: 2026-09-27

The unchanged benchmark from #145 was run before and after this change, with
three repetitions per case on macOS 27 arm64, Xcode 27, and Swift 6.4. Neither
run overlapped local builds or test suites. Fixture generation and copying are
excluded, filesystem caches are warm, and all data is fictional.

Complete one-character exchange, source followed by destination:

| Notes | Versions/note | Before ms | After ms | Saved ms |
| ---: | ---: | ---: | ---: | ---: |
| 100 | 1 | 371.22 | 174.61 | 196.61 |
| 500 | 3 | 2,392.17 | 1,250.82 | 1,141.35 |
| 1,000 | 5 | 5,497.09 | 2,790.46 | 2,706.64 |
| 10 | 500 | 49.90 | 32.29 | 17.61 |

These are median local reductions of 53%, 48%, 49%, and 35%, respectively.
Unchanged seed acceptance itself fell from 95.08 to 0.11 ms at 100 notes,
564.68 to 0.24 ms at 500 notes, and 1,328.48 to 0.27 ms at 1,000 notes. The
10-note, deep-history case fell from 9.91 to 0.08 ms.

All 112 phase measurements, including the phases without improvement, their
individual samples, byte counts, environment, and source revisions are in the
[JSON evidence](benchmarks/catalog-seed-2026-09-27.json). With three samples,
p95 is the maximum, not a reliable population estimate. Small differences in
unmodified paths should not be interpreted as separate improvements.

The fresh baseline was measured at `01d9135`, and the optimization at
`e0fb15d`. The core and harness are unchanged between that baseline and the
merged main revision `74d3705` used for this follow-up. Regenerated fixtures
have the same semantic content but may differ in actor IDs and catalog bytes.
See [the benchmark instructions](notebook-exchange-performance.md) to rerun
with a new evidence directory.

## Remaining cost and validation boundary

At 1,000 notes the exchange still takes about 2.79 seconds. Checkpoint-history
verification remains about 0.41 seconds per isolated check, and a listed
record scan remains about 0.11 seconds. Changed Markdown publication remains
about 0.50 seconds and is outside the coordinator exchange timer. These
isolated timings are not an additive profile of the full exchange.

The next useful investigation is repeated catalog validation and history
checking within a pass, followed by Markdown publication. A stage-level
profile should establish which repeated work can safely be shared before
adding another cache. Initial destination download is effectively unchanged.

These measurements exclude CloudKit, network latency, notification delivery,
debounce, background scheduling, editor flush, and rendering. Device and
CloudKit timing are still required to establish the user-visible gain.

## Verification

Ten new regression tests cover unchanged reuse, failed persistence, metadata
invalidation, valid disk rollback, forged records, damaged or missing durable
copies, external deletion-ledger changes with failed writes, and concurrent
catalog edits. Existing test assertions are unchanged. All 76 focused tests
passed, and independent read-only review found no remaining blocker.

Full local HTTP validation ran 720 Swift tests with zero failures and three
expected skips: two opt-in benchmarks and the native insertion-indicator host
check. All 16 Python service tests passed. Unsigned Release macOS and generic
iOS Simulator app builds passed.

The app version remains unchanged during the optimization series, as
requested. Release readiness and physical-device acceptance are separate
from these local performance results.
