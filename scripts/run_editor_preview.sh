#!/bin/bash
set -euo pipefail

# Compile the actual editor in a disposable app that never opens a notebook.
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
preview_root="${TMPDIR:-/tmp}/meh-editor-appearance-preview"
preview_app="$preview_root/Markdown Appearance Preview.app"
mkdir -p "$preview_app/Contents/MacOS" "$preview_app/Contents/Resources"

xcrun swiftc -parse-as-library -swift-version 6 \
  -default-isolation MainActor \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -target "$(uname -m)-apple-macos27.0" \
  "$repo_root/meh.md/MarkdownSyntax.swift" \
  "$repo_root/meh.md/MarkdownPresentation.swift" \
  "$repo_root/meh.md/MarkdownTablePresentation.swift" \
  "$repo_root/meh.md/MarkdownEditor.swift" \
  "$repo_root/meh.md/MarkdownEditingCommands.swift" \
  "$repo_root/meh.md/MarkdownLivePreview.swift" \
  "$repo_root/meh.md/EditorTextSizeControl.swift" \
  "$repo_root/meh.md/EditorWritingControls.swift" \
  "$repo_root/Tools/EditorPreview/EditorPreview.swift" \
  -o "$preview_app/Contents/MacOS/EditorPreview"

cp "$repo_root/docs/fixtures/editor-showcase.md" \
  "$preview_app/Contents/Resources/editor-showcase.md"
cat > "$preview_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>EditorPreview</string>
  <key>CFBundleIdentifier</key><string>de.andreas-sk.meh-md.editor-preview</string>
  <key>CFBundleName</key><string>Markdown Appearance Preview</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

printf '%s\n' "$preview_app"
if [[ "${1:-}" != "--build-only" ]]; then
  open -n "$preview_app"
fi
