# Sync performance investigation

The first benchmark isolates device-side CloudKit bookkeeping. It uses the
real `CloudKitTransportStateStore` with fictional Automerge records and real
durable writes. It does not create a CloudKit container, contact iCloud, launch
an app, or read an existing notebook. It is not an end-to-end sync benchmark.

## Repeatable release benchmark

Run from the checkout to measure, using a new output directory:

```sh
scripts/run_sync_performance.sh /tmp/meh-sync-baseline
```

The runner saves the revision, working-tree status, toolchain, OS, test log,
and machine-readable `results.jsonl`. It refuses to overwrite an existing
run. Compare the same configuration on the same machine with other heavy work
stopped. There are no flaky elapsed-time assertions in the ordinary tests.

The default cases contain 10 notes with 10 retained revisions each, 100 notes
with 10 revisions, and 100 notes with 30 revisions. Each case runs seven
times. Override the matrix explicitly for more notes or deeper history:

```sh
MEH_SYNC_BENCHMARK_NOTES=10 \
MEH_SYNC_BENCHMARK_REVISIONS=100,500 \
scripts/run_sync_performance.sh /tmp/meh-sync-deep-history
```

`MEH_SYNC_BENCHMARK_NOTES` and `MEH_SYNC_BENCHMARK_REVISIONS` accept up to four
distinct comma-separated integers, each between 1 and 1,000. Their Cartesian
product is limited to 12 cases, each with at most 5,000 retained body records.
`MEH_SYNC_BENCHMARK_REPETITIONS` accepts 1 through 8 (default 7). The fixture
generator is checked in; generated databases live only in temporary test
directories and are removed afterward. Names, identities, text, and edit dates
are fictional and fixed. Automerge actor IDs are generated, so fixtures are
semantically repeatable rather than byte-identical across runs. Results report
actual byte counts to expose material differences.

Each revision adds one character to a short note and retains its full snapshot.
Each repetition starts with the same generated state for that case. Fixture
generation and initial store opening are excluded from the measured operations.
These are warm filesystem measurements, not cold disk or physical-device data.

The JSON output includes every sample, median, nearest-rank p95, snapshot
bytes, durable state-file bytes, and retained record counts. With seven
samples,
p95 is the maximum sample; it is descriptive, not a population estimate.

Measured phases:

- Full state validation, including snapshot decoding and hashes.
- Full state JSON encoding.
- Updating only the CloudKit engine-state payload with a durable write.
- Repeating that exact engine-state update without changing any data.
- Appending one additional character-edit snapshot with a durable write.
- Reopening the state store and fully validating its persisted contents.

Reopening verifies that the engine state and added snapshot survived. A small
payload change still requires durable storage; no benchmark weakens the
flush-before-acknowledgement contract.

## Scope and next layers

The local HTTP transport bypasses this CloudKit-specific state store. Therefore
fast HTTP sync alone cannot clear this code path. After this isolated work,
measure repeated notebook scans, local HTTP exchanges, editor application, and
Markdown-copy publication separately. The existing
[notebook validation runner](notebook-sync-validation.md) supplies correctness
coverage, but its synthetic scale timings use the in-memory transport.

CloudKit service latency, push delivery, rate limits, background scheduling,
and physical-device responsiveness require a later iCloud Dev run. Keep
automatic scheduling delay separate from active exchange time and correlate
upload acknowledgement with the receiving device's visible edit.
