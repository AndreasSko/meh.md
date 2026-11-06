#!/bin/bash
# Finds the TestFlight builds for a commit: scripts/testflight_builds.sh <rev>
#
# testflight.yml records each upload as a commit status, testflight/IOS and
# testflight/MAC_OS, described as "<version> (<build number>)". This walks
# back from <rev> to the newest commit that has both, and fails if the app
# changed in between. Prints commit=, version=, ios= and mac= lines for
# $GITHUB_OUTPUT. Needs GH_TOKEN and GITHUB_REPOSITORY.
set -euo pipefail

rev=${1:?usage: $0 <rev>}
target=$(git rev-parse "$rev^{commit}")
# Keep in sync with paths-ignore in testflight.yml
not_app=(':(exclude)docs' ':(exclude,glob)**/*.md' ':(exclude)Tools/AppStore')

for sha in $(git rev-list --first-parent --max-count=50 "$target"); do
  statuses=$(gh api "repos/$GITHUB_REPOSITORY/commits/$sha/status" \
    --jq '[.statuses[] | select(.state == "success")
      | {key: .context, value: .description}] | from_entries')
  ios=$(jq -r '."testflight/IOS" // empty' <<< "$statuses")
  mac=$(jq -r '."testflight/MAC_OS" // empty' <<< "$statuses")
  [[ -n $ios && -n $mac ]] || continue

  if ! git diff --quiet "$sha" "$target" -- . "${not_app[@]}"; then
    echo "The app changed after ${sha:0:7}, the newest commit with builds." >&2
    echo "Wait for Internal TestFlight to finish on ${target:0:7}, or rerun it." >&2
    exit 1
  fi
  version=${ios% *}
  if [[ ${mac% *} != "$version" ]]; then
    echo "iOS and Mac builds of ${sha:0:7} differ: $ios, $mac" >&2
    exit 1
  fi
  ios=${ios##*(} mac=${mac##*(}
  printf 'commit=%s\nversion=%s\nios=%s\nmac=%s\n' \
    "$sha" "$version" "${ios%)}" "${mac%)}"
  exit 0
done
echo "No commit with iOS and Mac TestFlight builds near ${target:0:7}." >&2
exit 1
