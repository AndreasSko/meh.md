#!/bin/bash
# A clean CI job: one prebuilt frozen Dev probe, never a scored retry.
set -euo pipefail
[[ "${CI:-}" == true ]] || { echo "Diagnostic is restricted to CI" >&2; exit 2; }
: "${RUNNER_TEMP:?runner evidence directory required}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
reference_revision=369814141840b6f9ee1f898eae628d35ad4d68ca
evidence_root="$RUNNER_TEMP/editor-performance-diagnostic-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
mkdir -p "$evidence_root"
work_root="$(mktemp -d "$RUNNER_TEMP/editor-fresh-diagnostic-work.XXXXXX")"
reference_root="$work_root/reference"
registered=0
watchdog_pid=""
child_pid=""
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'evidence_root=%s\n' "$evidence_root" >> "$GITHUB_OUTPUT"
fi
printf '%s\n' 'CI-only, unscored diagnostic; no performance budget decision.' \
  > "$evidence_root/fresh-status.txt"
cleanup() {
  local status=$?
  [[ "$BASH_SUBSHELL" == 0 ]] || return "$status"
  trap - EXIT INT TERM
  set +e
  [[ -z "$child_pid" ]] || kill -TERM "$child_pid" 2>/dev/null
  [[ -z "$watchdog_pid" ]] || kill "$watchdog_pid" 2>/dev/null
  if [[ "$registered" == 1 ]]; then
    git -C "$repo_root" worktree remove --force "$reference_root"
  fi
  rm -rf "$work_root"
  printf 'Fresh diagnostic exit status: %s\n' "$status" >> "$evidence_root/fresh-status.txt"
  exit "$status"
}
trap cleanup EXIT
trap 'echo "Fresh diagnostic interrupted or timed out" >> "$evidence_root/fresh-status.txt"; exit 1' TERM INT
# Bound compilation/setup as well as the child diagnostic's 240-second bound.
(
  sleeper=""
  trap '[[ -z "$sleeper" ]] || kill "$sleeper" 2>/dev/null || true; exit 0' TERM INT
  sleep 800 & sleeper=$!
  wait "$sleeper"
  kill -TERM "$$"
) & watchdog_pid=$!

git -C "$repo_root" worktree add --detach "$reference_root" "$reference_revision" \
  > "$evidence_root/worktree.log" 2>&1
registered=1
[[ "$(git -C "$reference_root" rev-parse HEAD)" == "$reference_revision" ]] || {
  echo "Unexpected frozen reference revision" >&2; exit 2;
}
git -C "$reference_root" -c core.fsmonitor=false diff --quiet HEAD -- Sources meh.md
printf '%s\n' "$reference_revision" > "$evidence_root/reference-revision.txt"
git -C "$repo_root" rev-parse HEAD > "$evidence_root/harness-revision.txt"
mkdir -p "$reference_root/Tools/EditorQuoteCheck" "$reference_root/scripts"
cp -R "$repo_root/Tools/EditorQuoteCheck/." "$reference_root/Tools/EditorQuoteCheck/"
cp "$repo_root/scripts/run_editor_performance_check.sh" \
  "$repo_root/scripts/editor_performance_app_cache.py" "$reference_root/scripts/"
cache_root="$work_root/app-cache"
EDITOR_PERFORMANCE_APP_CACHE="$cache_root" EDITOR_PERFORMANCE_BUILD_ONLY=1 \
  EDITOR_PERFORMANCE_HOST=notebook \
  "$reference_root/scripts/run_editor_performance_check.sh" unused working-tree \
  livePreview 500 "$evidence_root/reference-unscored.json" large-note \
  > "$evidence_root/prebuild.log" 2>&1 & child_pid=$!
wait "$child_pid"
child_pid=""
# Retain the verified optimized binary and debug information for offline tracing.
cp -R "$cache_root" "$evidence_root/compiled-probe-cache"
git -C "$reference_root" -c core.fsmonitor=false diff --quiet HEAD -- Sources meh.md
xcrun simctl list --json > "$evidence_root/simulators.json"
EDITOR_PERFORMANCE_REFERENCE_ROOT="$reference_root" \
  EDITOR_PERFORMANCE_DIAGNOSTIC_INVENTORY="$evidence_root/simulators.json" \
  EDITOR_PERFORMANCE_DIAGNOSTIC_APP_CACHE="$cache_root" \
  "$repo_root/scripts/run_editor_performance_diagnostic.sh" \
  > "$evidence_root/diagnostic.log" 2>&1 & child_pid=$!
wait "$child_pid"
child_pid=""
git -C "$reference_root" -c core.fsmonitor=false diff --quiet HEAD -- Sources meh.md
