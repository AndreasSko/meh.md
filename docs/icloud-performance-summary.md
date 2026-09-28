# iCloud performance optimization review

The remaining work is consolidated in PR #148, including the changes formerly
reviewed in #146 and #147. No version bump, merge, or release is included.
Measurements use fictional files and separate UUID-named CloudKit Development
zones. The normal Development notebook and production data are outside scope.

## Measured work

The earlier local improvements and their full samples remain documented in
[state bookkeeping](sync-performance.md),
[record gathering](notebook-exchange-performance.md),
[catalog seed reuse](catalog-seed-performance.md), and
[pipeline measurements](sync-pipeline-measurements.md).

Those measurements distinguish complete coordinator exchanges, local storage
operations, scheduling, and CloudKit request wrappers. Their reported savings
must not be added together as if each were an independent part of one run.

The final changes target work that those measurements showed to be repeated:

- Read the canonical record before checking whether its zone exists. A
  missing-zone error still resolves the zone and retries once. Normal passes
  retain the live account and canonical-record checks.
- Reuse validation of an unchanged durable bootstrap proposal only after a
  fresh, exact byte comparison with the file. Changed, missing, invalid, or
  oversized proposals still take the full validation path.

- Retain at most two fully validated CloudKit bootstrap records under a
  16 MiB payload budget. Reuse requires exact record and protocol-mode
  equality. Remote metadata, asset reads, size checks, and the content digest
  still run. New content takes full validation. A validation token permits
  duplicate inbox handling without another decode; it grants no durability.

### Durable proposal validation

A fresh Release benchmark compares only the final proposal change, after the
previous catalog/history improvements. Three-sample medians measure the
complete local source-plus-destination coordinator exchange:

| Notes | Versions/note | Before ms | After ms | Saved ms |
| ---: | ---: | ---: | ---: | ---: |
| 100 | 1 | 139.67 | 121.88 | 17.79 |
| 500 | 3 | 784.39 | 681.08 | 103.31 |
| 1,000 | 5 | 1,774.32 | 1,494.48 | 279.84 |
| 10 | 500 | 27.35 | 25.06 | 2.29 |

The 1,000-note reduction is about 16%. All samples and phases, including
initial, no-op, and destination phases, are retained in the JSON evidence.
These are warm filesystem tests with fictional, semantically equivalent
fixtures; generated Automerge actor IDs and exact byte counts can differ.
The measurement excludes editor debounce, Markdown publication, and iCloud.
Most of the gain is in the source pass, whose original proposal holds the
large catalog. Destination passes are nearly flat; initial sync varies by
about 0-2% in the wider cases. Three samples cannot establish population
statistics or predict a particular device's latency.

### CloudKit bootstrap validation

A local Release benchmark constructs CloudKit records and assets without
creating a container or contacting iCloud. It measures repeated proposal
validation, canonical decode, and duplicate inbox append after warming the
cache. Three-sample medians for the complete measured path:

| Catalog items | Before ms | After ms |
| ---: | ---: | ---: |
| 100 | 31.316 | 0.105 |
| 1,000 | 454.696 | 0.120 |

This is deliberately a large-canonical case: both the proposal and canonical
contain the full catalog. Many real notebooks retain a much smaller original
canonical seed, so this is not a 455 ms saving on every CloudKit pass. The
remaining asset read, field checks, digest calculation, and exact comparison
are included; network time and state-file writes are not. Assertions outside
the timer confirm exact decoded content and one canonical inbox record.

To reproduce the opt-in CPU benchmark:

```sh
MEH_BOOTSTRAP_VALIDATION_BENCHMARK=1 swift test -c release \
  --disable-sandbox --filter CloudKitBootstrapValidationPerformanceTests
```

The baseline harness is commit `e37a69c`; the optimized path is `a915eb0`.
Other opt-in benchmarks and fixture sizes are described in the linked
reports. Do not overlap measurements with builds or correctness suites.

### Real iCloud Development

The signed Debug-iCloud lab ran ten fictional notes on the dedicated iOS
simulator with independent sender and receiver stores. Each run used a new
UUID zone. Three warmed one-character edits per run converged to the exact
expected text. Medians below measure manual coordinator passes:

| Run | Upload ms | Download ms | Paired total ms |
| --- | ---: | ---: | ---: |
| Before | 2,055.69 | 1,208.41 | 3,264.10 |
| After | 1,790.98 | 973.20 | 2,774.83 |
| After repeat | 1,891.03 | 984.35 | 2,883.60 |

The paired total is the median of paired samples, not the sum of medians.
The first comparison improves by about 489 ms (15%); the repeat is about
381 ms faster than the baseline. These short sequential live runs are
observations, not a guaranteed latency reduction or a controlled estimate
of all service variability.

The stronger direct evidence is the request trace: six zone lookups per
replica before become one initial lookup on the sender and none on the
receiver. All settled passes skip that request. The baseline's paired
zone-request median was 490 ms. Both optimized runs created a new zone and
saved its canonical record successfully, exercising the missing-zone path.

The repeat also captured a 16.24-second initial upload, including 11.48
seconds inside the canonical-save request. The first optimized initial
upload was 5.55 seconds; baseline was 6.03 seconds. All samples are kept.
Request wrappers include SDK, callback, and retry work; they are not a pure
measurement of Apple's server or network time.

These runs verify manual iCloud Development exchange and live session text.
They do not measure push delivery, background scheduling, or native painting.
All raw fictional reports, environment details, and hashes are in the
[machine-readable evidence](benchmarks/icloud-performance-2026-09-28.json).

## Remaining candidate decisions

| Candidate | Decision and reason |
| --- | --- |
| Account lookup caching | Keep live checks; measured calls take 1–2 ms. |
| Skip canonical fetch | Keep it; server identity can change independently. |
| Send before fetch | Keep merge-before-send and concurrent-edit guarantees. |
| Cache file timestamps | Reject; timestamps cannot prove valid file bytes. |
| Reuse pre-upload scan | Reject; edits can arrive during the network wait. |
| Narrow page checkpoints | Defer; changes corruption and history detection. |
| More seed-acceptance shortcuts | Settled acceptance is about 0.27 ms. |
| Duplicate cached item access | Negligible against the measured costs. |
| Markdown publication | Now 220 ms at 1,000; see the follow-up below. |
| Shorter idle scheduling | Preserve the existing deliberate ten-second wait. |
| Split state storage | Needs a storage migration and recovery design. |
| Delta snapshot protocol | Broader wire/history/recovery redesign. |
| Push and background latency | OS/service-dependent; not measured here. |

Fresh byte reads, exact acknowledgement heads, durable writes before cursor
advancement, and current account identity remain correctness requirements.
Replacing those checks with assumptions would make a benchmark faster while
weakening recovery. Broader storage or protocol redesigns need their own
evidence and a migration plan. They are not prerequisites for this work.

The real-cloud lab remains available on the dedicated, signed-in simulator.
Its runner verifies the Development identity and reads only the selected
run's synthetic report. Physical-device use is not required for further lab
runs; manual simulator exchanges do not establish APNs or native paint timing.

## Risk and release boundary

The main implementation risk is mistakenly treating changed data as already
validated. Reuse therefore requires exact bytes or full immutable records,
and the tests deliberately replace files, forge heads, alter identities,
exercise rollback and restart, and inject persistence failures. Cache memory
has explicit payload limits. A cache hit never stands for a durable write.

The lazy zone check adds one bounded recovery branch when a zone is absent.
Other errors, including explicit user deletion, authentication failures, and
rate limits, propagate. Existing account checks and retry handling remain.
No disk format, CloudKit schema, cursor, or acknowledgement semantics change.
These are contained changes, but testing cannot prove zero data-loss risk.
The tests and isolated Development run are evidence for review, not a
production rollout or a guarantee about Apple service timing.

## Validation before the Markdown follow-up

The expanded local runner passed 756 Swift tests with zero failures and six
expected skips: five opt-in performance tests and the native insertion
indicator check requiring its app host. All 16 local-service Python tests
and 17 lab launch/isolation guard tests passed. Existing test assertions were
not relaxed to accommodate the optimizations.

The run used disruption seeds `7,11,23,47,97,193,389,769` and scale cases
100, 500, and 1,000 notes. It covers three-replica convergence, offline
concurrent edits, process restarts, duplicate and reordered delivery, lost
acknowledgements, stale replicas returning after deletion, corrupt or
replaced durable files, forged records, and failed writes. New focused tests
also cover bounded missing-zone retries and exact bootstrap cache reuse.

Independent source and test review found no remaining correctness blocker.
Normal Release macOS and generic iOS Simulator builds both passed. Neither
normal Release binary contains the lab factory or lab-entry symbols. The
app version and build remain 0.6.0 and 1, inherited from main.

A final staged Mac-to-simulator Development run also passed on the finished
code (`a915eb0`). The Mac published ten synthetic notes; the simulator
received the notebook and verified ten placements. After the Mac appended a
character, a separate simulator launch verified the exact expected text in
an already-open live note session and a nonempty history head.

| Phase | Single observation ms |
| --- | ---: |
| Mac initial upload | 6,466.24 |
| Simulator initial download | 2,574.28 |
| Mac character upload | 2,563.11 |
| Simulator character download | 11,619.19 |

The last phase includes 10,779.70 ms inside the canonical-record read and
751.64 ms in the engine fetch. This is a second observed cloud-request
outlier, retained without a retry to obtain a more favorable number. The
four phases used separate launches and are functional cross-host evidence,
not a continuous edit-to-screen timing or a warm benchmark. No physical
device was used in this final run. All phase reports are in the JSON evidence.
The simulator remains signed in with its isolated lab installed.

## Markdown publication follow-up

The requested additional optimization is now included in this PR. Exact
snapshot reuse avoids preparing unchanged note text and catalog placements
again; staged files avoid redundant parent checks and duplicate flushes.
Complete changed publication for 1,000 notes fell from 498 to 220 ms (56%).
Atomic folder replacement, output ownership checks, and recovery remain.
See [the publication report](markdown-publication-performance.md) for the
per-change results and retained-memory budget. Final validation passed 767
Swift tests (six expected skips), 35 Python tests, and both normal Release
builds, with no failures.
