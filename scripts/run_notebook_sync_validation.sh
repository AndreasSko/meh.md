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

if ! python3 -m unittest discover -s Tools/LocalSyncServer -p 'test_*.py' \
    >"$evidence_root/python-test.log" 2>&1; then
    cat "$evidence_root/python-test.log"
    printf 'Python test log: %s\n' "$evidence_root/python-test.log"
    exit 1
fi

if ! swift test --disable-sandbox >"$test_log" 2>&1; then
    tail -n 200 "$test_log"
    printf 'Full test log: %s\n' "$test_log"
    printf 'Service log: %s\n' "$service_log"
    exit 1
fi

tail -n 20 "$evidence_root/python-test.log"
grep 'Notebook scale' "$test_log" || true
tail -n 40 "$test_log"
printf 'Validation evidence: %s\n' "$evidence_root"
