#!/bin/bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 6 ]]; then
  echo "usage: $0 SIMULATOR_UDID [working-tree|GIT_REF] [source|livePreview] [blocks|KB] [output] [presentation|large-note]" >&2
  exit 2
fi
device="$1"
revision="${2:-working-tree}"
mode="${3:-livePreview}"
scenario="${6:-large-note}"
case "$scenario" in presentation|large-note) ;; *) exit 2 ;; esac
performance_host="${EDITOR_PERFORMANCE_HOST:-editor}"
case "$performance_host" in editor|notebook) ;; *) exit 2 ;; esac
if [[ "$scenario" != large-note && "$performance_host" != editor ]]; then
  echo "notebook host requires the large-note scenario" >&2
  exit 2
fi
default_size=150
maximum_size=500
if [[ "$scenario" == large-note ]]; then
  default_size=500
  maximum_size=2000
  # Core and the editor must come from the same checkout in this scenario.
  [[ "$revision" == working-tree ]] || {
    echo "large-note requires working-tree; run from the desired checkout" >&2
    exit 2
  }
fi
blocks="${4:-$default_size}"
output="${5:-/tmp/meh-editor-performance.json}"
case "$mode" in source|livePreview) ;; *) exit 2 ;; esac
[[ "$blocks" =~ ^[0-9]+$ ]] && ((blocks >= 1 && blocks <= maximum_size)) || exit 2
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
# A failed build or launch must not leave a previous result at this run's path.
python3 - "$output" <<'PY'
import sys
from pathlib import Path
output = Path(sys.argv[1])
output.unlink(missing_ok=True)
output.with_name(output.stem + "-fixture.md").unlink(missing_ok=True)
PY
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
if [[ "$performance_host" == notebook ]]; then
  for source in "$repo_root"/meh.md/*.swift; do
    name="${source##*/}"
    case "$name" in
      NotebookSyncLabApp.swift|CloudKitSmokeCheck.swift|NotebookTypingDiagnostics.swift)
        continue
        ;;
    esac
    cp "$source" "$check_root/sources/$name"
  done
else
  for name in "${files[@]}"; do
    if [[ "$revision" == working-tree ]]; then
      cp "$repo_root/meh.md/$name.swift" "$check_root/sources/$name.swift"
    else
      git -C "$repo_root" show "$revision:meh.md/$name.swift" \
        > "$check_root/sources/$name.swift"
    fi
  done
  # Table support is absent in historical comparison revisions.
  for name in MarkdownTablePresentation MarkdownTableEditing MarkdownTableScrolling \
              MarkdownTableAccessibility MarkdownTableCellEditing MarkdownTableCellEditor; do
    if [[ "$revision" == working-tree ]]; then
      if [[ -f "$repo_root/meh.md/$name.swift" ]]; then
        cp "$repo_root/meh.md/$name.swift" "$check_root/sources/$name.swift"
      fi
    elif git -C "$repo_root" cat-file -e "$revision:meh.md/$name.swift" 2>/dev/null; then
      git -C "$repo_root" show "$revision:meh.md/$name.swift" \
        > "$check_root/sources/$name.swift"
    fi
  done
fi
cp "$repo_root/Tools/EditorQuoteCheck/Info.plist" "$check_app/Info.plist"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
target="$(uname -m)-apple-ios27.0-simulator"
app_cache="${EDITOR_PERFORMANCE_APP_CACHE:-}"
cache_helper="$repo_root/scripts/editor_performance_app_cache.py"
cache_key=""
cache_hit=0
if [[ -n "$app_cache" ]]; then
  compiler_version="$(xcrun swiftc --version)
$(swift --version)"
  key_arguments=(key --repo "$repo_root" --sources "$check_root/sources"
    --compiler "$compiler_version" --sdk "$sdk" --target "$target"
    --scenario "$scenario" --host "$performance_host")
  cache_key="$(python3 "$cache_helper" "${key_arguments[@]}")"
  if python3 "$cache_helper" lookup --cache "$app_cache" --key "$cache_key" --app "$check_app"; then
    cache_hit=1
    echo "Reusing verified compiled performance probe: $cache_key"
  else
    status=$?
    [[ "$status" == 1 ]] || exit "$status"
  fi
fi
if [[ "$cache_hit" == 0 ]]; then
  extra_arguments=("$repo_root/Tools/EditorQuoteCheck/EditorQuoteCheck.swift")
  if [[ "$scenario" == large-note ]] || rg -q "import NoteCore" "$check_root/sources"; then
    build_args=(--package-path "$repo_root" -c release --product NoteCore
                --triple "$target" --sdk "$sdk")
    SDKROOT="$sdk" swift build "${build_args[@]}"
    products="$(SDKROOT="$sdk" swift build "${build_args[@]}" --show-bin-path)"
    extra_arguments+=(-I "$products"
      -I "$products/include" -L "$products" -luniffi_automerge
      "$products/NoteCore.o" "$products/Automerge.o"
      "$products/AutomergeUniffi.o" "$products/AutomergeUtilities.o")
  fi
  if [[ "$scenario" == large-note ]]; then
    extra_arguments+=(-D LARGE_NOTE_PERFORMANCE
      "$repo_root/Tools/EditorQuoteCheck/LargeNotePerformanceProbe.swift"
      "$repo_root/Tools/EditorQuoteCheck/NotebookPerformanceHost.swift")
    if [[ "$performance_host" == notebook ]]; then
      extra_arguments+=(-D NOTEBOOK_PERFORMANCE_HOST -D DEBUG
        -D ICLOUD_ENABLED -D ICLOUD_DEV -D SYNC_LAB)
    else
      extra_arguments+=("$repo_root/meh.md/NotebookNoteEditor.swift")
    fi
  fi
  CLANG_MODULE_CACHE_PATH="$check_root/module-cache" \
  SWIFT_MODULE_CACHE_PATH="$check_root/module-cache" \
  xcrun swiftc -O -parse-as-library -swift-version 6 \
    -default-isolation MainActor \
    -sdk "$sdk" \
    -target "$target" \
    "$check_root"/sources/*.swift \
    "${extra_arguments[@]}" \
    -o "$check_app/EditorQuoteCheck"

  if [[ -n "$app_cache" ]]; then
    # Never label a binary with inputs that changed during compilation.
    final_key="$(python3 "$cache_helper" "${key_arguments[@]}")"
    [[ "$final_key" == "$cache_key" ]] || {
      echo "Performance probe inputs changed during compilation; retry the run" >&2
      exit 1
    }
    python3 "$cache_helper" store --cache "$app_cache" --key "$cache_key" --app "$check_app"
  fi
fi

xcrun simctl bootstatus "$device" -b >/dev/null
xcrun simctl install "$device" "$check_app"
container="$(xcrun simctl get_app_container "$device" "$bundle_id" data)"
report="$container/Documents/performance.json"
rm -f "$report"
SIMCTL_CHILD_EDITOR_PERFORMANCE_CONTEXT="${EDITOR_PERFORMANCE_CONTEXT:-standard}" \
SIMCTL_CHILD_EDITOR_PERFORMANCE_SHAPE="${EDITOR_PERFORMANCE_SHAPE:-standard}" \
SIMCTL_CHILD_EDITOR_PERFORMANCE_HOST="$performance_host" \
SIMCTL_CHILD_EDITOR_PERFORMANCE_PRESERVE_FAILED_HOST="${EDITOR_PERFORMANCE_PRESERVE_FAILED_HOST:-0}" \
SIMCTL_CHILD_EDITOR_PERFORMANCE_CHECK=1 \
SIMCTL_CHILD_EDITOR_PERFORMANCE_SCROLL_ROUNDS="${EDITOR_PERFORMANCE_SCROLL_ROUNDS:-1}" \
SIMCTL_CHILD_EDITOR_PERFORMANCE_BLOCKS="$blocks" \
SIMCTL_CHILD_EDITOR_PERFORMANCE_MODE="$mode" \
xcrun simctl launch --terminate-running-process "$device" "$bundle_id"
probe_launched=1
for ((attempt=0; attempt<360; attempt++)); do
  if [[ -f "$report" ]]; then
    python3 - "$report" "$output" "$revision" "$repo_root" "$device" <<'PY'
import hashlib
import json
import shutil
import statistics
import subprocess
import sys
from pathlib import Path
report = json.loads(Path(sys.argv[1]).read_text())
report["revision"] = sys.argv[3]
report["compiler_optimization"] = "-O"
report["checkout_commit"] = subprocess.check_output(
    ["git", "-C", sys.argv[4], "rev-parse", "HEAD"], text=True).strip()
report["checkout_dirty"] = bool(subprocess.check_output(
    ["git", "-C", sys.argv[4], "-c", "core.fsmonitor=false", "status", "--porcelain"],
    text=True).strip())
report["simulator_udid"] = sys.argv[5]
output = Path(sys.argv[2])
output.parent.mkdir(parents=True, exist_ok=True)
if report.get("scenario") == "large-note":
    fixture = Path(sys.argv[1]).with_name("large-note-fixture.md").read_bytes()
    if len(fixture) != report.get("utf8_bytes"):
        raise SystemExit("Exported fixture length does not match the measured note")
    report["fixture_sha256"] = hashlib.sha256(fixture).hexdigest()
output.write_text(json.dumps(report, indent=2) + "\n")
if not report["source_and_selection_preserved"]:
    raise SystemExit(report.get("error", "Source or selection preservation failed"))
if report.get("scenario") == "large-note":
    shutil.copyfile(Path(sys.argv[1]).with_name("large-note-fixture.md"),
                    output.with_name(output.stem + "-fixture.md"))
    print(f"Fixture: {report['utf8_bytes']:,} UTF-8 bytes")
for name, samples in report["measurements"].items():
    print(f"{name}: median {statistics.median(samples):.2f} ms, "
          f"max {max(samples):.2f} ms, n={len(samples)}")
PY
    printf '%s\n' "$output"
    exit 0
  fi
  sleep 1
done
echo "Performance probe timed out without a report" >&2
exit 1
