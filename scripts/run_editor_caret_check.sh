#!/bin/bash
set -euo pipefail

# Exercise the actual AppKit insertion indicator in a disposable app bundle.
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
check_root="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/meh-editor-caret-check.XXXXXX")"
check_app="$check_root/Markdown Caret Check.app"
result_file="$check_root/result.txt"
if [[ "${1:-}" != "--build-only" ]]; then
  trap 'rm -rf "$check_root"' EXIT
fi

rm -rf "$check_app"
rm -f "$result_file"
mkdir -p "$check_app/Contents/MacOS"
mkdir -p "$check_root/module-cache"
export CLANG_MODULE_CACHE_PATH="$check_root/module-cache"
export SWIFT_MODULE_CACHE_PATH="$check_root/module-cache"

# Build the probe with the current package source inventory and NoteCore.
# Compiling a hand-maintained Swift file list misses new editor dependencies.
package_root="$check_root/package"
mkdir -p "$package_root/CaretSources"
ln -sfn "$repo_root/Sources" "$package_root/Sources"
ln -sfn "$repo_root/Tests" "$package_root/Tests"
ln -sfn "$repo_root/meh.md" "$package_root/meh.md"
cp "$repo_root/Package.swift" "$package_root/Package.swift"
python3 - "$repo_root" "$package_root" <<'PYTHON'
import json
from pathlib import Path
import shutil
import subprocess
import sys

repo, package = map(Path, sys.argv[1:])
inventory = json.loads(subprocess.check_output(
    ["swift", "package", "--scratch-path", str(package / "inventory-build"),
     "dump-package"], cwd=repo, text=True))
target = next(item for item in inventory["targets"]
              if item["name"] == "NativeEditor")
for source in target["sources"]:
    shutil.copy2(repo / "meh.md" / source, package / "CaretSources" / source)
shutil.copy2(repo / "Tools/EditorCaretCheck/EditorCaretCheck.swift",
             package / "CaretSources/EditorCaretCheck.swift")
with (package / "Package.swift").open("a") as manifest:
    manifest.write("""
package.products.append(.executable(name: "EditorCaretCheck", targets: ["CaretCheck"]))
package.targets.append(.executableTarget(
    name: "CaretCheck", dependencies: ["NoteCore"], path: "CaretSources",
    swiftSettings: [.defaultIsolation(MainActor.self)]
))
""")
PYTHON
swift build --package-path "$package_root" --product EditorCaretCheck
products="$(swift build --package-path "$package_root" --show-bin-path)"
cp "$products/EditorCaretCheck" "$check_app/Contents/MacOS/EditorCaretCheck"

cat > "$check_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>EditorCaretCheck</string>
  <key>CFBundleIdentifier</key><string>de.andreas-sk.meh-md.caret-regression</string>
  <key>CFBundleName</key><string>Markdown Caret Check</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

printf '%s\n' "$check_app"
if [[ "${1:-}" == "--build-only" ]]; then
  exit 0
fi

open -n -W --env "MEH_CARET_RESULT_PATH=$result_file" "$check_app"
cat "$result_file"
grep -q '^PASS:' "$result_file"
if [[ -n "${MEH_CARET_PROOF_PATH:-}" ]]; then
  cp "$result_file" "$MEH_CARET_PROOF_PATH"
fi
