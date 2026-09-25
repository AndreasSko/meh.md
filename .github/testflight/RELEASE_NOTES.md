# TestFlight release notes

## Writing a PR

Use the release-notes section in the PR template. Write one to three short,
plain-text bullets explaining the changes to a tester, with an optional
request about what to test. Only the marked text is sent to TestFlight:

```markdown
## Release notes

<!-- release-notes:start -->
- You can now move several notes to another folder at once.

Please test moving notes and syncing the result to another device.
<!-- release-notes:end -->
```

Use exactly `None` between the markers when nothing changes for the tester.
Do not leave the placeholder, publish implementation details, or invent
"performance improvements" for a CI-only change. Basic text bullets are
fine; do not rely on Markdown rendering in TestFlight. The aggregate notes
have a conservative 4,000 UTF-16-unit limit and are never silently truncated.

The lightweight `Validate release notes` check runs on PR edits as well as
code changes. Description-only edits do not restart the Xcode build. The
check can be made required through the normal repository rules. Publication
also validates all included PRs, so bypassing the PR check does not silently
publish incomplete notes.

## Publication and provenance

The existing `asc publish testflight --test-notes` argument receives the
notes file. Signing, build-number selection, `en-US`, and automatic
internal-group distribution are unchanged. External promotion stays manual.
These notes describe changes since the last successful internal publication
for that platform, not since the last public-group promotion.

The collector follows the exact checked-out Git history, starting at the
last confirmed publication. It queries PR associations for first-parent
commits and deduplicates PRs, including squash/rebase merges. It includes
changes from cancelled, failed, and superseded releases. It does not select
PRs by timestamps or by whichever PR was most recently merged. Direct pushes
without a merged main PR fail explicitly instead of hiding their changes.
If all included PRs say `None`, testers see:

> No user-visible changes in this build.

Before uploading, the workflow saves an immutable notes snapshot keyed by
workflow run ID. A rerun reuses that text even if someone edits the PR later.
A newly dispatched run may collect fresh text. After Apple processing and
internal-group verification succeed, the script records the build ID,
version, build number, and workflow attempt. The receipt and successful
baseline advance together in one Git commit.

State is stored on two automatically created orphan branches:

- `testflight-state/IOS`
- `testflight-state/MAC_OS`

Each branch contains `runs/<run-id>.json` snapshots and `latest.json`, the
last confirmed publication. Notes and provenance remain in Git after the
workflow artifacts expire. Do not merge these branches into main, delete
them, or manually rewind them. Their commits contain metadata only; they do
not change app source or trigger a release. The publish job alone receives
`contents: write` and `pull-requests: read`, using the existing workflow
token. No new secrets are needed. Repository rules must permit these state
branches to be created and updated by that token; ref updates are not forced.

Each attempt also uploads `notes.txt` and `manifest.json` as a uniquely named
Actions artifact and includes the notes in the job summary. The full Git SHA
is retained in provenance, not in the tester-facing notes.

## First rollout

`notes-bootstrap.json` explicitly starts both platforms at commit
`2f19f0398676261837c6424e3bdc85998b51f423` (version 0.1.14). Workflow run
`35840884486` successfully published both platforms on September 23, 2026.
This avoids treating all old PRs as new changes. Once a platform has a
confirmed state record, the bootstrap is no longer used for that platform.
Any PR merged after that baseline needs notes, including PRs opened before
this convention was introduced. Add the section to their descriptions if
publication reports a missing section.

## Failures and retries

Main release runs are serialized and are not automatically cancelled by a
new merge once running. Pending intermediate runs may still be superseded;
the next publication collects their PRs. PR build cancellation is unchanged.
A rerun skips matrix legs already recorded as published, but can retry the
failed platform. An older unpublished run is rejected after a newer commit
has shipped, rather than rewinding its platform's baseline.

Missing notes, GitHub API failures, state-write failures, unknown commits,
and oversized notes stop publication. Correct invalid PR descriptions and
rerun before a snapshot has been saved. To change an already snapshotted
text, use a new manual run on current main. Do not rerun pre-notes workflow
versions; use the current workflow instead.

Apple upload and GitHub state cannot form one transaction. A timeout, manual
cancellation, or state-write failure after Apple accepts a build can leave a
build in TestFlight without a confirmed receipt. Its changes will be included
again, conservatively, and a retry may upload another build. Check App Store
Connect in that case; never advance state based only on upload acceptance.
A snapshot alone does not count as a successful publication.

PR text is read from event JSON or the GitHub API into files, never inserted
into shell source. The summary escapes HTML, and no release-time AI call or
third-party changelog generator is involved.

## Local validation

```sh
python3 -m unittest discover -s scripts/tests -p 'test_testflight_notes.py' -v
python3 scripts/testflight_notes.py validate --event /path/to/pr-event.json
```

Tests use local Git repositories and mocked service boundaries. They do not
upload builds, change real publication state, or need credentials.
