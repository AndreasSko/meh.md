#!/bin/bash

set -euo pipefail

package_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /tmp/meh-md-automerge-spike.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT

export CLANG_MODULE_CACHE_PATH=/tmp/meh-md-clang-cache
export SWIFTPM_MODULECACHE_OVERRIDE=/tmp/meh-md-swiftpm-cache

cd "$package_dir"

swift build --disable-sandbox --product AutomergeSpikeWriter >/dev/null
binary_dir="$(swift build --disable-sandbox --show-bin-path)"
writer="$binary_dir/AutomergeSpikeWriter"

check_stage() {
    stage="$1"
    expected_current="$2"
    expected_previous="$3"
    scenario_dir="$test_dir/$stage"
    branch_file="$scenario_dir/earlier-fork.automerge"
    mkdir -p "$scenario_dir"

    "$writer" write "$scenario_dir" old
    initial_inspection="$($writer inspect "$scenario_dir")"
    initial_heads="$(printf '%s\n' "$initial_inspection" \
        | sed -n 's/^current-heads=//p')"
    initial_history="$(printf '%s\n' "$initial_inspection" \
        | sed -n 's/^current-history=//p')"
    "$writer" branch "$scenario_dir" "$branch_file" -fork
    "$writer" append "$scenario_dir" -new "$stage" &
    writer_pid=$!

    for _ in $(seq 1 100); do
        if [[ -f "$scenario_dir/stage.marker" ]]; then
            break
        fi
        sleep 0.05
    done

    if [[ ! -f "$scenario_dir/stage.marker" ]]; then
        kill -9 "$writer_pid" 2>/dev/null || true
        echo "writer did not reach $stage" >&2
        return 1
    fi

    kill -9 "$writer_pid"
    wait "$writer_pid" 2>/dev/null || true

    inspection="$($writer inspect "$scenario_dir")"
    current="$(printf '%s\n' "$inspection" \
        | sed -n 's/^current=//p')"
    previous="$(printf '%s\n' "$inspection" \
        | sed -n 's/^previous=//p')"
    if [[ "$current" != "$expected_current" \
        || "$previous" != "$expected_previous" ]]; then
        echo "unexpected files after interruption at $stage" >&2
        echo "$inspection" >&2
        return 1
    fi

    "$writer" append "$scenario_dir" -reopened
    reopened_inspection="$($writer inspect "$scenario_dir")"
    reopened_heads="$(printf '%s\n' "$reopened_inspection" \
        | sed -n 's/^current-heads=//p')"
    reopened_history="$(printf '%s\n' "$reopened_inspection" \
        | sed -n 's/^current-history=//p')"
    if [[ "$reopened_heads" == "$initial_heads" \
        || "$reopened_history" -le "$initial_history" ]]; then
        echo "reopen did not continue the saved CRDT history" >&2
        return 1
    fi

    "$writer" merge "$scenario_dir" "$branch_file"
    merged_inspection="$($writer inspect "$scenario_dir")"
    merged="$(printf '%s\n' "$merged_inspection" \
        | sed -n 's/^current=//p')"
    merged_history="$(printf '%s\n' "$merged_inspection" \
        | sed -n 's/^current-history=//p')"
    if [[ "$merged" != *-fork* || "$merged" != *-reopened* \
        || "$merged_history" -le "$reopened_history" ]]; then
        echo "earlier fork did not merge after reopen" >&2
        echo "$merged_inspection" >&2
        return 1
    fi
}

check_stage tempSynced old missing-or-invalid
check_stage previousReplaced old old
check_stage currentReplaced old-new old
check_stage directorySynced old-new old

recovery_dir="$test_dir/recovery"
mkdir -p "$recovery_dir"
"$writer" write "$recovery_dir" old
"$writer" append "$recovery_dir" -new
printf damaged >"$recovery_dir/note.automerge"
recovery_report="$($writer append "$recovery_dir" -recovered)"
if [[ "$recovery_report" != *"recovered-from=previous"* \
    || "$recovery_report" != *"current-failure=corrupt"* ]]; then
    echo "recovery did not report the previous document fallback" >&2
    echo "$recovery_report" >&2
    exit 1
fi
recovery_inspection="$($writer inspect "$recovery_dir")"
if [[ "$recovery_inspection" != *"current=old-recovered"* ]]; then
    echo "recovered write did not replace the corrupt current file" >&2
    echo "$recovery_inspection" >&2
    exit 1
fi
quarantine_file="$(find "$recovery_dir" -name 'note.quarantine-*.automerge')"
if [[ -z "$quarantine_file" \
    || "$(<"$quarantine_file")" != "damaged" ]]; then
    echo "recovered write did not retain the corrupt current file" >&2
    exit 1
fi

echo "Interrupted-write checks passed."
