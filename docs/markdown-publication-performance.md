# Markdown copy publication performance

After the sync improvements in PR #148, publishing readable Markdown copies
still took about half a second for 1,000 synthetic notes. This follow-up stays
in that PR and retains the complete, atomic folder replacement.

## Changes

The publisher now reuses decoded note text and dates, and the catalog's
validated folder placements, only when the entire input snapshot matches.
Equality includes serialized bytes, claimed history heads, and identity.
Changed snapshots still undergo full decoding and validation. Supplied
placements must still match those derived from the catalog.

One shared 32 MiB payload budget covers retained snapshots, decoded Markdown,
projected names, and an allowance for metadata. At most 1,024 notes are cached.
Missing, changed, duplicate, trashed, and deleted entries are pruned. Values
that do not fit use the original decoding path. The budget is an estimate of
retained payload and overhead, not a limit on total process memory; temporary
plans and caller-owned snapshots have their own costs.

Cached decoding grants no trust in the output folder. Every publication still
reads the manifest, recovers interrupted work, verifies the managed inventory
and symlinks, and compares existing file bytes before declaring a no-op.
The new generation is still built completely before the folder swap. No
manifest format, note storage format, or CloudKit protocol changes.

Staged files also avoid redundant filesystem work: parent directories are
already created before the file pass, and content plus creation/modification
dates now share one final file flush. The exclusive file creation guard,
final file flush, directory flushes, and atomic folder swap remain. A failed
metadata update propagates before publication. Pending partial stages remain
recoverable through the existing manifest protocol.

## Measurements

Three sequential Release runs use the same synthetic matrix: 100 notes with
one version, 1,000 with five versions, and ten with 500 versions. Each case has
three repetitions. No builds or correctness suites overlap measurement.

The first publication is cold. The changed publication follows a one-character
edit using the same publisher instance, as the app does. Fixture generation
and snapshot gathering are outside the publication timer. Catalog decoding,
planning, output ownership checks, file writes, flushes, folder replacement,
and cleanup are included. These are warm local filesystem measurements, not
CloudKit or native editor timings. Regenerated Automerge actor IDs and exact
fixture bytes can differ. Three samples are descriptive, not population
statistics.

Complete changed publication, median milliseconds:

| Notes | Versions/note | Before | Decode reuse | Final | Saved |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | 1 | 46.26 | 25.94 | 23.56 | 22.70 |
| 1,000 | 5 | 498.38 | 245.58 | 220.03 | 278.35 |
| 10 | 500 | 10.42 | 4.63 | 4.41 | 6.01 |

At 1,000 notes, decoded-data reuse saves about 253 ms, then reducing staged
filesystem work saves another 26 ms. The combined reduction is 56%.
Preparation falls from 282.01 to 31.47 ms; staged file building falls from
156.51 to 130.98 ms. Cleanup still costs about 55 ms. Stage medians do not
necessarily sum to the complete-path median.

First publication is broadly unchanged: 439.41 to 403.86 ms at 1,000 notes,
37.58 to 38.60 ms at 100, and 9.44 to 9.45 ms for ten notes with deep history.
The benefit primarily applies to subsequent publications. The new cache adds
bounded retained memory and does not skip recovery or filesystem checks.

Every phase and sample, including the unmodified coordinator exchange, is
preserved in the [JSON evidence][evidence].

[evidence]: benchmarks/markdown-publication-2026-09-28.json

These savings are outside the coordinator sync timer and must not be added
to unrelated CloudKit or app-model measurements as a promised total.

The measured revisions were `bdb2def`, `bc055ef`, and `01a5a6a`. After
folding review corrections into their original commits, the equivalent
revisions are `b9d45ca`, `e221c47`, and `7dc219a`, respectively. Application
and exchange-benchmark source equality was checked for each pair. The JSON
retains the original run metadata and this mapping.

Reproduce with the existing fixture generator:

```sh
MEH_EXCHANGE_BENCHMARK_CASES=100x1,1000x5,10x500 \
MEH_EXCHANGE_BENCHMARK_REPETITIONS=3 \
scripts/run_notebook_exchange_performance.sh /tmp/markdown-new-run
```

## Validation

New tests cover exact reuse, malformed or forged snapshots, supplied-placement
mismatch, catalog changes and rollback, count and shared byte pressure,
pruning, warm-cache symlink rejection, and same-instance retry after every
durable publication boundary. Existing tests continue to cover literal UTF-8,
dates and date-only edits, nested folders, naming collisions, moves, Trash,
permanent deletion, external edits, foreign files, and recovery after restart.
File-writer tests also verify that an existing file is rejected before its
metadata callback can run and that callback failures propagate.

The focused Release suite passed 32 tests with no failures or skips. The full
expanded runner passed 767 Swift tests with six expected skips (five opt-in
benchmarks and the insertion-indicator host check) and zero failures. It used
eight disruption seeds and 100/500/1,000-note scale cases. All 16 local-service
and 19 lab-runner Python tests passed. Normal Release macOS and generic iOS
Simulator builds passed. Existing test assertions were not relaxed.

Independent source review found no remaining blocker. Two existing PR review
comments were also addressed: older cloud measurements are now explicitly
labeled as baselines, and the Mac lab runner rereads its log after process
exit so a final success report cannot be mistaken for a premature exit.
The latter has a deterministic synthetic race test. No additional live
CloudKit or physical-device run was needed for these local-copy changes.
The app version remains unchanged.
