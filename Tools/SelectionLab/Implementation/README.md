# Production selection-scroll probe

This archive exercises the narrower animated-offset guard in the native
MarkdownEditor. It uses an 80-paragraph fictional note and creates a range
with a real double-tap after manually scrolling. The probe reads native
selection, offset, and geometry; it does not set selection or force layout.

The temporary integration patch targets MyApp.swift and
NotebookAppDelegate.swift from main `03b41f3`. It bypasses
NotebookWorkspace, backup scheduling, and sync. Apply it only in an
isolated diagnostic checkout. Copy SelectionImplementationLab.swift into
meh.md and SelectionImplementationLabUITests.swift into meh.mdUITests.
Build with the iCloud Dev scheme. Reverse the patch and remove the staged
files before a normal build. This diagnostic host uses fictional content
and must never open personal or development notes.

## User-visible checks

The app route requires `MEH_SELECTION_IMPLEMENTATION=1`. The UI test sets
that itself and selects Source or Live Preview with
`LAB_EDITOR=source` or `LAB_EDITOR=livePreview`.
`LAB_CAPTURE=before` records the baseline without asserting suppression.
Without it, the test checks edge suppression and range retention. Captures
use the same fictional note and native handle gesture. Read the screenshots
with the UTF-16 range and offset traces; test completion alone is not
behavioral acceptance.

The current diagnostic host presents the editor in a view controller with
a vertical stack whose safe area shrinks above the keyboard. Production
ignores the keyboard safe area only while Find is presented; the host
mirrors this condition. It remains a focused probe, not the full screen.

## Reproducible native-editor tests

Swift package tests need an iOS application host for UIKit scrolling. The
command-line package runner has no connected `UIWindowScene`; these six
tests skip there. Avoid an Xcode scheme collision by making a temporary
package workspace containing symlinks to `Package.swift`, `Package.resolved`,
`Sources`, `Tests`, and `meh.md` from this checkout. Use a task-owned path
under `/tmp`, for example `/tmp/meh-selection-package`.

Build the iCloud Dev app for the simulator with the staged integration
patch and archived Swift files. Build `NativeEditorTests` from the linked
package workspace using scheme `MehCore-Package`. For example, use separate
derived data directories under `/tmp/sel-app` and `/tmp/sel-pkg`:

```sh
selection_repo="$PWD"
xcodebuild -project meh.md.xcodeproj \
  -scheme 'meh.md iCloud Dev' \
  -configuration Debug-iCloud \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/sel-app \
  build
cd /tmp/meh-selection-package
xcodebuild -scheme MehCore-Package \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/sel-pkg \
  build-for-testing
cd "$selection_repo"
python3 Tools/SelectionLab/Implementation/prepare_hosted_tests.py \
  --app-host /tmp/sel-app/Build/Products/Debug-iCloud-iphonesimulator/\
meh.md.app \
  --test-run /tmp/sel-pkg/Build/Products/MehCore-Package_MehCore-Package_\
iphonesimulator27.0-arm64.xctestrun \
  --output-dir /tmp/meh-selection-host/prepared
xcodebuild test-without-building \
  -xctestrun /tmp/meh-selection-host/prepared/selection-hosted.xctestrun \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_ID>'
```

Replace `<SIMULATOR_ID>` with the task's simulator ID. Confirm the generated
xctestrun filename under the package derived-data `Build/Products` directory
and use that exact path; the architecture suffix can vary. The preparation
script restricts the run to `MarkdownSelectionScrollingTests`. Keep staged
files and result bundles in task-owned temporary paths. Do not install on a
personal device.

The package workspace contains the shared production source, so it tests
the same MarkdownTextView implementation as the app. The hosted fixture
uses a connected UIWindowScene because the package runner cannot drive
UIKit scroll animations. An explicit range reveal must be observed after
the native scroll animation settles.

## Evidence status

All six focused app-hosted UIKit regression tests passed with zero skips.
The macOS native-editor suite ran 293 tests with zero failures and two skips.
The final iCloud Dev build passed after removing the diagnostic launch hooks.

The latest Live Preview run passed edge suppression, manual scrolling with
exact range retention, returning to the handle, anchored adjustment, and
exact replacement. Source had a passing continuation/replacement run, but
later return gestures changed the range or failed to grab the handle. The
full native gesture sequence is not established reliably in Source.

Find visibility failed in both the candidate and unchanged main with this
host. This does not establish a regression caused by the selection guard,
and normal-screen Find coverage remains required. A temporary combined
build with PR #202 at a810015 compiled, but its handle gesture did not change
the range, and Find failed. Combined gesture acceptance remains unverified.

The temporary integration patch bypasses workspace startup, backup
scheduling, and sync. The candidate also has not been verified on physical
iPhone or iPad. See `docs/investigations/selection-autoscroll.md` for the
broader experiment and its evidence limits.
