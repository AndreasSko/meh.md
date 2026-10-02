# Native import regression checks

These opt-in UI tests use the real iPhone document picker. They cover multiple
Markdown files, one folder with a child note, cancellation after a successful
import, and an invalid UTF-8 error. Completion and error alerts must appear
after the picker closes. The tests skip unless the runner supplies its fixture
and localhost service environment; ordinary iCloud UI runs do not use them.

Build the iCloud Dev scheme for testing against an explicitly disposable iPhone
simulator. Replace `SIMULATOR_UDID` with that simulator's UDID:

```sh
xcodebuild build-for-testing \
  -project meh.md.xcodeproj -scheme 'meh.md iCloud Dev' \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
  -derivedDataPath /tmp/meh-import-regression

python3 Tools/Import/run_simulator_checks.py \
  --products-dir /tmp/meh-import-regression/Build/Products \
  --simulator SIMULATOR_UDID \
  --output-dir /tmp/meh-import-evidence
```

The runner installs only the iCloud Dev build on the supplied simulator. It
creates a uniquely named fictional source directory in the app's Documents
folder, a separate loopback notebook for each test, and its own localhost
server on an unused port. It removes only its source directory and temporary
test plan, stops its server, and restores the simulator to shutdown if it
booted it. It does not erase the simulator or remove notebook data. Use a
disposable simulator with no personal data; delete it afterward if desired.

The evidence directory retains XCTest logs, the result bundle, screenshots, and
a verification report. App labels are tested in English; native picker labels
support English and German. No scheme changes or production fixture code are
needed.
