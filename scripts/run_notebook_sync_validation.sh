#!/bin/bash
set -euo pipefail

repository_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repository_root"
evidence_root=$(mktemp -d "${TMPDIR:-/tmp}/meh-sync-validation.XXXXXX")
service_data="$evidence_root/service"
service_log="$evidence_root/service.log"
test_log="$evidence_root/swift-test.log"
service_pid=""
service_ready=0

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'evidence_root=%s\n' "$evidence_root" >>"$GITHUB_OUTPUT"
fi

cleanup() {
    if [[ -n "$service_pid" ]]; then
        kill "$service_pid" 2>/dev/null || true
        wait "$service_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

port=$(python3 -c \
    'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')

mkdir -p "$service_data"
python3 "$repository_root/Tools/LocalSyncServer/local_sync_server.py" \
    --data-dir "$service_data" --port "$port" >"$service_log" 2>&1 &
service_pid=$!

for _ in $(seq 1 100); do
    if curl --silent --output /dev/null \
        "http://127.0.0.1:$port/v2/records?scope=ready&limit=1"; then
        service_ready=1
        break
    fi
    if ! kill -0 "$service_pid" 2>/dev/null; then
        cat "$service_log"
        exit 1
    fi
    sleep 0.1
done

if [[ "$service_ready" -ne 1 ]]; then
    cat "$service_log"
    printf 'Loopback service did not become ready on port %s\n' "$port"
    exit 1
fi

if [[ "${1:-}" == "--scheduled" ]]; then
    export MEH_NOTEBOOK_STRESS_SEEDS="7,11,23,47,97,193,389,769"
    export MEH_NOTEBOOK_SCALE_COUNTS="100,500,1000"
fi
export MEH_NOTEBOOK_HTTP_URL="http://127.0.0.1:$port"
if [[ "${1:-}" == "--complete" ]]; then
# These benchmarks are entirely synthetic; none needs an iCloud account.
export MEH_TYPING_BENCHMARK=1
export MEH_SYNC_BENCHMARK=1
export MEH_EXCHANGE_BENCHMARK=1
export MEH_BOOTSTRAP_VALIDATION_BENCHMARK=1
export MEH_RUN_MODEL_SYNC_BENCHMARK=1
export MEH_CATALOG_BENCHMARK=1
export MEH_FULL_PARSE_BENCHMARK=1
fi

if ! python3 -m unittest discover -s Tools/LocalSyncServer -p 'test_*.py' \
    >"$evidence_root/python-test.log" 2>&1; then
    cat "$evidence_root/python-test.log"
    printf 'Python test log: %s\n' "$evidence_root/python-test.log"
    exit 1
fi

if ! python3 -m unittest discover -s Tools/CloudKit -p 'test_notebook_lab.py' \
    >"$evidence_root/lab-guard-test.log" 2>&1; then
    cat "$evidence_root/lab-guard-test.log"
    exit 1
fi

if ! swift test --disable-sandbox >"$test_log" 2>&1; then
    tail -n 200 "$test_log"
    printf 'Full test log: %s\n' "$test_log"
    printf 'Service log: %s\n' "$service_log"
    exit 1
fi

if [[ "${1:-}" == "--complete" ]]; then
swift test --skip-build list >"$evidence_root/discovered-tests.txt"
MEH_CARET_PROOF_PATH="$evidence_root/caret-proof.txt" \
    scripts/run_editor_caret_check.sh >"$evidence_root/caret.log" 2>&1
python3 scripts/check_ci_test_coverage.py --platform macos --scope package \
    --swift-log "$test_log" --discovered "$evidence_root/discovered-tests.txt" \
    --caret-proof "$evidence_root/caret-proof.txt" \
    --output "$evidence_root/coverage-report.json"
fi

tail -n 20 "$evidence_root/python-test.log"
tail -n 20 "$evidence_root/lab-guard-test.log"
grep 'Notebook scale' "$test_log" || true
tail -n 40 "$test_log"
printf 'Validation evidence: %s\n' "$evidence_root"
