#!/bin/bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 3 ]]; then
  echo "usage: $0 SIMULATOR_UDID [initial|scrolled|resized] [screenshot]"
  exit 2
fi

device="$1"
stage="${2:-scrolled}"
screenshot="${3:-/tmp/meh-editor-quote-$stage.png}"
case "$stage" in
  initial|scrolled|resized) ;;
  *)
    echo "unknown stage: $stage" >&2
    exit 2
    ;;
esac

# Validate before building or installing the iOS 27 harness.
xcrun simctl list --json | python3 -c '
import json
import sys

inventory = json.load(sys.stdin)
selected = sys.argv[1].upper()
for runtime_id, devices in inventory.get("devices", {}).items():
    device = next(
        (item for item in devices if item["udid"].upper() == selected), None
    )
    if device is not None:
        break
else:
    sys.exit(f"Unknown simulator UDID: {sys.argv[1]}")
runtime = next(
    (item for item in inventory.get("runtimes", [])
     if item["identifier"] == runtime_id), None
)
if runtime is None:
    sys.exit(f"Cannot determine runtime for simulator {selected}")
version = tuple(int(part) for part in runtime["version"].split("."))
if ".iOS-" not in runtime_id or version < (27, 0):
    sys.exit(
        "Quote preview requires iOS 27.0 or newer; selected simulator uses "
        + runtime["name"]
    )
if not runtime.get("isAvailable", False) or not device.get("isAvailable", False):
    sys.exit(f"Selected simulator is unavailable: {selected}")
' "$device"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
check_root="${TMPDIR:-/tmp}/meh-editor-quote-check"
check_app="$check_root/Editor Quote Check.app"
module_cache="$check_root/module-cache"
sdk_path="$(xcrun --sdk iphonesimulator --show-sdk-path)"
bundle_id="de.andreas-sk.meh-md.editor-quote-check"

rm -rf "$check_app"
mkdir -p "$check_app" "$module_cache"
cp "$repo_root/Tools/EditorQuoteCheck/Info.plist" "$check_app/Info.plist"

CLANG_MODULE_CACHE_PATH="$module_cache" \
SWIFT_MODULE_CACHE_PATH="$module_cache" \
xcrun swiftc -parse-as-library -swift-version 6 \
  -default-isolation MainActor \
  -sdk "$sdk_path" \
  -target "$(uname -m)-apple-ios27.0-simulator" \
  "$repo_root/meh.md/MarkdownSyntax.swift" \
  "$repo_root/meh.md/MarkdownPresentation.swift" \
  "$repo_root/meh.md/MarkdownTablePresentation.swift" \
  "$repo_root/meh.md/MarkdownEditor.swift" \
  "$repo_root/meh.md/MarkdownEditingCommands.swift" \
  "$repo_root/meh.md/MarkdownTableEditing.swift" \
  "$repo_root/meh.md/MarkdownTableScrolling.swift" \
  "$repo_root/meh.md/MarkdownLivePreview.swift" \
  "$repo_root/meh.md/EditorWritingControls.swift" \
  "$repo_root/Tools/EditorQuoteCheck/EditorQuoteCheck.swift" \
  -o "$check_app/EditorQuoteCheck"

xcrun simctl install "$device" "$check_app"
SIMCTL_CHILD_QUOTE_CHECK_STAGE="$stage" \
  xcrun simctl launch --terminate-running-process "$device" "$bundle_id"
sleep 2
xcrun simctl io "$device" screenshot "$screenshot"
printf '%s\n' "$screenshot"
