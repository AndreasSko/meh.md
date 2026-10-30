#!/bin/bash
# Bump the app's MARKETING_VERSION: scripts/bump_version.sh patch|minor|major
set -euo pipefail

part=${1:-}
case "$part" in
  patch | minor | major) ;;
  *) echo "usage: $0 patch|minor|major" >&2; exit 64 ;;
esac

cd "$(git rev-parse --show-toplevel)"
project=meh.md.xcodeproj/project.pbxproj
current=$(xcodebuild -project meh.md.xcodeproj -target meh.md \
  -showBuildSettings 2>/dev/null |
  awk '$1 == "MARKETING_VERSION" && !found { print $3; found = 1 }')
[[ "$current" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || {
  echo "Unexpected MARKETING_VERSION: '$current'" >&2
  exit 1
}
major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]} patch=${BASH_REMATCH[3]}
case "$part" in
  patch) next="$major.$minor.$((patch + 1))" ;;
  minor) next="$major.$((minor + 1)).0" ;;
  major) next="$((major + 1)).0.0" ;;
esac

OLD="$current" NEW="$next" perl -pi -e \
  's/MARKETING_VERSION = \Q$ENV{OLD}\E;/MARKETING_VERSION = $ENV{NEW};/g' "$project"
grep -q "MARKETING_VERSION = $next;" "$project" || {
  echo "Version was not updated" >&2
  exit 1
}
echo "$current -> $next"
