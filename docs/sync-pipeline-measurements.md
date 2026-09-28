# Notebook sync pipeline measurements

This report records three different boundaries: the app-model path over an
in-memory transport, manual CloudKit lab exchanges, and staged Mac/iPad
CloudKit transfer. These runs are not interchangeable. They use fictional
notebooks and do not measure push delivery or native editor rendering.

The run reports, source hashes, environment details, and validation log hashes
are preserved in [the evidence bundle][evidence].
These measurements precede the zone-lookup optimization. The final bootstrap
path checks the zone only after a missing-zone error, then retries once.
The app version remains unchanged. See the [final review][final] for results.

[final]: icloud-performance-summary.md

[evidence]: benchmarks/sync-pipeline-2026-09-28.json

## App-model path with in-memory transport

The Release benchmark uses 201-byte note bodies. The edited note has 12 prior
revisions; the other notes have their initial history. Import and initial sync
are completed before timing. Three repetitions ran per case over
`InMemorySyncTransport`.

All table values are medians in milliseconds.

| Path and notes | Idle wait | Sender exchange | Sender completed |
| --- | ---: | ---: | ---: |
| Automatic, 12 | 10,006 | 27 | 10,065 |
| Manual, 100 | — | 68 | 127 |
| Manual, 1,000 | — | 677 | 1,252 |

| Path and notes | Receiver exchange | Full refresh | Edit to model visible |
| --- | ---: | ---: | ---: |
| Automatic, 12 | 18 | 30 | 10,090 |
| Manual, 100 | 65 | 131 | 153 |
| Manual, 1,000 | 683 | 1,215 | 1,512 |

`Sender completed` for automatic sync includes its roughly ten-second idle
schedule. The benchmark polls pass completion and receiver model text every
25 ms, so those observations can lag by up to one polling interval. Integer
millisecond output also rounds the sub-millisecond editor change to zero.

Receiver model visibility means the open `NoteSession` contains the new text;
it is not a screen-paint measurement. `Receiver refresh` waits for the full
workspace refresh, including deletion cleanup and Markdown-copy publication,
so it can continue after the note text is visible. The harness waits for the
sender refresh and publication to finish before it starts the receiver pass;
source and receiver publication do not overlap in this measurement.

## Same-Mac Development CloudKit lab

Two independent clients on one Mac ran manual warm exchanges using a Debug
Development lab build and a fresh synthetic zone. The first run's three
character uploads were 1,993, 2,264, and 2,157 ms (median 2,157 ms). Downloads
were 1,435, 1,349, and 1,347 ms (median 1,349 ms). Editing and flushing took
about 2.94 ms median. Single-sample initial upload and download were 5,917 ms
and 2,158 ms.

A second same-Mac run recorded request-wrapper timings for three edits. For
each edit, the request total below adds the timed zone-list, canonical-record
read, engine-fetch, and engine-send calls. These sums account for about 97–98%
of each enclosing upload or download measurement:

In the table, each pass is shown as total / named request time, in ms.

| Edit | Upload | Download | Paired zone-list |
| ---: | ---: | ---: | ---: |
| 1 | 1,852 / 1,809 ms (97.7%) | 1,270 / 1,236 ms (97.3%) | 495 ms |
| 2 | 2,367 / 2,310 ms (97.6%) | 1,352 / 1,309 ms (96.8%) | 563 ms |
| 3 | 2,563 / 2,512 ms (98.0%) | 1,380 / 1,336 ms (96.8%) | 531 ms |

The final three sender `engineSend` samples were 1,135, 1,240, and 1,463 ms;
the final three receiver `engineFetch` samples were 705, 759, and 753 ms.
These timers cover SDK and delegate work, including any retry waits; they do
not isolate server time. The request totals are instrumentation estimates,
not proof that all measured time can be removed. The paired zone-list median
is about 531 ms per edit/download cycle in this baseline. The final bootstrap
path removes the routine lookup, resolving the zone only after CloudKit
returns `.zoneNotFound`, then retrying once. Later before/after measurements
are recorded in the [final review][final]; this baseline is not a promise
of an equivalent saving in every run.

## Dedicated iOS Simulator lab

Two manual Development CloudKit exchanges passed on a dedicated simulator
with two local replicas and fresh synthetic zones. Each run creates ten notes
and checks three successive one-letter edits to the first note. The samples
are shown in full; each run has only three samples:

| Run / direction | Samples (ms) | Median (ms) |
| --- | --- | ---: |
| Saved report / upload | 2,006; 2,143; 2,175 | 2,143 |
| Saved report / download | 1,203; 1,255; 1,323 | 1,255 |
| Runner report / upload | 6,246; 2,343; 2,264 | 2,343 |
| Runner report / download | 1,228; 1,270; 1,426 | 1,270 |

The 6,246 ms upload includes a 4,512 ms canonical-bootstrap request; the
other two such requests were 222 and 219 ms. This captures request latency
variation without establishing its server, network, or SDK cause. Initial
upload/download took 6,240/2,210 ms in the first run and 6,317/2,113 ms in the
second. Do not treat the two run medians as a stable simulator baseline.

The first attempt to capture the simulator's large JSON report over
`simctl --console` blocked while streaming output. The completed report was
recovered from the exact UUID-scoped lab directory, and the reusable runner
now reads that report through `simctl get_app_container`. The app sync passed;
the console capture problem was tooling behavior, not a sync deadlock.

## Staged Mac and iPad Development CloudKit transfer

One manual run used a fresh UUID-scoped Development zone. Mac publish,
iPad receive, Mac edit, and iPad verify all passed with the same note and run
IDs. The first synthetic note body matched on the iPad, and the initial receive
verified ten note placements. After the Mac appended one character,
the iPad verified the exact updated body and a nonempty history head.

| Stage | Measured duration |
| --- | ---: |
| Mac initial upload | 6,414 ms |
| iPad initial download | 4,276 ms |
| Mac one-character upload | 2,971 ms |
| iPad one-character download | 1,909 ms |

These are single staged observations, not repeated timing samples. The phases
are separated by relaunches, restoration, and operator handoffs; do not add
them as continuous edit-to-screen latency. The initial Mac publish overlapped
the tail of the correctness suite, so these durations are functional evidence,
not a clean performance benchmark. The physical-device runner reinstalled the
normal Development app at source version 0.6.0 after the lab phase, replacing
the previously installed 0.5.0 build without launching it. Only the isolated
synthetic zone was used; production and canonical Development notebook data
were not accessed.

## Reproduction

Run the app-model benchmark from the repository root:

```sh
MEH_RUN_MODEL_SYNC_BENCHMARK=1 \
MEH_MODEL_BENCHMARK_CASES=100:3,1000:3 \
swift test -c release \
  --disable-sandbox \
  --filter NotebookWorkspacePipelineBenchmarkTests
```

Build a lab explicitly; normal builds never select its entry point. For Mac:

```sh
LAB_FLAGS='DEBUG ICLOUD_ENABLED ICLOUD_DEV SYNC_LAB'
xcodebuild -project meh.md.xcodeproj -scheme 'meh.md iCloud Dev' \
  -configuration Debug-iCloud -destination 'platform=macOS' \
  -derivedDataPath /tmp/meh-mac-lab \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS="$LAB_FLAGS" \
  CODE_SIGN_IDENTITY='Apple Development' build
```

For Simulator, use `-destination "id=$SIMULATOR_UDID"` and a separate derived
data directory. Keep Xcode's simulator signing unchanged: CloudKit permissions
are embedded in the executable, while host-signature entitlements are empty.
Hand-signing the simulator app with physical-device entitlements caused launch
rejection. The runner checks the actual executable's embedded Development
entitlements and lab entry point. It supports thin 64-bit simulator binaries;
ambiguous or unsupported layouts are rejected.

For a same-Mac CloudKit exchange, use a verified signed Debug Development lab
app and a new evidence directory:

```sh
python3 Tools/CloudKit/run_notebook_lab.py \
  /path/to/NotebookSyncLab.app /tmp/notebook-lab-exchange \
  --phase exchange --allow-development-cloud
```

For staged Mac/iPad runs, invoke `run_notebook_lab.py` with `publish` and
`edit` phases on the Mac. Use `run_notebook_lab_device.py` with `receive` and
`verify` on the iPad, passing the original run ID to each follow-up phase. The
scripts create one evidence directory per phase. The iPad runner restores the
normal signed Development app after the lab phase without launching it.

For the dedicated iOS Simulator, use the signed lab app, an already booted
dedicated simulator, and a fresh evidence directory:

```sh
python3 Tools/CloudKit/run_notebook_lab_simulator.py \
  /path/to/NotebookSyncLab.app "$SIMULATOR_UDID" \
  /tmp/notebook-lab-simulator \
  --phase exchange --allow-development-cloud --dedicated-simulator
```

The simulator runner requires both explicit safety flags, refuses the normal
Development app, never erases or resets the simulator, and leaves the lab app
installed for follow-up phases. Pass the same run ID to `publish`, `receive`,
`edit`, or `verify` phases. The runner retrieves only that run's report.

## Limits and validation

The Release app-model benchmark uses an in-memory transport. CloudKit timings
come from small-fixture Debug Development builds. Do not compare their absolute
durations as if they measured the same work. None measures APNs delivery,
background scheduling, native editor paint, or complete user-perceived
latency. A final CloudKit request-wrapper profile is reported separately from
the staged physical-device run.

The final local validation passed 736 Swift tests with five expected skips
and no failures, plus 16 local service Python tests. The isolated CloudKit lab
guard suite passed 17 tests. Normal Release macOS and generic iOS Simulator
builds passed. These checks do not establish signed iCloud runtime performance.

This report preserves the baseline measurements and bounded lab tooling.
The consolidated PR also changes bootstrap request behavior and removes
repeated local work, as recorded in the [final review][final]. The app
version remains unchanged.
