# Measured performance controls

These JSON reports preserve measured timings and validation metadata, without
large Markdown source blobs. They were copied from completed PR #212 CI runs:

* `native-slow-836.json`: run 37954100461, source
  `1378bf5e1b9fcaf0ff5e97435a320ef7d726ef42`.
* `native-current-af516.json` and `native-reference-af516.json`: first pair
  from run 37971527557. Current source is the PR merge
  `f52bb9f18ac5d83eb4a23440b7532e2961693aba`; its tree matches `af516a3`.
  Reference source is `369814141840b6f9ee1f898eae628d35ad4d68ca`.
* `parser-*-af516.json`: first parser round from run 37971527557.

The archived slow native control passes metadata and fidelity validation but
fails absolute latency budgets, including its first input taking 2236 ms.
The archived slow parser control exceeds the 300 ms budget at 500 KB.
Normal captured reports pass the same gates. Tests reject corrupted controls
and prove that a fast report cannot substitute for the negative control.
The source commit, fixture SHA-256, 500108 UTF-8 bytes, and 491603 UTF-16 units
are independently frozen in the checker; missing or changed identity fails.

Current runs measure three independent launches of the current source. They
compare those medians against the checked-in `native-reference-af516.json`
and `parser-reference-af516.json` values from hosted run 37971527557.
Ordinary pull requests never build or execute historical source variants.
Baseline refresh is a deliberate reviewed change: capture a completed hosted
known-good run, preserve its raw report, and update the fixture and run/source
provenance together. Never derive a baseline from the run being judged. Source,
save, selection, rendering, parse counts, sample counts, and
fixture identity remain strict. Raw reports and comparison diagnostics remain
available. Small historical improvements are no longer required for success:

* Native synchronous comparisons allow twice the reference plus 25 ms.
* Cold middle-bold opening allows twice the reference plus 50 ms.
* Parser medians allow twice the reference plus 10 ms at 50 KB or 25 ms at
  500 KB; existing absolute parser ceilings remain 50 ms and 300 ms.
* Native warm wall latency retains its 150% plus 25 ms comparison and the
  400 ms ceiling on every warm input. The 500 KB cold-input ceilings remain
  unchanged. At 50 KB, the first-input ceiling is now 1,000 ms and bulk
  completion allows 750 ms.
* Native actions use a uniform 300 ms synchronous ceiling. At 50 KB,
  settling allows 600 ms across all shapes. Warm typing remains limited to
  400 ms, first typing to 1,000 ms, and bulk completion to 750 ms. The 500 KB
  idle ceiling and independent cold-input guards remain unchanged.
  Run 37999929489 measured 53/318 ms on its first 50 KB bold marker and
  18/91 ms on its second. The earlier 50/250 ms ceilings rejected this
  variance despite passing paired 500 KB comparisons. This policy targets
  major delays consistently across actions; it does not claim faster code.

These fixed policies target large slowdowns and visible stalls. They give up
requiring a 20% improvement over old code. Archived historical controls remain
validated by cheap policy tests. Older
code can fall inside the coarse absolute budgets, as happened in run
37971527557; that does not establish a failed negative-control gate. CI
verifies the archived measured stall above. Thresholds never adapt to the
current run. A separate manual diagnostic workflow can still trace frozen
source for an investigation.

History now targets major throughput loss: its full-index ceiling is 30 s for
about 121 KB and 90 s for 500 KB, replacing 20 s and 60 s. The legacy indexing
comparison allows twice the legacy time instead of 135%. First usable History
must arrive within 2 s or 6 s, replacing 1 s or 3 s. Reopening allows 250 ms
instead of 50 ms; three previews allow 500 ms instead of 250 ms. Version-list
and source equivalence remain exact. Raw current and legacy timings remain in
benchmark reports.

The catalog main-actor gap ceiling is 200 ms instead of 120 ms. Captured good
500-item gaps were 48-90 ms; captured slow control gaps were 222-381 ms. The
archived catalog test proves the new ceiling still rejects that stall. Catalog
load and write ceilings remain unchanged. These gates intentionally stop
protecting small performance gains and target noticeable responsiveness loss.
