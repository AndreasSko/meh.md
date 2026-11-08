#!/bin/bash
# Prints whether the app can differ between two commits, true or false:
# scripts/app_changed.sh <from> <to>
#
# Docs, the App Store page and the release tooling don't change the app.
# testflight.yml doesn't build for them, and PRs that only touch them skip
# the app's builds and checks.
set -euo pipefail

# Keep in sync with paths-ignore in testflight.yml
not_app=(
  ':(exclude)docs' ':(exclude,glob)**/*.md' ':(exclude)Tools/AppStore' ':(exclude).claude'
  ':(exclude).github/workflows/release.yml' ':(exclude).github/workflows/beta.yml'
  ':(exclude).github/workflows/release-notes.yml' ':(exclude).github/workflows/app-store.yml'
  ':(exclude)scripts/release_notes.py' ':(exclude)scripts/test_release_notes.py'
  ':(exclude)scripts/testflight_builds.sh'
)

if git diff --quiet "${1:?usage: $0 <from> <to>}" "${2:?usage: $0 <from> <to>}" -- . "${not_app[@]}"; then
  echo false
else
  status=$?
  (( status == 1 )) || exit "$status"
  echo true
fi
