#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
evidence_root="${RUNNER_TEMP:-/tmp}/editor-performance-evidence-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
mkdir -p "$evidence_root"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'evidence_root=%s\n' "$evidence_root" >> "$GITHUB_OUTPUT"
fi

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
  xcrun simctl shutdown "$sim_udid" >/dev/null 2>&1 || true
  xcrun simctl delete "$sim_udid" >/dev/null 2>&1 || true
}
trap cleanup EXIT

run_case() {
  local label="$1" size="$2" mode="$3" context="$4"
  local report="$evidence_root/${label}.json"
  local log="$evidence_root/${label}.log"
  printf 'Running %s: %s KB, %s, context=%s\n' "$label" "$size" "$mode" "$context"
  set +e
  EDITOR_PERFORMANCE_CONTEXT="$context" \
    "$repo_root/scripts/run_editor_performance_check.sh" \
    "$sim_udid" working-tree "$mode" "$size" "$report" large-note \
    2>&1 | tee "$log"
  local run_status=${PIPESTATUS[0]}
  set -e
  if [[ $run_status -ne 0 ]]; then
    printf '%s runner failed with status %s\n' "$label" "$run_status" >&2
    return "$run_status"
  fi
  python3 "$repo_root/scripts/check_editor_performance.py" \
    "$report" --size-kb "$size" --mode "$mode" --context "$context" \
    2>&1 | tee -a "$log"
}

run_case mixed-50kb 50 livePreview mixed
run_case standard-500kb 500 livePreview standard
