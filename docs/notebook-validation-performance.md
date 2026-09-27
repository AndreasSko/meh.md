# Reducing repeated notebook validation

Now that PR #146 reuses unchanged catalog seed acceptance, two avoidable
validation costs remain in each settled sync pass. This follow-up keeps a
useful history cache during large scans and validates bootstrap seeds once
at the existing durable acceptance boundary. It leaves the durable format,
CloudKit protocol, cursor advancement, and acknowledgement rules unchanged.

## History cache working set

The old 256-entry least-recently-used cache repeatedly evicted every entry
when scanning 501 or 1,001 records. A 1,000-note warm check decoded all 1,001
snapshots again and spent about 315 ms in the history worker alone.

The cache now retains up to 1,024 entries under its existing 32 MiB accounting
budget. That budget covers snapshot bytes plus an allowance for history
hashes; it is not a bound on total process memory. Each pass prunes records
that changed, disappeared, were deleted, or left the checkpoint set. Stable
key order and admission without displacing active residents keep a useful
subset when the whole notebook cannot fit.

Every checkpoint still checks fresh record presence and history membership.
Cached history requires exact equality of the full record, including bytes,
identity, and claimed heads. Changed and uncached records are decoded, and
cancellation is checked even when all records are cached. Nothing trusts file
metadata or freezes the record set across a network wait.

## One seed validation boundary

The coordinator previously decoded each bootstrap catalog before calling
`acceptSeed`, which validates it again. Acceptance now owns that validation.
The coordinator retains protocol, record-kind, and notebook-identity guards.
New or changed seeds take full validation and persistence; the only reuse
path remains #146's exact accepted record plus fresh durable-copy and
ledger checks. Failed acceptance cannot advance the checkpoint or begin
fetching and publishing records.

For a warm replica, a seed for the wrong notebook now reports the identity
conflict before decoding its payload. Fresh and warm malformed, forged, or
unsupported seeds are rejected without changing the durable checkpoint.

## Release measurements: 2026-09-27

These runs use fictional local notebook files and an in-memory transport.
Three repetitions per case ran sequentially, without overlapping builds or
test suites, on macOS 27 arm64, Xcode 27, and Swift 6.4. Timings exclude
fixture generation, copying, editor flush, and subsequent Markdown
publication. Filesystem caches are warm.

Complete one-character exchange, source followed by destination, median ms:

| Notes | Versions/note | Baseline | History cache | Validate once | Saved |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | 1 | 177.32 | 170.46 | 152.79 | 24.53 |
| 500 | 3 | 1,269.13 | 973.99 | 853.22 | 415.91 |
| 1,000 | 5 | 2,832.62 | 2,190.74 | 1,873.03 | 959.59 |
| 10 | 500 | 29.33 | 29.14 | 27.75 | 1.58 |

At 1,000 notes, the history step saves 641.88 ms, then removing the duplicate
validation saves another 317.71 ms. The combined local reduction is 33.9%.
At 500 notes it is 32.8%; smaller cases show 13.8% and 5.4% reductions.
Small differences are more sensitive to measurement noise.

The isolated warm history worker falls from 314.78 to 1.86 ms at 1,000 notes,
and 142.73 to 0.92 ms at 500 notes. Decodes per pass fall from 1,001 and 501
to zero. With file gathering included, the 1,000-note history check falls
from 418.84 to 107.45 ms after both changes. Standalone catalog validation
still costs about 155 ms; this change avoids repeating it on settled passes.

The baseline is `4d222c4`, after #146. History-only is `e347fc2`; both changes
are `c5e4cef`. The original three runs each contain 64 phase rows. They retain
unimproved paths: changed Markdown publication stays near 500 ms, and
initial destination sync changes from 4,207.70 to 3,991.30 ms, a much smaller
relative change than the warm exchange. Some sub-millisecond phases fluctuate
upward. All samples, byte counts, revisions, environments, and log hashes are
in the [JSON evidence](benchmarks/notebook-validation-2026-09-27.json).

The fictional content is semantically repeatable, but generated actor IDs and
catalog values may differ. Three-sample p95 is the maximum observed sample,
not a population estimate. Isolated phases are not an additive profile of the
whole exchange. Reproduction uses the existing
[benchmark runner](notebook-exchange-performance.md#repeating-the-benchmark).

## Remaining Markdown publication cost

A separate 1,000-note run adds five stage timings using existing callbacks
inside the publisher actor. It changes no production publication behavior.
The changed-publication total is measured within that actor, excluding its
initial scheduling hop; earlier totals included that hop.

| Stage | Median ms |
| --- | ---: |
| Prepare, decode, plan, validate ownership, record pending | 281.72 |
| Build and durably write the replacement generation | 154.13 |
| Swap content and sync the directory | 0.53 |
| Commit the manifest | 2.28 |
| Remove the old generation and finish cleanup | 58.96 |
| Complete changed publication | 492.70 |

Stage medians need not sum exactly to the total median. The full 21-row run
and its three samples per phase are preserved with the other evidence.
Planning mixes decoding and filesystem checks; this profile does not assign
all preparation time to a single cause.

The safe next investigation is to separate planning from ownership checks,
then assess bounded reuse of already validated immutable input. Avoiding a
whole replacement generation would need a separate design preserving atomic
publication, dates, foreign-file protection, and crash recovery. This batch
keeps those safeguards unchanged.

## Final validation

Eleven new test methods cover cache count and byte pressure, repeated large
scans, rollback, missing and deleted records, forged content, disabled caches,
cancellation, and fresh or warm seed rejection. The seed tests exercise seven
fault types and verify retry after failed persistence. Existing assertions
were not relaxed. The focused history run passed 56 tests; the focused seed
run passed 55 tests.

The final `scripts/run_notebook_sync_validation.sh --scheduled` run passed
731 Swift tests with zero failures and three expected skips: two opt-in
benchmarks and the native insertion-indicator check requiring its app host.
All 16 Python service tests passed. The expanded run used disruption seeds
`7,11,23,47,97,193,389,769` and scale counts `100,500,1000`. It included the
real local HTTP service tests, three-replica convergence, offline concurrent
edits, restarts, duplicate and reordered delivery, lost acknowledgements,
and a stale replica returning after deletion.

Independent read-only review found no remaining correctness blocker. The
release benchmark also passed with all stage callbacks present. The final
unsigned Release macOS and generic iOS Simulator builds both passed.
Builds do not establish physical-device or signed iCloud runtime behavior.

Live CloudKit timing remains unverified. The Development account-status
helper could not launch, so live testing stopped without accessing notebook
records. Local benchmarks do not measure iCloud service time, push delivery,
debounce, background scheduling, or physical-device responsiveness. A future
live test needs a dedicated synthetic zone and an isolated workspace; the
normal development notebook is not a disposable fixture.

The app version remains unchanged during this optimization series. Neither
this follow-up nor #146 is automatically merged or released by this work.
