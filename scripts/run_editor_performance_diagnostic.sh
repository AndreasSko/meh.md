#!/bin/bash
# Remote CI only: one unscored optimized-reference replay with a bounded trace.
set -euo pipefail
[[ "${CI:-}" == true ]] || { echo "Diagnostic is restricted to CI" >&2; exit 2; }
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
: "${EDITOR_PERFORMANCE_REFERENCE_ROOT:?reference worktree required}"
: "${RUNNER_TEMP:?runner evidence directory required}"
reference="$EDITOR_PERFORMANCE_REFERENCE_ROOT"
[[ "$(git -C "$reference" rev-parse HEAD)" == 369814141840b6f9ee1f898eae628d35ad4d68ca ]] || exit 2
git -C "$reference" -c core.fsmonitor=false diff --quiet HEAD -- Sources meh.md
root="$RUNNER_TEMP/editor-performance-diagnostic-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
mkdir -p "$root"
printf '%s\n' 'Unscored diagnostic; original wall-clock failure remains authoritative.' > "$root/status.txt"
# Reuse the exact runtime/type inventory of the scored disposable simulator.
inventory="${EDITOR_PERFORMANCE_DIAGNOSTIC_INVENTORY:-$RUNNER_TEMP/editor-performance-evidence-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}/simulators.json}"
read -r runtime device_type < <(python3 - "$inventory" <<'PYCODE'
import json, sys
inventory = json.load(open(sys.argv[1]))
runtimes = [r for r in inventory["runtimes"] if r.get("isAvailable")
            and ".iOS-" in r["identifier"] and int(r["version"].split(".")[0]) >= 27]
runtime = max(runtimes, key=lambda r: tuple(map(int, r["version"].split("."))))
device = next(d for d in inventory["devices"][runtime["identifier"]]
              if d.get("isAvailable") and "iPhone" in d.get("deviceTypeIdentifier", ""))
print(runtime["identifier"], device["deviceTypeIdentifier"])
PYCODE
)
simulator="$(xcrun simctl create "EditorDiagnostic-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}" "$device_type" "$runtime")"
probe_pid="" trace_pid="" watchdog_pid=""
cleanup() {
  status=$?
  for pid in "$probe_pid" "$trace_pid" "$watchdog_pid"; do
    [[ -z "$pid" ]] || kill "$pid" >/dev/null 2>&1 || true
  done
  xcrun simctl shutdown "$simulator" >/dev/null 2>&1 || true
  xcrun simctl delete "$simulator" >/dev/null 2>&1 || true
  printf 'Diagnostic exit status: %s\n' "$status" >> "$root/status.txt"
}
trap cleanup EXIT
trap 'echo "Diagnostic interrupted or timed out" >> "$root/status.txt"; exit 1' TERM INT
# Bound setup, attachment and report collection too; never wait the probe's 360s.
(
  sleeper=""
  trap '[[ -z "$sleeper" ]] || kill "$sleeper" 2>/dev/null || true; exit 0' TERM INT
  sleep 240 & sleeper=$!
  wait "$sleeper"
  kill -TERM "$$"
) & watchdog_pid=$!
EDITOR_PERFORMANCE_APP_CACHE="${EDITOR_PERFORMANCE_DIAGNOSTIC_APP_CACHE:-$RUNNER_TEMP/editor-performance-app-cache-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}}" \
EDITOR_PERFORMANCE_REQUIRE_CACHED_APP=1 EDITOR_PERFORMANCE_HOST=notebook \
EDITOR_PERFORMANCE_START_DELAY_SECONDS=30 \
EDITOR_PERFORMANCE_DIAGNOSTIC_KEEP_ALIVE_SECONDS=60 \
EDITOR_PERFORMANCE_LAUNCH_PID_FILE="$root/launch.pid" \
  "$reference/scripts/run_editor_performance_check.sh" "$simulator" working-tree \
  livePreview 500 "$root/reference-unscored.json" large-note \
  > "$root/probe.log" 2>&1 & probe_pid=$!
for ((attempt=0; attempt<120; attempt++)); do
  [[ ! -f "$root/launch.pid" ]] || break
  kill -0 "$probe_pid" 2>/dev/null || { cat "$root/probe.log"; exit 1; }
  sleep 1
done
[[ -f "$root/launch.pid" ]] || { echo "No observed disposable probe PID" >&2; exit 1; }
read -r attached_pid < "$root/launch.pid"
[[ "$attached_pid" =~ ^[0-9]+$ ]] || exit 1
# PID originates only from simctl launch on this newly owned simulator.
xcrun xctrace record --template 'Time Profiler' --device "$simulator" \
  --attach "$attached_pid" --time-limit 60s --no-prompt \
  --output "$root/optimized-reference.trace" > "$root/xctrace.log" 2>&1 & trace_pid=$!
trace_status=0
wait "$trace_pid" || trace_status=$?
trace_pid=""
probe_status=0
wait "$probe_pid" || probe_status=$?
probe_pid=""
if [[ "$probe_status" == 0 ]]; then
  PYTHONPATH="$repo_root/scripts" python3 - "$root/reference-unscored.json" <<'PYCODE' > "$root/fidelity.log" 2>&1 || probe_status=$?
import json
import sys
from check_editor_performance import check_report
with open(sys.argv[1], encoding="utf-8") as source:
    report = json.load(source)
errors = check_report(report, 500, "livePreview", "standard", "notebook",
                      "standard", enforce_budgets=False)
if errors:
    sys.exit("\n".join(errors))
print("Unscored diagnostic fidelity and structure passed")
PYCODE
fi
cat "$root/xctrace.log" "$root/probe.log"
printf 'Trace status: %s; probe status: %s\n' "$trace_status" "$probe_status" >> "$root/status.txt"
[[ "$trace_status" == 0 && "$probe_status" == 0 && -d "$root/optimized-reference.trace" ]]
