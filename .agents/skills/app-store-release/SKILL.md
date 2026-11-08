---
name: app-store-release
description: Prepare the release notes of the draft GitHub release and publish it to the App Store. Use when asked to release a new version to the App Store.
---

# App Store release

The draft release text becomes What's New on the App Store. Its readers are
people using the app, often not technical. They don't know about GitHub or
PRs and just want to skim what changed or got fixed.

The release process itself is in `docs/releasing.md`.

## 1. Propose the notes

Read the draft with `gh release view <tag>`. Its paragraphs come from merged
PRs and are raw material. Rewrite them:

- Leave out anything users don't notice: CI, tests, docs, refactors.
- Group items under the devices they affect: `Mac`, `iPad`, `iPhone`, or
  `All devices`, in that order, and skip empty groups. Combine headings
  where that fits, like `iPhone and iPad`. Check the PR's code
  (`#if os(...)`, platform-only views) instead of guessing.
- One short line per item, saying what the user notices. No causes,
  internals or PR numbers.
- Make clear whether something is a fix or a change.
- Say where in the app something is when that helps, like "in Settings".
  Name places by what users see, like "the sidebar", not by internal or
  section names like "Files". If a word could mean something else (like
  "highlight"), pick a clearer one.
- Condense hard. A detail the user doesn't need goes. Several small fixes
  in one area can share a line, like "Smaller improvements to …", but
  keep anything a user would look for as its own line.

Show the proposal in a code block and say briefly what you left out and
why. Revise until the user approves. Don't publish anything before that.

## 2. Publish

1. Update the draft: `gh release edit <tag> --notes-file <file>`.
2. Check the draft's target commit. It should be the commit a beta was
   promoted from for this version, otherwise the current `main`; a target
   left over from an old edit would ship a build without the newest
   notes. It also needs both TestFlight builds (the `testflight/IOS` and
   `testflight/MAC_OS` statuses). If either doesn't hold, find out why and
   tell the user before going on.
3. Publish: `gh release edit <tag> --draft=false`, adding
   `--target <full SHA>` if the target needs to change (GitHub rejects a
   short SHA). This runs `release.yml`, which prepares the versions in App
   Store Connect but doesn't submit them.
4. Follow the run until it finishes and report the result. The user submits
   for review in App Store Connect.

If the run fails, read the failed step's log and tell the user the cause
before trying again. A rerun only helps when the cause was outside the
repo. For a fix in the repo, `docs/releasing.md` says how to prepare the
tag again.

Never run `beta.yml` as part of this. It sends a build to the public
TestFlight group, which is a separate decision.
