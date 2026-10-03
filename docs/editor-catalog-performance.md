# Catalog startup and first-edit performance

The catalog path was doing avoidable full-document work during startup and
the first recent-activity write. The benchmark below uses a synthetic local
catalog to measure the fix and its main-actor effect.

The 100- and 500-note fixtures include activity history for every note except
one, so the measured first-activity write always changes the catalog. Each
fixture is built once. Direct fork-and-snapshot and projection measurements
have three samples; replica load and first-activity measurements have one
sample each. The main-queue dispatch timer records the largest interval
between 10 ms beats while those async replica operations run. The table uses
serial baseline/candidate runs with this same timer.

| Fixture | Measurement | Before | After |
| --- | --- | ---: | ---: |
| 100 notes | Replica load, total ms | 39.5 | 24.3 |
| 100 notes | Replica load, main-actor gap ms | 26.9 | 12.5 |
| 100 notes | First activity write, total ms | 78.8 | 44.4 |
| 100 notes | First activity write, main-actor gap ms | 23.9 | 13.0 |
| 500 notes | Replica load, total ms | 232.3 | 152.0 |
| 500 notes | Replica load, main-actor gap ms | 160.4 | 12.7 |
| 500 notes | First activity write, total ms | 464.2 | 256.9 |
| 500 notes | First activity write, main-actor gap ms | 143.0 | 13.4 |

The first PR CI run exceeded the initial 50 ms heartbeat budget: 76.7 ms
for load and 90.4 ms for first activity at 500 notes. Recent-state projection
and sequence generation still decoded every recent register repeatedly. The
follow-up cache validates all conflicts once per document revision, retains
the largest sequence including losing actions, and reads back only touched
registers after local recent writes. Item changes and merges invalidate it
through changed heads. New tests compare cached state with serialized reopen
results, including clear/unpin conflicts.

The second CI run reduced total work but retained about 90 ms heartbeat gaps.
The original heartbeat used Task.sleep; its wakeup includes cooperative
executor scheduling. The final probe uses a dispatch timer on the main queue
so background-executor delay does not require that extra wakeup hop. The
main-queue timer still measured 75–90 ms on CI. The CI ceiling is 120 ms to
include that runner variance; the 0.10.6 baseline measured 143–160 ms locally
with the same timer. Every pull request runs the 0.10.6 baseline control and
candidate on the same runner. The control must fail a heartbeat budget, and
the candidate must pass it.

The catalog changes reuse cached item and link-history projections only when
their Automerge heads match. Recent-activity and pin writes advance those
caches only when they still match the pre-write heads. Item edits and merges
continue to invalidate them. Catalog forks carry only caches validated at
the source heads. Snapshot loading decodes a fresh document on a concurrent
executor, then transfers its exclusive ownership back to the main actor for
projection and publication. Catalog writes persist one captured snapshot
before publishing that same snapshot and staged document.

The focused durability test injects a failed catalog write and confirms that
the staged activity does not appear in live or reopened state. The opt-in
benchmark records snapshot, projection, replica-load, and first-activity
timings without imposing wall-clock assertions in the normal unit suite.

Run it with `MEH_CATALOG_BENCHMARK=1 swift test -c release
--filter 'NotebookCatalog(CacheTests|PerformanceTests)'`. Set
`MEH_CATALOG_BENCHMARK_REPORT=/tmp/catalog.json` to save its JSON output.

These are directional measurements from one Release run on an arm64 Mac with
macOS 27.0, Xcode 27.0, and Swift 6.4. The synthetic fixture has no CloudKit
traffic and does not model a physical iPhone, display latency, or a user's
catalog. The replica timings include local durable storage; only the heartbeat
estimates main-actor blocking. The 500-note candidate still takes about
260 ms end to end for the first activity write, while its measured main-actor
gap is below 20 ms. This evidence does not promise the same timings on other
devices or storage conditions.

CI runs both fixtures and rejects a main-actor gap above 120 ms. It also
checks total load/write ceilings of 250/250 ms for 100 notes and 500/750 ms
for 500 notes. Reports and logs are retained with the native editor evidence.
The checker rejects incomplete reports and invalid timing samples.

The [serial catalog reports](benchmarks/editor-catalog-2026-10-03.json)
contain the baseline and candidate samples.
