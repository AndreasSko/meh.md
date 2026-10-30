# AGENTS.md

Just a few things to note:

* When wirting markdown files in this repo, ensure Markdown text is limited to
  79 chars per line. Line-wrap otherwise
* If DeviceHub automation times out, quit it and launch its binary directly:
  From `/Applications/Xcode.app/Contents/Applications/DeviceHub.app`, run
  `Contents/MacOS/DeviceHub`.
* Bump the app version for every new PR with `scripts/bump_version.sh`;
  use `patch` for bug fixes and `minor` for features.
* Ensure the start of the PR description is easy to understand for an end-user.
  It should use easy english that explains if the change uses a new feature,
  fixes a bug, etc. Think of it as the release notes that could arrive on
  the App Store. In a later section you can go into more technical details.
  But always make sure it still easy to understand and to quickly skim over.
  Simple, concise language is the goal.
* For visible UI changes, include concise before/after screenshots in the PR.
  Default to iPhone; add other platforms only for meaningful differences.
  Use matching content and state, fictional data, and actual app captures.
  Focus on the main changes; state when a before capture is unavailable.
  Upload screenshots as PR attachments; do not commit them to the repository.
  Use `gh pr edit <number> --body-file <body.md> --attach <image.png>`;
  repeat `--attach` for more files. Matching local Markdown image paths in
  the body are replaced with uploaded GitHub URLs. Videos attach the same
  way, but without a `#alt` suffix.
* The goal of this app is to be minimalistic, easy-to-use and feeling like
  a proper, native iOS app. Keep that in mind when proposing UI changes.
  Consider Apple’s Human Interface Guidelines for UI design:
  https://developer.apple.com/design/human-interface-guidelines
* When building on a local machine for testing, ALWAYS use the iCloud Dev
  Build, unless the user explicitly asks otherwise.

## Building and testing

* Markdown-only changes need no build or test run.
* Use `-derivedDataPath build/<name>`; `build/` is ignored by git.
* Pipe `xcodebuild` output through `xcbeautify` when it is installed. Keep
  the raw log with `tee` and use `set -o pipefail` so failures still show.
* Run UI tests with `build-for-testing` once, then `test-without-building
  -only-testing:<target>/<class>/<test>` for each rerun.
* UI test runs often exceed the tool timeout. Run them in the background with
  output to a log file, and tell the user how many tests passed and failed
  each time you check on the log.

## Simulators and devices

* Get a simulator with `scripts/sim.py create iphone` (or `ipad`). It prints
  the UDID of a booted simulator that belongs to this worktree.
* Run `scripts/sim.py cleanup` when you are done with a simulator. It also
  deletes simulators left behind by worktrees that no longer exist.
* Never shut down, erase, or delete simulators you didn't create, and never
  restart DeviceHub while other sessions may be running tests.
* Install on a real iPhone or iPad with `scripts/install_device.sh [name]`.
  Use `--production` only when the user explicitly asks for it: it replaces
  the TestFlight app and works on their real iCloud notes.

## Pull requests

* A PR is done when it is ready to merge: tests pass, a screen recording
  shows the touched parts still work, CodeRabbit reviewed it, and you
  followed up on its comments. Merge only when the user asks.
* CodeRabbit doesn't review on its own; comment `@coderabbitai review`.
* Force-pushing your own branch with `--force-with-lease` is fine.
