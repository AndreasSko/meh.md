#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
baseline_revision=64a72671e3dd8fc31905f15d9a4e08fe3ca8b678
task_temp="${RUNNER_TEMP:-/tmp}"
evidence_root="$(mktemp -d "$task_temp/native-editor-parity-evidence.XXXXXX")"
work_root="$(mktemp -d "$task_temp/native-editor-parity-work.XXXXXX")"
baseline_root="$work_root/baseline-source"
sim_udid=""
baseline_registered=0
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'evidence_root=%s\n' "$evidence_root" >> "$GITHUB_OUTPUT"
fi
printf 'Native parity evidence: %s\n' "$evidence_root"

collect_result() {
  local label="$1" bundle="$evidence_root/$1.xcresult"
  [[ -d "$bundle" ]] || return 0
  xcrun xcresulttool get test-results summary --path "$bundle" \
    > "$evidence_root/$label-summary.json" || true
  xcrun xcresulttool get test-results tests --path "$bundle" \
    > "$evidence_root/$label-tests.json" || true
}
cleanup() {
  local status=$?
  [[ "$BASH_SUBSHELL" == 0 ]] || return "$status"
  trap - EXIT INT TERM
  set +e
  collect_result baseline
  collect_result current
  if [[ -n "$sim_udid" ]]; then
    xcrun simctl shutdown "$sim_udid" >/dev/null 2>&1
    xcrun simctl delete "$sim_udid" >/dev/null 2>&1
  fi
  if [[ "$baseline_registered" == 1 ]]; then
    git -C "$repo_root" worktree remove --force "$baseline_root"
  fi
  rm -rf "$work_root"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

git -C "$repo_root" worktree add --detach "$baseline_root" "$baseline_revision"
baseline_registered=1
[[ "$(git -C "$baseline_root" rev-parse HEAD)" == "$baseline_revision" ]]
git -C "$repo_root" rev-parse HEAD > "$evidence_root/current-revision.txt"
printf '%s\n' "$baseline_revision" > "$evidence_root/baseline-revision.txt"
xcodebuild -version > "$evidence_root/toolchain.txt"
grep -Eq '^Xcode 27([. ]|$)' "$evidence_root/toolchain.txt"
xcrun simctl list --json > "$evidence_root/simulators.json"
runtime_id="$(python3 - "$evidence_root/simulators.json" <<'PY'
import json
import sys
inventory = json.load(open(sys.argv[1], encoding="utf-8"))
runtimes = [r for r in inventory.get("runtimes", [])
            if r.get("isAvailable") and r.get("version") == "27.0"
            and r.get("identifier", "").startswith("com.apple.CoreSimulator.SimRuntime.iOS-")]
types = [t for t in inventory.get("devicetypes", [])
         if t.get("identifier") == "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"]
if len(runtimes) != 1 or len(types) != 1:
    sys.exit("Available iPhone 18 Pro / iOS 27.0 is required")
print(runtimes[0]["identifier"])
PY
)"
sim_udid="$(xcrun simctl create "NativeParity-$(basename "$work_root")" \
  com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro "$runtime_id")"
printf '%s\n' "$sim_udid" > "$evidence_root/owned-simulator.txt"
xcrun simctl boot "$sim_udid"
xcrun simctl bootstatus "$sim_udid" -b

run_variant() {
  local label="$1" source_root="$2" package_root="$work_root/$1-package"
  local derived="$work_root/$1-build"
  # Frozen production and tests remain unchanged; only the temporary manifest
  # is filtered to the standalone native graph used by the regression job.
  git -C "$source_root" -c core.fsmonitor=false diff --quiet HEAD -- \
    Sources Tests meh.md Package.swift Package.resolved || return 2
  mkdir -p "$package_root"
  for entry in Sources Tests meh.md; do
    ln -s "$source_root/$entry" "$package_root/$entry"
  done
  cp "$source_root/Package.swift" "$package_root/Package.swift"
  cat >> "$package_root/Package.swift" <<'SWIFT'

package.products.removeAll { $0.name == "NotebookAppModel" }
package.targets.removeAll {
    ["NotebookAppModel", "NotebookAppModelTests", "NoteCoreTests"].contains($0.name)
}
SWIFT
  cp "$package_root/Package.swift" "$evidence_root/$label-package.swift"
  if [[ -f "$source_root/Package.resolved" ]]; then
    cp "$source_root/Package.resolved" "$package_root/Package.resolved"
  fi
  (
    cd "$package_root"
    xcodebuild build-for-testing -scheme MehCore-Package \
      -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" \
      CODE_SIGNING_ALLOWED=NO \
      'OTHER_SWIFT_FLAGS=$(inherited) -D ICLOUD_ENABLED -D ICLOUD_DEV'
  ) 2>&1 | tee "$evidence_root/$label-build.log"
  local build_status=${PIPESTATUS[0]}
  [[ "$build_status" == 0 ]] || return "$build_status"
  local test_run
  test_run="$(python3 - "$derived/Build/Products" <<'PY'
from pathlib import Path
import sys
paths = list(Path(sys.argv[1]).glob("MehCore-Package_*iphonesimulator*.xctestrun"))
if len(paths) != 1:
    sys.exit(f"Expected one native test run, found {len(paths)}")
print(paths[0])
PY
)" || return 2
  xcodebuild test-without-building -xctestrun "$test_run" \
    -destination "platform=iOS Simulator,id=$sim_udid" \
    -only-testing:NativeEditorTests -parallel-testing-enabled NO \
    -collect-test-diagnostics never -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 30 \
    -maximum-test-execution-time-allowance 60 \
    -resultBundlePath "$evidence_root/$label.xcresult" \
    2>&1 | tee "$evidence_root/$label-test.log"
  local test_status=${PIPESTATUS[0]}
  printf '%s\n' "$test_status" > "$evidence_root/$label-status.txt"
  collect_result "$label"
  git -C "$source_root" -c core.fsmonitor=false diff --quiet HEAD -- \
    Sources Tests meh.md Package.swift Package.resolved || return 2
  # An ordinary assertion failure remains evidence for the parity checker.
  [[ "$test_status" == 0 || "$test_status" == 65 ]] || return "$test_status"
}

failed_variants=()
for label in baseline current; do
  source_root="$repo_root"
  [[ "$label" != baseline ]] || source_root="$baseline_root"
  if run_variant "$label" "$source_root"; then
    :
  else
    failed_variants+=("$label")
  fi
done
if [[ "${#failed_variants[@]}" != 0 ]]; then
  printf 'Native parity infrastructure/build failure: %s\n' "${failed_variants[@]}" >&2
  exit 1
fi
python3 "$repo_root/scripts/check_native_editor_baseline_parity.py" "$evidence_root" \
  2>&1 | tee "$evidence_root/comparison.log"
