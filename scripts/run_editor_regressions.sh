#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
task_temp="${RUNNER_TEMP:-/tmp}"
evidence_root="$(mktemp -d "$task_temp/editor-regression-evidence.XXXXXX")"
work_root="$(mktemp -d "$task_temp/editor-regression-work.XXXXXX")"
sim_udid=""
record_pid=""
record_path=""
collected_results=" "
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'evidence_root=%s\n' "$evidence_root" >> "$GITHUB_OUTPUT"
fi
printf 'Regression evidence: %s\n' "$evidence_root"

stop_recording() {
  if [[ -n "$record_pid" ]]; then
    kill -INT "$record_pid" 2>/dev/null || true
    wait "$record_pid" 2>/dev/null || true
    record_pid=""
  fi
}

collect_result() {
  local phase="$1" bundle="$evidence_root/$1.xcresult"
  [[ -d "$bundle" ]] || return 0
  [[ "$collected_results" != *" $phase "* ]] || return 0
  xcrun xcresulttool get test-results summary --path "$bundle" \
    > "$evidence_root/$phase-summary.json" || true
  xcrun xcresulttool get test-results tests --path "$bundle" \
    > "$evidence_root/$phase-tests.json" || true
  xcrun xcresulttool export attachments --path "$bundle" \
    --output-path "$evidence_root/$phase-attachments" || true
  collected_results+="$phase "
}

cleanup() {
  local status=$?
  [[ "$BASH_SUBSHELL" == 0 ]] || return "$status"
  trap - EXIT INT TERM
  set +e
  stop_recording
  collect_result native
  collect_result ui
  if [[ -n "$sim_udid" ]]; then
    xcrun simctl shutdown "$sim_udid" >/dev/null 2>&1
    xcrun simctl delete "$sim_udid" >/dev/null 2>&1
  fi
  rm -rf "$work_root"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

xcodebuild -version | tee "$evidence_root/toolchain.txt"
grep -Eq '^Xcode 27([. ]|$)' "$evidence_root/toolchain.txt"
git -C "$repo_root" rev-parse HEAD > "$evidence_root/checkout.txt"
git -C "$repo_root" -c core.fsmonitor=false status --short \
  >> "$evidence_root/checkout.txt"
(
  cd "$repo_root"
  shasum -a 256 meh.md/MarkdownEditor.swift meh.md/MarkdownPresentation.swift \
    meh.md/NotebookNoteEditor.swift
) > "$evidence_root/production-sha256.txt"
xcrun simctl list --json > "$evidence_root/simulators.json"
read -r runtime_id device_type < <(python3 - "$evidence_root/simulators.json" <<'PY'
import json
import sys

inventory = json.load(open(sys.argv[1], encoding="utf-8"))
runtimes = [runtime for runtime in inventory.get("runtimes", [])
            if runtime.get("isAvailable")
            and runtime.get("identifier", "").startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
            and str(runtime.get("version", "")).split(".")[0] == "27"]
devices = [device for device in inventory.get("devicetypes", [])
           if device.get("identifier") == "com.apple.CoreSimulator.SimDeviceType.iPhone-12-Pro-Max"]
if not runtimes or len(devices) != 1:
    sys.exit("An available iOS 27 runtime and iPhone 12 Pro Max type are required")
runtime = max(runtimes, key=lambda item: tuple(map(int, item["version"].split("."))))
print(runtime["identifier"], devices[0]["identifier"])
PY
)
sim_udid="$(xcrun simctl create "EditorRegressions-$(basename "$work_root")" \
  "$device_type" "$runtime_id")"
printf '%s\n' "$sim_udid" > "$evidence_root/owned-simulator.txt"
xcrun simctl boot "$sim_udid"
xcrun simctl bootstatus "$sim_udid" -b

# A package-only directory avoids choosing the adjacent app project scheme.
package_root="$work_root/package"
mkdir -p "$package_root"
for entry in Sources Tests meh.md; do
  ln -s "$repo_root/$entry" "$package_root/$entry"
done
cp "$repo_root/Package.swift" "$package_root/Package.swift"
cat >> "$package_root/Package.swift" <<'SWIFT'

// Keep the existing native editor test graph; omit unrelated app-model tests.
package.products.removeAll { $0.name == "NotebookAppModel" }
package.targets.removeAll {
    ["NotebookAppModel", "NotebookAppModelTests", "NoteCoreTests"].contains($0.name)
}
SWIFT
printf '%s\n' 'product: NotebookAppModel' \
  'targets: NotebookAppModel, NotebookAppModelTests, NoteCoreTests' \
  > "$evidence_root/native-manifest-filter.txt"
(
  printf 'Original checkout manifest:\n'
  cd "$repo_root"
  shasum -a 256 Package.swift
  printf 'Temporary native-test manifest:\n'
  cd "$package_root"
  shasum -a 256 Package.swift
) > "$evidence_root/native-manifest-sha256.txt"
cp "$package_root/Package.swift" "$evidence_root/native-package.swift"
if [[ -f "$repo_root/Package.resolved" ]]; then
  cp "$repo_root/Package.resolved" "$package_root/Package.resolved"
fi
(
  cd "$package_root"
  xcodebuild build-for-testing -scheme MehCore-Package \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$work_root/native-build" CODE_SIGNING_ALLOWED=NO
) 2>&1 | tee "$evidence_root/native-build.log"
native_run="$(python3 - "$work_root/native-build/Build/Products" <<'PY'
from pathlib import Path
import sys

paths = list(Path(sys.argv[1]).glob("MehCore-Package_*iphonesimulator*.xctestrun"))
if len(paths) != 1:
    sys.exit(f"Expected one native package test run, found {len(paths)}")
print(paths[0])
PY
)"

run_phase() {
  local phase="$1"
  shift
  record_path="$evidence_root/$phase-failure.mp4"
  xcrun simctl io "$sim_udid" recordVideo --codec=h264 "$record_path" \
    > "$evidence_root/$phase-recording.log" 2>&1 &
  record_pid=$!
  sleep 1
  if ! kill -0 "$record_pid" 2>/dev/null; then
    wait "$record_pid" 2>/dev/null || true
    record_pid=""
    printf '%s: recording exited before tests; see %s\n' \
      "$phase" "$evidence_root/$phase-recording.log" >&2
    return 1
  fi
  set +e
  "$@" 2>&1 | tee "$evidence_root/$phase-test.log"
  local status=${PIPESTATUS[0]}
  set -e
  stop_recording
  collect_result "$phase"
  if [[ "$status" != 0 ]]; then
    return "$status"
  fi
  python3 "$repo_root/scripts/check_editor_regression_results.py" "$phase" \
    "$evidence_root/$phase-summary.json" "$evidence_root/$phase-tests.json"
  rm -f "$record_path"
}

run_phase native xcodebuild test-without-building -xctestrun "$native_run" \
  -destination "platform=iOS Simulator,id=$sim_udid" \
  -only-testing:NativeEditorTests/MarkdownEditorScrollPaddingTests \
  -only-testing:NativeEditorTests/MarkdownParagraphGapTests \
  -only-testing:NativeEditorTests/MarkdownHeadingGeometryTests \
  -only-testing:NativeEditorTests/MarkdownRenderingAttributeTests \
  -only-testing:NativeEditorTests/NativeEditorIntegrationTests \
  -parallel-testing-enabled NO -resultBundlePath "$evidence_root/native.xcresult"

run_phase ui xcodebuild test -project "$repo_root/meh.md.xcodeproj" \
  -scheme 'meh.md iCloud Dev' -destination "platform=iOS Simulator,id=$sim_udid" \
  -derivedDataPath "$work_root/ui-build" CODE_SIGNING_ALLOWED=NO \
  -only-testing:meh.mdUITests/EditorScrollTypingUITests/testSourceReopeningKeyboardNearEndRevealsCaret \
  -only-testing:meh.mdUITests/EditorScrollTypingUITests/testLivePreviewReopeningKeyboardNearEndRevealsCaret \
  -only-testing:meh.mdUITests/EditorScrollTypingUITests/testSourceTypingAtEndKeepsCaretStable \
  -only-testing:meh.mdUITests/EditorScrollTypingUITests/testLivePreviewTypingAtEndKeepsCaretStable \
  -only-testing:meh.mdUITests/EditorScrollTypingUITests/testLivePreviewListReturnAtEndKeepsCaretStable \
  -only-testing:meh.mdUITests/EditorScrollTypingUITests/testLivePreviewTypingOnEmptyEndLineKeepsCaretStable \
  -only-testing:meh.mdUITests/EditorLongNoteTapUITests/testTapNearEndReplacesPreviousEOFSelection \
  -parallel-testing-enabled NO -resultBundlePath "$evidence_root/ui.xcresult"
