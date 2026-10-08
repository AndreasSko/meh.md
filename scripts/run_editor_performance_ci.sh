#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
evidence_root="${RUNNER_TEMP:-/tmp}/editor-performance-evidence-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
mkdir -p "$evidence_root"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'evidence_root=%s\n' "$evidence_root" >> "$GITHUB_OUTPUT"
fi

baseline_root="${EDITOR_PERFORMANCE_BASELINE_ROOT:-}"
reference_root="${EDITOR_PERFORMANCE_REFERENCE_ROOT:-}"
require_control_sources() {
  local root="$1" expected="$2" label="$3"
  [[ -n "$root" && -f "$root/.git" ]] || {
    echo "A detached $label worktree is required" >&2
    exit 2
  }
  local revision
  revision="$(git -C "$root" rev-parse --verify HEAD)"
  [[ "$revision" == "$expected" ]] || {
    echo "Unexpected $label source revision: $revision" >&2
    exit 2
  }
  git -C "$root" -c core.fsmonitor=false diff --quiet HEAD -- Sources meh.md || {
    echo "$label production sources must match the frozen revision" >&2
    exit 2
  }
}
require_control_sources "$baseline_root" 1378bf5e1b9fcaf0ff5e97435a320ef7d726ef42 baseline
require_control_sources "$reference_root" 369814141840b6f9ee1f898eae628d35ad4d68ca reference
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
  local source_root="${6:-$repo_root}" control="${7:-current}"
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
  if [[ "$control" == baseline ]]; then
    # The control must preserve fidelity/structure; expected slowness is allowed.
    PYTHONPATH="$repo_root/scripts" python3 - "$report" <<'PY' 2>&1 | tee -a "$log"
import json
import sys
from check_editor_performance import check_report
with open(sys.argv[1], encoding="utf-8") as source:
    errors = check_report(json.load(source), 500, "livePreview", "standard",
                          "notebook", "standard", enforce_budgets=False)
if errors:
    sys.exit("\n".join(errors))
print("Control native fidelity and structure passed")
PY
    local check_status=${PIPESTATUS[0]}
    [[ "$check_status" == 0 ]] || return "$check_status"
  else
    # Bash 3.2 treats an empty array as unset under nounset.
    local checker_arguments=("$report" --size-kb "$size" --mode "$mode"
      --context "$context" --host notebook --shape "$shape")
    if [[ "$label" == standard-500kb ]]; then
      checker_arguments+=(--baseline-report "$evidence_root/baseline-standard-500kb.json")
    fi
    python3 "$repo_root/scripts/check_editor_performance.py" \
      "${checker_arguments[@]}" 2>&1 | tee -a "$log" || return "$?"
  fi
}

# Compile every source variant before measuring any of them. The three
# current workloads share one verified binary.
for source_root in "$baseline_root" "$reference_root" "$repo_root"; do
  EDITOR_PERFORMANCE_APP_CACHE="$app_cache_root" \
    EDITOR_PERFORMANCE_BUILD_ONLY=1 EDITOR_PERFORMANCE_HOST=notebook \
    "$source_root/scripts/run_editor_performance_check.sh" \
    "$sim_udid" working-tree livePreview 500
done

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
record_case baseline-standard-500kb 500 livePreview standard standard "$baseline_root" baseline
paired_arguments=()
attempt="${GITHUB_RUN_ATTEMPT:-1}"
[[ "$attempt" =~ ^[0-9]+$ ]] || { echo "Invalid run attempt" >&2; exit 2; }
for pair in 1 2 3; do
  suffix=""
  [[ "$pair" == 1 ]] || suffix="-$pair"
  current_label="standard-500kb$suffix"
  reference_label="reference-standard-500kb$suffix"
  paired_arguments+=(--paired-current-report "$evidence_root/$current_label.json"
    --paired-reference-report "$evidence_root/$reference_label.json")
  # Reverse order within successive pairs and across rerun attempts.
  if (( (attempt + pair) % 2 == 0 )); then
    record_case "$reference_label" 500 livePreview standard standard "$reference_root" reference
    record_case "$current_label" 500 livePreview standard standard
  else
    record_case "$current_label" 500 livePreview standard standard
    record_case "$reference_label" 500 livePreview standard standard "$reference_root" reference
  fi
done
if python3 "$repo_root/scripts/check_editor_performance.py" \
  "$evidence_root/standard-500kb.json" --size-kb 500 --host notebook \
  --context standard "${paired_arguments[@]}" \
  > "$evidence_root/paired-comparison.log" 2>&1; then
  cat "$evidence_root/paired-comparison.log"
else
  cat "$evidence_root/paired-comparison.log"
  failed_cases+=("paired comparison")
fi
record_case mixed-50kb 50 livePreview mixed standard
record_case nearby-table-50kb 50 livePreview standard nearby-table

if [[ "${#failed_cases[@]}" != 0 ]]; then
  printf 'Failed performance case: %s\n' "${failed_cases[@]}" >&2
  exit 1
fi
