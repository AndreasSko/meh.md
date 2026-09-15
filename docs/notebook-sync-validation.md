# Notebook sync validation

The notebook sync suite runs without CloudKit credentials or another hosted
service. It combines the real replica and coordinator with an in-memory record
store and the repository's loopback HTTP service.

## Pull request coverage

`NotebookSyncStressTests` runs three fixed seeds. Every seed drives three
replicas through independent edits, a network outage, durable local restart,
lost acknowledgement, reordered records within pages, and duplicate record
delivery. It then
checks:

- all catalog placements and note bodies converge;
- each replica's offline edits survive restart and exchange;
- a permanent deletion cannot be resurrected by a stale body; and
- an unknown child of a deleted folder survives at the recovery root.

The ordinary scale check imports 100 notes with folders and mixed body lengths,
reopens the durable source replica, fully synchronizes a second replica, and
exchanges one incremental edit. It checks every note body and the exact note
and folder counts. It prints timings for import, reopen, initial sync, and the
incremental exchange without applying a flaky wall-clock limit.

The same runner starts `Tools/LocalSyncServer/local_sync_server.py` on a free
loopback port and runs the complete Swift suite, including the existing real
HTTP restart tests, all core and native-editor tests, and app-model tests. It
also runs the Python service suite. A shell trap stops the process on success,
failure, or interruption. Test and service output stay in a temporary evidence
directory printed at the end of the run. CI uploads its log files even when a
validation step fails.

Run the pull request checks locally with:

```sh
scripts/run_notebook_sync_validation.sh
```

## Scheduled coverage

The Tuesday schedule and the opt-in workflow input run the same complete Swift
and Python suites with eight fixed seeds plus the 100, 500, and 1,000-note
synthetic notebook cases:

```sh
scripts/run_notebook_sync_validation.sh --scheduled
```

For a bounded custom run, use comma-separated decimal values. At most 12 seeds
and 1,000 items are accepted:

```sh
MEH_NOTEBOOK_STRESS_SEEDS=13,21 \
MEH_NOTEBOOK_SCALE_COUNTS=100,500 \
scripts/run_notebook_sync_validation.sh
```

These checks measure deterministic correctness at useful synthetic sizes. They
do not claim real-device timing, energy behavior, CloudKit delivery, or a
production-sized library benchmark.

## Hosted Xcode constraint

`Package.swift` requires Swift tools 6.2 and the macOS 27 and iOS 27 SDK
generation. GitHub's official runner-image inventory lists `xcode-27` as the
hosted arm64 image for that SDK generation. GitHub currently marks the image as
a preview, so it can have queueing or image stability issues outside the
repository's control.

The workflow records the selected Xcode, Swift, host, and macOS SDK versions
before testing. It keeps the package deployment targets intact. If GitHub
removes or renames the preview label, the job will stay visibly blocked until a
supported Xcode 27 image is selected; it must not silently validate the app
against an older platform.

Sources:

- [GitHub Actions runner images][runner-images]
- [Xcode 27 hosted-image announcement][xcode-27]

[runner-images]: https://github.com/actions/runner-images
[xcode-27]: https://github.com/actions/runner-images/issues/14404

## Recorded synthetic run: 2026-09-13

The corrected larger debug run passed all eight disruption seeds and all
three notebook sizes in 701.6 seconds. Body verification reads every durable
snapshot in bulk; it does not manufacture an editor session for every note.
The incremental step still opens, edits, and flushes a real note session.

| Notes | Import | Reopen | Initial replication | Incremental exchange |
| ---: | ---: | ---: | ---: | ---: |
| 100 | 0.216 s | 0.076 s | 6.617 s | 1.357 s |
| 500 | 1.062 s | 0.389 s | 129.131 s | 7.407 s |
| 1,000 | 2.315 s | 0.822 s | 515.228 s | 15.320 s |

These are local macOS 27 debug-build timings using the in-memory transport
and real durable replicas. Initial replication includes source upload,
destination download, and source reconciliation. Incremental timing includes
opening/editing/flushing one source note and exchanging with the destination.
They exclude CloudKit/network latency and are not device or release benchmarks.

Correctness passed, but initial replication scales poorly in this debug run.
A CPU sample during the 1,000-note case showed active replica application and
Automerge snapshot decoding/merging. Profiling that path is a performance
follow-up; these results do not justify changing merge or durability rules.
Actual-library profiling remains deferred to daily use as requested.

## Cached checkpoint checks and catalog reads

After PR #53 reduced per-keystroke work, the next small optimization keeps
checkpoint-history decoding and enumeration in `NotebookHistoryChecker`, a
serial actor. It receives only immutable records captured from durable local
storage. It never reads or mutates live editor documents and never writes
files. The main-actor coordinator still controls acknowledgement ordering.

The worker caches successful history checks using the entire record,
including snapshot bytes, identity, and claimed heads. Every pass still
checks record presence; losing a file cannot be hidden by the cache. Changed,
rolled-back, or malformed data is checked again. The cache retains at most
256 records, with a 32 MiB payload-and-hash cost budget; oversized records are
checked without caching. The budget is an estimate, not an exact heap limit.

Each catalog document also caches its decoded items for one exact Automerge
head set. All mutations invalidate it through their changed heads, including
writes inside a batch. Failed decoding is never cached, and forks have their
own caches. This avoids repeated map traversal for an unchanged catalog.

Deterministic tests verify reuse, mutation and merge invalidation, failed
merge safety, rollback, corruption, identity mismatch, eviction, missing-file
replay, and cancellation. No network format, merge algorithm, durable-write
ordering, or file-validation rule changes.

Open notes skip redundant remote merges when validated heads match. If the
incoming snapshot exactly matches a saved or locally captured snapshot of
the current revision, it also skips decoding. Otherwise it validates the
incoming bytes before comparing heads. Matching text or unverified claimed
heads are never sufficient. A duplicate cannot mark unsaved edits as saved;
the caller must still flush successfully before acknowledging the download.

### Deferred work

Issue #52 remains open. Moving live open-note merging off the main actor
requires a separate design for edits arriving while a remote merge is being
computed. Do not replace newer editor state with a stale worker result.
Unopened-note merges and other sync processing also remain on their existing
paths in this deliberately limited change. Reprofile before expanding scope.
