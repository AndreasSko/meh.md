#!/bin/bash
# Measure only current code; reference values are deliberately recorded.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
: "${RUNNER_TEMP:?evidence directory required}"
cp "$repo_root/scripts/fixtures/performance/parser-reference-af516.json" \
  "$RUNNER_TEMP/parser-recorded-reference.json"
cd "$repo_root"
unset MEH_FULL_PARSE_BENCHMARK MEH_FULL_PARSE_REPORT
swift test -c release --filter MarkdownFullParsePerformanceTests \
  2>&1 | tee "$RUNNER_TEMP/parser-current-build.log"
failed=0
arguments=()
for run in 1 2 3; do
  report="$RUNNER_TEMP/parser-current-$run.json"
  rm -f "$report"
  if ! MEH_FULL_PARSE_BENCHMARK=1 MEH_FULL_PARSE_LABEL="ci-current-$run" \
    MEH_FULL_PARSE_REPORT="$report" swift test -c release --skip-build \
    --filter MarkdownFullParsePerformanceTests \
    2>&1 | tee "${report%.json}.log"; then
    failed=1
  fi
  arguments+=(--current-report "$report")
done
if ! python3 "$repo_root/scripts/check_parser_performance.py" \
  --recorded-reference "${arguments[@]}"; then
  failed=1
fi
exit "$failed"
