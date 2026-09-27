#!/bin/bash
set -euo pipefail

if [[ $# -gt 1 ]]; then
    echo "usage: $0 [new-evidence-directory]" >&2
    exit 2
fi
repository_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repository_root"
evidence_root=${1:-$(mktemp -d "${TMPDIR:-/tmp}/meh-sync-performance.XXXXXX")}
mkdir -p "$evidence_root"
evidence_root=$(cd "$evidence_root" && pwd)
if [[ -e "$evidence_root/test.log" || -e "$evidence_root/results.jsonl" ]]; then
    echo "Choose a new evidence directory; existing results are preserved." >&2
    exit 2
fi

{
    git rev-parse HEAD
    git -c core.fsmonitor=false status --short
    sw_vers
    uname -m
    xcodebuild -version
    swift --version
    env | LC_ALL=C sort | grep '^MEH_SYNC_BENCHMARK' || true
} > "$evidence_root/environment.txt"

# This test uses generated records and temporary files. It creates no
# CKContainer, makes no network requests, and reads no app data.
if ! MEH_SYNC_BENCHMARK=1 swift test -c release --disable-sandbox \
    --filter CloudKitStatePerformanceTests > "$evidence_root/test.log" 2>&1; then
    tail -n 80 "$evidence_root/test.log"
    echo "Benchmark failed; evidence: $evidence_root" >&2
    exit 1
fi

python3 - "$evidence_root" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
prefix = "SYNC_BENCHMARK "
rows = []
for line in (root / "test.log").read_text().splitlines():
    if line.startswith(prefix):
        rows.append(json.loads(line[len(prefix):]))
if not rows:
    sys.exit("No benchmark results were emitted; inspect test.log")
with (root / "results.jsonl").open("w") as output:
    for row in rows:
        output.write(json.dumps(row, sort_keys=True) + "\n")
        print(json.dumps(row, sort_keys=True))
PY
echo "Benchmark evidence: $evidence_root"
