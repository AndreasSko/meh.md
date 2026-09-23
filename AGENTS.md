# AGENTS.md

Just a few things to note:

* When wirting markdown files in this repo, ensure Markdown text is limited to
  79 chars per line. Line-wrap otherwise
* If DeviceHub automation times out, quit it and launch its binary directly:
  From `/Applications/Xcode.app/Contents/Applications/DeviceHub.app`, run
  `Contents/MacOS/DeviceHub`.
* Bump the app version for every new PR; use a patch bump for bug fixes.
* For visible UI changes, include concise before/after screenshots in the PR.
  Default to iPhone; add other platforms only for meaningful differences.
  Use matching content and state, fictional data, and actual app captures.
  Focus on the main changes; state when a before capture is unavailable.
  Upload screenshots as PR attachments; do not commit them to the repository.
  Use `gh pr edit <number> --body-file <body.md> --attach <image.png>`;
  repeat `--attach` for more files. Matching local Markdown image paths in
  the body are replaced with uploaded GitHub URLs.
* Consider Apple’s Human Interface Guidelines for UI design:
  https://developer.apple.com/design/human-interface-guidelines
