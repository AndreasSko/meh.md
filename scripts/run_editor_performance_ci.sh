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
require_control_sources "$reference_root" 0dcaea9eeef6d635604c4d8570c9a2af983b0d73 reference
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
  if [[ "$control" != current ]]; then
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
  else
    # Bash 3.2 treats an empty array as unset under nounset.
    local checker_arguments=("$report" --size-kb "$size" --mode "$mode"
      --context "$context" --host notebook --shape "$shape")
    if [[ "$size" == 500 && "$shape" == standard && "$context" == standard ]]; then
      checker_arguments+=(--baseline-report "$evidence_root/baseline-standard-500kb.json"
        --reference-report "$evidence_root/reference-standard-500kb.json")
    fi
    python3 "$repo_root/scripts/check_editor_performance.py" \
      "${checker_arguments[@]}" 2>&1 | tee -a "$log" || return "$?"
  fi
}

run_case baseline-standard-500kb 500 livePreview standard standard "$baseline_root" baseline
run_case reference-standard-500kb 500 livePreview standard standard "$reference_root" reference
run_case mixed-50kb 50 livePreview mixed standard
run_case standard-500kb 500 livePreview standard standard
run_case nearby-table-50kb 50 livePreview standard nearby-table
