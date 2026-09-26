#!/bin/bash
set -euo pipefail

# Exercise the actual AppKit insertion indicator in a disposable app bundle.
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
check_root="${TMPDIR:-/tmp}/meh-editor-caret-check"
check_app="$check_root/Markdown Caret Check.app"
result_file="/tmp/meh-editor-caret-check-result.txt"

rm -rf "$check_app"
rm -f "$result_file"
mkdir -p "$check_app/Contents/MacOS"
mkdir -p "$check_root/module-cache"

CLANG_MODULE_CACHE_PATH="$check_root/module-cache" \
SWIFT_MODULE_CACHE_PATH="$check_root/module-cache" \
xcrun swiftc -parse-as-library -swift-version 6 \
  -default-isolation MainActor \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -target "$(uname -m)-apple-macos27.0" \
  "$repo_root/meh.md/MarkdownSyntax.swift" \
  "$repo_root/meh.md/MarkdownPresentation.swift" \
  "$repo_root/meh.md/MarkdownTablePresentation.swift" \
  "$repo_root/meh.md/MarkdownEditor.swift" \
  "$repo_root/meh.md/MarkdownEditingCommands.swift" \
  "$repo_root/meh.md/MarkdownTableEditing.swift" \
  "$repo_root/meh.md/MarkdownTableScrolling.swift" \
  "$repo_root/meh.md/MarkdownLivePreview.swift" \
  "$repo_root/meh.md/EditorWritingControls.swift" \
  "$repo_root/Tools/EditorCaretCheck/EditorCaretCheck.swift" \
  -o "$check_app/Contents/MacOS/EditorCaretCheck"

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

open -n -W "$check_app"
cat "$result_file"
grep -q '^PASS:' "$result_file"
