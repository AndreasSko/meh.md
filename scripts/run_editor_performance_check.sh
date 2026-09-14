#!/bin/bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 5 ]]; then
  echo "usage: $0 SIMULATOR_UDID [working-tree|GIT_REF] [source|livePreview] [blocks] [output]" >&2
  exit 2
fi
device="$1"
revision="${2:-working-tree}"
mode="${3:-livePreview}"
blocks="${4:-150}"
output="${5:-/tmp/meh-editor-performance.json}"
case "$mode" in source|livePreview) ;; *) exit 2 ;; esac
[[ "$blocks" =~ ^[0-9]+$ ]] && ((blocks >= 1 && blocks <= 500)) || exit 2
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
# Validate the runtime before compiling or replacing the existing test app.
xcrun simctl list --json | python3 -c '
import json
import sys
inventory = json.load(sys.stdin)
selected = sys.argv[1].upper()
for runtime_id, devices in inventory.get("devices", {}).items():
    device = next((d for d in devices if d["udid"].upper() == selected), None)
    if device is not None:
        break
else:
    sys.exit("Unknown simulator UDID")
runtime = next((r for r in inventory.get("runtimes", [])
                if r["identifier"] == runtime_id), None)
if runtime is None or ".iOS-" not in runtime_id:
    sys.exit("The performance probe requires an iOS simulator")
if tuple(map(int, runtime["version"].split("."))) < (27, 0):
    sys.exit("The performance probe requires iOS 27 or newer")
if not runtime.get("isAvailable") or not device.get("isAvailable"):
    sys.exit("Selected simulator is unavailable")
' "$device"
check_root="$(mktemp -d "${TMPDIR:-/tmp}/meh-editor-performance.XXXXXX")"
probe_launched=0
bundle_id="de.andreas-sk.meh-md.editor-quote-check"
cleanup() {
  if [[ "$probe_launched" == 1 ]]; then
    xcrun simctl terminate "$device" "$bundle_id" >/dev/null 2>&1 || true
  fi
  rm -rf "$check_root"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
check_app="$check_root/Editor Quote Check.app"
mkdir -p "$check_app" "$check_root/sources" "$check_root/module-cache"
files=(MarkdownSyntax MarkdownPresentation MarkdownEditor MarkdownEditingCommands
       MarkdownLivePreview EditorWritingControls)
if [[ "$revision" != working-tree ]]; then
  revision="$(git -C "$repo_root" rev-parse --verify "$revision^{commit}")"
fi
for name in "${files[@]}"; do
  if [[ "$revision" == working-tree ]]; then
    cp "$repo_root/meh.md/$name.swift" "$check_root/sources/$name.swift"
  else
    git -C "$repo_root" show "$revision:meh.md/$name.swift" \
      > "$check_root/sources/$name.swift"
  fi
done
cp "$repo_root/Tools/EditorQuoteCheck/Info.plist" "$check_app/Info.plist"
CLANG_MODULE_CACHE_PATH="$check_root/module-cache" \
SWIFT_MODULE_CACHE_PATH="$check_root/module-cache" \
xcrun swiftc -O -parse-as-library -swift-version 6 \
  -default-isolation MainActor \
  -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -target "$(uname -m)-apple-ios27.0-simulator" \
  "$check_root"/sources/*.swift \
  "$repo_root/Tools/EditorQuoteCheck/EditorQuoteCheck.swift" \
  -o "$check_app/EditorQuoteCheck"

xcrun simctl bootstatus "$device" -b >/dev/null
xcrun simctl install "$device" "$check_app"
container="$(xcrun simctl get_app_container "$device" "$bundle_id" data)"
report="$container/Documents/performance.json"
rm -f "$report"
SIMCTL_CHILD_EDITOR_PERFORMANCE_CHECK=1 \
SIMCTL_CHILD_EDITOR_PERFORMANCE_SCROLL_ROUNDS="${EDITOR_PERFORMANCE_SCROLL_ROUNDS:-1}" \
SIMCTL_CHILD_EDITOR_PERFORMANCE_BLOCKS="$blocks" \
SIMCTL_CHILD_EDITOR_PERFORMANCE_MODE="$mode" \
xcrun simctl launch --terminate-running-process "$device" "$bundle_id"
probe_launched=1
for ((attempt=0; attempt<180; attempt++)); do
  if [[ -f "$report" ]]; then
    python3 - "$report" "$output" "$revision" <<'PY'
import json
import statistics
import sys
from pathlib import Path
report = json.loads(Path(sys.argv[1]).read_text())
report["revision"] = sys.argv[3]
report["compiler_optimization"] = "-O"
output = Path(sys.argv[2])
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(report, indent=2) + "\n")
if not report["source_and_selection_preserved"]:
    raise SystemExit("Source or selection preservation failed")
for name, samples in report["measurements"].items():
    print(f"{name}: median {statistics.median(samples):.2f}")
PY
    printf '%s\n' "$output"
    exit 0
  fi
  sleep 1
done
echo "Performance probe timed out without a report" >&2
exit 1
