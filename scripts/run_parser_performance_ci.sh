#!/bin/bash
# Build first, then rotate launch order to balance temporal runner variance.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
: "${EDITOR_PERFORMANCE_BASELINE_ROOT:?baseline worktree required}"
: "${EDITOR_PERFORMANCE_REFERENCE_ROOT:?reference worktree required}"
: "${RUNNER_TEMP:?evidence directory required}"
roots=("$EDITOR_PERFORMANCE_BASELINE_ROOT" "$EDITOR_PERFORMANCE_REFERENCE_ROOT" "$repo_root")
labels=(baseline reference current)
expected=(1378bf5e1b9fcaf0ff5e97435a320ef7d726ef42 369814141840b6f9ee1f898eae628d35ad4d68ca)
for index in 0 1; do
  if [[ "$(git -C "${roots[$index]}" rev-parse HEAD)" != "${expected[$index]}" ]]; then
    echo "Unexpected ${labels[$index]} control revision" >&2
    exit 1
  fi
  if ! git -C "${roots[$index]}" diff HEAD --quiet -- Sources meh.md; then
    echo "Modified ${labels[$index]} control production sources" >&2
    exit 1
  fi
done
for index in 0 1 2; do
  (cd "${roots[$index]}"
    unset MEH_FULL_PARSE_BENCHMARK MEH_FULL_PARSE_REPORT
    swift test -c release --filter MarkdownFullParsePerformanceTests) \
    2>&1 | tee "$RUNNER_TEMP/parser-paired-build-${labels[$index]}.log"
done
failed=0
arguments=()
for round in 0 1 2; do
  for offset in 0 1 2; do
    index=$(((round + offset) % 3))
    label="${labels[$index]}"
    report="$RUNNER_TEMP/parser-paired-$label-$((round + 1)).json"
    # A stale report must never stand in for a failed launch.
    rm -f "$report"
    if ! (cd "${roots[$index]}"
      MEH_FULL_PARSE_BENCHMARK=1 MEH_FULL_PARSE_LABEL="ci-$label-$round" \
        MEH_FULL_PARSE_REPORT="$report" swift test -c release --skip-build \
        --filter MarkdownFullParsePerformanceTests
    ) 2>&1 | tee "${report%.json}.log"; then
      failed=1
    fi
    arguments+=("--paired-$label-report" "$report")
  done
done
if ! python3 "$repo_root/scripts/check_parser_performance.py" "${arguments[@]}"; then
  failed=1
fi
exit "$failed"
