# Local notebook exchange performance

This follows the CloudKit bookkeeping work in PR #143. It measures complete
`NotebookSyncCoordinator` passes with real durable notebook files and an
in-memory transport. It does not contact iCloud, read app data, or include
debouncing, notification delivery, background scheduling, or editor rendering.

## Repeating the benchmark

Run the same configuration on the same machine without concurrent builds:

```sh
MEH_EXCHANGE_BENCHMARK_CASES=100x1,500x3,1000x5,10x500 \
MEH_EXCHANGE_BENCHMARK_REPETITIONS=3 \
scripts/run_notebook_exchange_performance.sh /tmp/meh-exchange-new-run
```

The runner refuses to overwrite an existing log or results file. It records
the source revision, working-tree state, toolchain, OS, configuration, complete
test log, and extracted JSON measurements. Ordinary test runs skip this test;
there are no elapsed-time assertions in the correctness suite.

Cases are `notes x body versions`, separated by commas without spaces. The
defaults are `100x1,500x3,1000x5`. Up to six cases are accepted, with 1 to
1,000
notes and 1 to 500 versions, and at most 5,000 note versions per case. Each
case runs three repetitions by default; the allowed range is one to five.

Every case generates a fictional flat notebook with short text. Each note
retains its edit history in one final Automerge snapshot. This differs from
the earlier CloudKit-state benchmark, which retained multiple full snapshots
per note. IDs, names, initial dates, and body edits are synthetic. Automerge
actor IDs and some generated catalog values vary between runs, so the fixture
is semantically repeatable rather than byte-identical. Actual byte counts are
reported. Temporary notebook trees are removed after each case.

Each repetition copies the same fixture to a fresh source directory and uses
a new destination and transport. Fixture generation and copying are excluded
from the timers. Initial sync is measured separately. Both peers settle before
the no-op and single-character measurements. The source editor is already
open when the character is appended, and its local flush precedes the sync
timer. Convergence checks compare all document heads and the edited body.

Measured phases include:

- Initial source upload and destination download passes, with 100-record pages.
- Settled source and destination passes with no new edit.
- A one-character source pass, destination pass, and their combined time.
- Listed and unlisted record gathering, plus checkpoint-history checking.
- Unchanged catalog-seed acceptance and cached catalog item access.
- First Markdown publication and publication after the one-character edit.

The Markdown phases receive already-gathered snapshots, so they exclude the
extra record gathering performed by the app's publication flow. The combined
character time covers coordinator calls, not the later Markdown publication.
Transport validation and durable merges/saves are included in full exchanges;
they are not separately timed or an additive breakdown of every suboperation.
Measurements use warm filesystem caches. With three samples, nearest-rank p95
is the maximum sample, not a reliable population estimate.

## Reusing decoding while still reading files

Each pass gathers all current note records several times: checkpoint-history
verification, each received page, upload preparation, and final status. The
record reader previously decoded every note on every gather.

`NoteFileStorage` now returns an internal validation token for a successfully
decoded current file. Only that implementation can construct the token. The
replica retains tokens from successful scans, capped at 1,024 entries and
32 MiB of snapshot bytes plus an allowance for heads. This is a steady-state
payload budget; the old and replacement cache can coexist during a scan, and
returned records and other app caches have their own memory costs. Oversized
files are read normally. Deleted identities are removed during cleanup.

Every scan still checks file presence and reads the bytes. An exact byte match
allows reuse of decoded identity and heads. Changed bytes are decoded again;
missing, corrupt, unreadable, and unsupported files take the existing recovery
or failure paths. The replica still checks the note's identity against its
directory. Timestamps, inode identity, and claimed heads cannot authorize
reuse.

No full record set is frozen across network waits. Editing sessions still
flush, checkpoint history still runs, and final upload status still uses a
fresh scan. The durable file format, write/recovery path, cursor advancement,
and acknowledgement rules are unchanged. Restarting a replica starts cold.

## Recorded release results: 2026-09-27

Three-sample medians on macOS 27 arm64, Xcode 27.0, Swift 6.4. The runs were
sequential, with no concurrent builds or test suites. All samples, byte counts,
source revisions, and environment information are retained in the
[JSON evidence](benchmarks/notebook-exchange-2026-09-27.json).

Complete one-character exchange, source followed by destination:

| Notes | Versions/note | Before ms | After ms | Saved ms |
| ---: | ---: | ---: | ---: | ---: |
| 100 | 1 | 418.35 | 391.19 | 27.16 |
| 500 | 3 | 2,664.56 | 2,411.45 | 253.11 |
| 1,000 | 5 | 6,159.52 | 5,581.74 | 577.79 |
| 10 | 500 | 102.68 | 51.49 | 51.19 |

One listed-record gather, with current file bytes still read:

| Notes | Versions/note | Before ms | After ms |
| ---: | ---: | ---: | ---: |
| 100 | 1 | 17.16 | 10.96 |
| 500 | 3 | 90.20 | 55.12 |
| 1,000 | 5 | 190.26 | 117.05 |
| 10 | 500 | 6.66 | 1.11 |

The improvement is about 9% for the wider exchanges and 50% for the deep
history case. The small 100-note total change is modest and more sensitive to
run-to-run noise. These are measured local results, not guaranteed device or
CloudKit latency reductions.

Unchanged seed acceptance at 1,000 notes remained about 1.34 to 1.36 seconds;
changed Markdown publication remained about 0.51 to 0.50 seconds. Neither path
was optimized. Full samples include phases without improvement rather than
showing only favorable results.

The baseline production code is reproducible from harness commit `4a1887c`;
the optimization is `b34f1b4`. The baseline was actually measured before the
harness's output-only amendment, at `6947d20`. XCTest stderr split one buffered
JSON key in that run. Its original fragments were rejoined without changing
numbers; the evidence records this extraction. The amended harness emits each
row with one write, and the optimized run required no extraction repair.

## Verification

- Six new tests cover byte-identical replacement, missing/corrupt/unsupported
  and unreadable files, changed identity, and rollback/removal after warming
  the same replica's checkpoint cache.
- The focused storage/history/coordinator run passed all 52 tests, including
  the existing edit-during-upload and durable acknowledgement checks.
- Full local HTTP validation: 692 Swift tests passed with three expected
  skips (two opt-in benchmarks and the native insertion-indicator host check).
- All 16 Python local-service tests passed. Existing assertions were unchanged.
- Unsigned Release macOS and generic iOS Simulator app builds passed.
- Independent read-only review found no correctness blocker. Physical-device
  and iCloud timing remain unmeasured for this change.

After rebasing onto the merged Inbox and recent-note changes, all 698 Swift
tests and 16 Python tests passed, with the same three expected Swift skips.
Both unsigned Release app builds passed again. The app version stays at main's
0.5.0 until the broader optimization is ready for release. The timing samples
above retain their original measured revisions rather than implying a rerun.

## Remaining work

Catalog-seed acceptance remains expensive: it validates and merges the seed,
saves the catalog, and rebuilds derived state even on settled passes. The
benchmark isolates that cost for a separate follow-up. A shortcut here needs
to preserve durable catalog checks, deletion reconciliation, and concurrent
metadata edits; this change does not alter that path.

CloudKit bookkeeping, network service time, push delivery, and physical-device
responsiveness remain separate measurements. Use the iCloud Dev build for
that next layer. Local timings do not predict equivalent cross-device savings.
