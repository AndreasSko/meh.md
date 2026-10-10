#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
evidence_root="${RUNNER_TEMP:-/tmp}/editor-performance-evidence-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
mkdir -p "$evidence_root"
cp "$repo_root/scripts/fixtures/performance/native-reference-af516.json" \
  "$evidence_root/recorded-reference.json"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'evidence_root=%s\n' "$evidence_root" >> "$GITHUB_OUTPUT"
fi

app_cache_root="${RUNNER_TEMP:-/tmp}/editor-performance-app-cache-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
inventory="$evidence_root/simulators.json"
xcrun simctl list --json > "$inventory"
read -r runtime_id device_type < <(python3 - "$inventory" <<'PY'
import json
import sys

inventory = json.load(open(sys.argv[1], encoding="utf-8"))
runtimes = [r for r in inventory.get("runtimes", [])
            if r.get("isAvailable") and r.get("identifier", "").startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
            and int(r.get("version", "0").split(".")[0]) >= 27]
if not runtimes:
    raise SystemExit("No available iOS 27 simulator runtime")
runtime = sorted(runtimes, key=lambda r: tuple(map(int, r["version"].split("."))))[-1]
for device in inventory.get("devices", {}).get(runtime["identifier"], []):
    device_type = device.get("deviceTypeIdentifier", "")
    if device.get("isAvailable") and "iPhone" in device_type:
        print(runtime["identifier"], device_type)
        raise SystemExit(0)
raise SystemExit("No available iPhone simulator device type in inventory")
PY
)
sim_name="EditorPerformance-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
sim_udid="$(xcrun simctl create "$sim_name" "$device_type" "$runtime_id")"
cleanup() {
  # A pipeline subshell must not tear down the parent run's simulator.
  [[ "$BASH_SUBSHELL" == 0 ]] || return 0
  xcrun simctl shutdown "$sim_udid" >/dev/null 2>&1 || true
  xcrun simctl delete "$sim_udid" >/dev/null 2>&1 || true
}
trap cleanup EXIT

run_case() {
  local label="$1" size="$2" mode="$3" context="$4" shape="$5"
  local source_root="$repo_root"
  local report="$evidence_root/${label}.json"
  local log="$evidence_root/${label}.log"
  printf 'Running %s: %s KB, %s, context=%s\n' "$label" "$size" "$mode" "$context"
  set +e
  EDITOR_PERFORMANCE_APP_CACHE="$app_cache_root" \
    EDITOR_PERFORMANCE_HOST=notebook \
    EDITOR_PERFORMANCE_CONTEXT="$context" \
    EDITOR_PERFORMANCE_SHAPE="$shape" \
    "$source_root/scripts/run_editor_performance_check.sh" \
    "$sim_udid" working-tree "$mode" "$size" "$report" large-note \
    2>&1 | tee "$log"
  local run_status=${PIPESTATUS[0]}
  set -e
  if [[ $run_status -ne 0 ]]; then
    printf '%s runner failed with status %s\n' "$label" "$run_status" >&2
    return "$run_status"
  fi
  python3 "$repo_root/scripts/check_editor_performance.py" "$report" \
    --size-kb "$size" --mode "$mode" --context "$context" \
    --host notebook --shape "$shape" 2>&1 | tee -a "$log" || return "$?"
}

# Compile the current source once; all workloads reuse this binary.
EDITOR_PERFORMANCE_APP_CACHE="$app_cache_root" \
  EDITOR_PERFORMANCE_BUILD_ONLY=1 EDITOR_PERFORMANCE_HOST=notebook \
  "$repo_root/scripts/run_editor_performance_check.sh" \
  "$sim_udid" working-tree livePreview 500

failed_cases=()
record_case() {
  local label="$1"
  if run_case "$@"; then
    return 0
  else
    local status=$?
    failed_cases+=("$label (status $status)")
    return 0
  fi
}
current_arguments=()
for run in 1 2 3; do
  label="standard-500kb-$run"
  current_arguments+=(--current-report "$evidence_root/$label.json")
  record_case "$label" 500 livePreview standard standard
done
if ! python3 "$repo_root/scripts/check_editor_performance.py" \
  "$evidence_root/standard-500kb-1.json" --size-kb 500 --host notebook \
  --context standard --recorded-reference "${current_arguments[@]}" \
  2>&1 | tee "$evidence_root/recorded-comparison.log"; then
  failed_cases+=("recorded baseline comparison")
fi
record_case mixed-50kb 50 livePreview mixed standard
record_case nearby-table-50kb 50 livePreview standard nearby-table

if [[ "${#failed_cases[@]}" != 0 ]]; then
  printf 'Failed performance case: %s\n' "${failed_cases[@]}" >&2
  exit 1
fi
