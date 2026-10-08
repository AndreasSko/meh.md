# CI test coverage

Every pull request runs the complete feasible test matrix. The
`All feasible tests` check rejects missing jobs, missing test methods,
duplicate results, unexpected skips, failures, and stale inventories.
Builds alone are not test
coverage evidence. This is test execution coverage, not line coverage.

## What changed

Previously, notebook validation ran the macOS Swift package tests and two
Python tool suites. Editor regressions selected five UIKit native suites and
11 iPhone UI methods. The parser/catalog performance workflow exercised its
opt-in benchmarks, while five other synthetic benchmark groups stayed off.
No broad iPad or macOS UI suite ran on pull requests.

The new matrix adds:

| Job | Execution and fixtures |
| --- | --- |
| Package | All debug package tests, every benchmark opt-in, HTTP server |
| Native | All UIKit native editor tests in an iPhone simulator test host |
| UI iPhone | All applicable UI tests, import, ordered cross-device sync |
| UI iPad | All applicable iPad UI tests, including hardware-keyboard cases |
| UI macOS | All applicable Mac UI tests with disposable loopback workspaces |
| Python | Every declared Python test in scripts and both tool directories |

Debug package execution includes debug-only History fixture tests. Existing
release performance checks retain their budgets and baseline comparisons.
The weekly sync workflow still exercises its larger seeded scale matrix.
Synthetic benchmarks use their existing default fixtures and repetitions;
turning them on does not change their assertions or performance ceilings.

The iCloud Dev scheme normally selects only `ICloudDevelopmentUITests`.
CI builds that scheme, then replaces its generated test selection with
explicit applicable method IDs. Every selected method must appear once in
the result evidence and pass. Python discovery covers all `test_*.py` files,
including the performance app-cache tests missed by the previous glob.

## Explicit boundaries

`ICloudDevelopmentUITests` requires signed-in Apple accounts, provisioning,
and a real CloudKit service. It remains a manual live-account test. The
CloudKit lab/device scripts also exercise real account, push, and device
behavior; their local guard unit tests run automatically. Simulator and
loopback results do not prove live iCloud or physical-device behavior.

Platform guards route phone-only keyboard/compact-navigation cases to
an iPhone and pad-only cases to an iPad. Mac History interaction cases with
an explicit iOS guard are proved on iOS. The report lists every such route;
an arbitrary `XCTSkip` never makes the coverage gate green.

`LocalSyncUITests` runs as phone publish, iPad reply, original phone reopen
with a shared unique workspace and disposable HTTP service. It is proved
once by the iPhone orchestration job rather than independently launching
stateful phases on each platform. Native Files import gets a unique
fictional folder in the owned iPhone app sandbox through the import helper.

The macOS SwiftPM host can omit the OS insertion-indicator subview. If that
single test skips, a real standalone AppKit caret probe must pass instead.
The coverage report records the replacement. Other skipped package tests,
including missing benchmark flags or unsupported immutable-file fixtures,
fail the gate.

## Evidence and API audit

Jobs preserve logs, XCTest result bundles, summaries, test IDs, and failure
attachments. Small `test-coverage-*` artifacts contain the passing method
IDs and inventory digest. The aggregate check requires all matrix jobs to
succeed and rechecks those reports against the checkout's source inventory.
Mac package evidence also compares the compiler's `swift test list` with
the source inventory and requires a start and successful terminal outcome
for every compiled test. Unsupported source declarations fail closed.

Use a clean checkout of the exact PR head, authenticate `gh`, then run:

```sh
python3 scripts/check_ci_test_coverage.py --pr 123
```

The script uses GitHub's API to inspect the latest checks at that head,
requires all coverage, release, editor regression, and performance checks,
downloads the latest PR coverage run's proof artifacts, and rechecks the
full matrix. Pending, failed, cancelled, missing, and stale evidence all
produce a nonzero exit. The output links the PR and workflow run and gives
the number of proved test executions.

An explicitly accepted failure in the separate performance guard can be
reported without disabling the complete test matrix:

```sh
python3 scripts/check_ci_test_coverage.py --pr 123 \
  --ignore-editor-performance
```

The default remains strict. This option records the ignored check's actual
conclusion and URL in the output. It cannot ignore another check, missing
coverage reports, or any package benchmark. PR #208 uses this exception
because the existing performance failure is being fixed in a separate task.

For local evidence:

```sh
scripts/run_notebook_sync_validation.sh --complete
python3 scripts/run_native_test_coverage.py
python3 scripts/run_ui_test_coverage.py --platform iphone \
  --output-dir /tmp/meh-ci-ui-evidence
python3 scripts/run_python_test_coverage.py /tmp/python-coverage-report.json
```

UI runs create and remove only their own simulators, use the iCloud Dev
build, and inject fictional isolated workspaces. Mac UI and caret checks
need an interactive desktop without another UI automation taking focus.
Before each Mac test phase, the runner rejects another native UI runner or
Dev app outside its own build products. This check cannot prevent another
thread from starting afterward. CI runs each job in its own environment.
The standard UI phase allows three hours inside a 210-minute job cap.
The full iPhone baseline completed 76 of 88 methods in 118 minutes; the
remaining Recents cases also take several minutes each. This leaves
headroom for the full suite plus build, ordered fixtures, and evidence
export. Individual assertions and performance budgets keep their limits.

Fictional debug notebooks also scope editor preferences to their preview or
loopback identity. Font, editor mode, and toolbar order persist when the
same fixture relaunches, while the next fixture starts independently. Normal
development launches, live-account checks, release builds, and performance
hosts use their existing standard preferences. This isolates editor settings;
notebook navigation already uses its notebook and scene identities.

UI helpers distinguish an existing editor from completed note naming. Save
boundary checks verify navigation away and back through visible titles and
stable Files identities, then compare the original Markdown's UTF-8 bytes.
Gesture helpers convert screen points into application-relative coordinates,
so a windowed iPad does not add its window origin twice. Existing assertions
and gesture targets remain in place.

Navigation helpers recognize both compact and regular layouts, including
expanded Recents and the iPad's Previous Note control. A retained editor
under a Trash sheet does not prove that opening an action menu navigated
away; tests verify the active Trash surface and its actions instead.
Passive fixture relaunches cross a verified note-navigation save boundary
first. Typing alone updates the editor before its debounced disk write,
so immediate process termination is not proof of a persisted fixture.

Rendered-link OCR uses the native editor's screenshot, honors its image
orientation, and maps recognized text through that same editor viewport.
It rejects mismatched geometry and keeps the input image and coordinates
as evidence. A raw screenshot can have the correct aspect ratio while its
orientation still sends a tap away from the actual link.

The native Undo and pointer-created title cases opt in to debug input
diagnostics. These record responder, selection, composition, and undo
state without recording note text or changing input behavior. CI exports
the owned simulator's filtered `native-input.log` before deleting it.
A UIKit native test separately exercises the actual cell-editor responder
command and its composition guard; it does not replace the UI Cmd-Z test.

The HTTP fixture binds numeric loopback and avoids HTTPServer's reverse-DNS
lookup, which can trigger macOS local-network discovery permission. It
requires no LAN discovery; readiness still uses the real HTTP routes.

For a local Mac runner already granted automation access, use the same
Apple Development signing identity for freshly built test runners:

```sh
MEH_MAC_UI_SIGNING_IDENTITY='your signing identity' \
  python3 scripts/run_ui_test_coverage.py --platform macos \
  --output-dir /tmp/meh-ci-mac-evidence
```

The equivalent option is `--macos-signing-identity`. Only the runner inside
that invocation's disposable build products is signed. This retains the
Dev runner bundle identifier and can reuse its existing authorization;
macOS still controls permission decisions. It does not reuse old test
binaries or store a machine-specific certificate or session path in CI.
CI uses ad-hoc signing with the runner's debugging entitlement.

The UI fixture service uses the real local sync server and an ephemeral
loopback port in the orchestration process. Readiness is proved through
an HTTP request before launching tests. Its workspace, request log, and
shutdown belong to that invocation, including when a test fails.
