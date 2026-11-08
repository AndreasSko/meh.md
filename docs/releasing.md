# Releasing

Every merge to `main` reaches internal testers on TestFlight. When a build
feels right, one workflow sends it to the public beta, and publishing a
GitHub release prepares that same build in App Store Connect. You submit
it for review there after checking the details. Nothing is rebuilt on the
way, so what ships is the binary people tested.

| Channel | Who gets it | Starts with | Workflow |
| --- | --- | --- | --- |
| Internal | Internal testers | A merge to `main` | `testflight.yml` |
| Beta | The public TestFlight group | Running Beta | `beta.yml` |
| App Store | Everyone | Publish, then submit manually | `release.yml` |

Merges that can't change the app don't build: docs, Markdown files,
`Tools/AppStore/` and the release tooling, as `scripts/app_changed.sh`
lists them. A PR touching only those skips the Release builds and the
notebook sync checks too. How the internal builds are signed and
uploaded is in [Internal TestFlight delivery](testflight-ci.md).

## Version numbers

The version changes once per App Store release, not per PR. Many TestFlight
builds share one version, each with a higher build number, and one of them
is submitted. Apple requires every approved version to be higher than the
last, so a version is closed once it ships. Keeping one version through a
whole cycle also means Apple's Beta App Review, which looks at the first
beta build of each version, runs once per release.

Nobody bumps the version by hand. `scripts/app_version.sh` works it out
when CI builds:

- `main` builds one minor version above the newest release tag. After
  `v0.31.0`, every build is `0.32.0`.
- `MARKETING_VERSION` in the project is the lowest version it will use.
  Raise it only to jump ahead, say to `1.0.0`. Local builds show this value.
- A tag on the commit itself doesn't count, since that commit was built
  before the release named it.
- The build number is the next one App Store Connect hands out, per
  platform.

Patch versions aren't used: a fix ships in the next minor release.

## Release notes

Each release has a draft on GitHub's Releases page, named after the version
`main` builds, like `v0.31.0`. Only people with write access see drafts.
When a PR merges, `release-notes.yml` adds its first paragraph to the
draft, with the PR number. That's why a PR description opens with a
plain-English summary for users.

PRs labeled `no-release-note` are left out; use it for changes users don't
notice, like CI, tests, docs or refactors. To add a PR that was missed, run
the Release notes workflow with its number.

Notes land in the draft of the version `main` builds at merge time. After
you promote a beta, later PRs still go into that draft although the beta
build doesn't have them, so remove them before releasing; they ship with
the next version. Run the Release notes workflow for them once the next
draft exists.

The collected paragraphs are raw material. Before releasing, edit the draft
down to a few lines users care about. Markdown bullets, bold and links are
fine; they become plain text, and the `(#123)` PR numbers are dropped, since
TestFlight and the App Store show text as it is (`scripts/release_notes.py`).
The same text then appears in three places: the beta's What to Test, the
GitHub release, and What's New on the App Store.

## Send a build to beta testers

```sh
gh workflow run beta.yml                    # newest build on main
gh workflow run beta.yml -f commit=<sha>    # a specific commit
```

Or use Actions > Beta > Run workflow. It finds the newest commit on `main`
that has both an iOS and a Mac build, sets the draft release text as the
builds' What to Test, and adds them to the public group. Apple reviews the
first beta build of each version before testers get it; later builds of
the same version might skip the review. The draft release is then pointed
at that commit, so the App Store release ships exactly this build.

The workflow stops if the app changed after the newest build. Wait for
Internal TestFlight to finish, then run it again.

## Release to the App Store

Publish only once the previous version is live on the App Store.

1. Edit the draft release text into its final form.
2. Publish the draft, on its page or with
   `gh release edit v0.31.0 --draft=false`. GitHub creates the tag at the
   draft's commit: the beta build if you promoted one, otherwise `main`.
3. `release.yml` finds that commit's builds and checks their version
   matches the tag. It writes What's New, updates the App Store text with
   `Tools/AppStore/publish.sh` (not the screenshots), attaches the iOS and
   Mac builds, and validates each version. It stops before submitting for
   review. The run summary links to App Store Connect.
4. Open App Store Connect, check both platform versions, and adjust review
   notes or other details as needed. Submit each platform for review there
   when you are ready.
5. Once Apple approves, the update goes live for everyone right away.

From the tag on, `main` builds the next minor version, and the next merged
PR starts a new draft release.

Screenshots don't change with each release. When they do, publish them
with `publish.sh`, as [App Store page](app-store.md) describes.

## When something goes wrong

- **The preparation workflow fails.** If the cause was outside the repo,
  rerun the failed run. If the workflow or `publish.sh` needed a fix,
  merge it and run Actions > App Store release on `main` with the tag: a
  rerun would use the tag's old code, while a manual run uses `main`'s
  and still ships the tag's builds.
- **Apple rejects the text or screenshots.** Fix them in `Tools/AppStore/`
  or App Store Connect and resubmit in App Store Connect. The build stays.
- **Apple rejects the build.** The version isn't approved, so it can be
  reused. Turn the release back into a draft and delete its tag before
  merging the fix, so the fix still builds the same version:

  ```sh
  gh release edit v0.31.0 --draft=true --target main
  git push origin --delete v0.31.0
  ```

  Merge the fix, wait for its build, and publish the release again. PRs
  merged while the tag existed went into a `v0.32.0` draft but now ship in
  `0.31.0`: move their notes over and delete that draft. If submission
  fails because the rejected submission is still open, remove it in App
  Store Connect, then submit manually again.

## Asking Claude

Promoting a build or publishing a release only happens when you ask for it.
These are the commands behind each step:

```sh
gh release list                       # drafts and past releases
gh release view v0.31.0               # the draft's text and target
gh workflow run beta.yml              # send the newest build to beta
gh release edit v0.31.0 --draft=false # prepare in App Store Connect
gh run list --workflow release.yml    # then follow it with gh run watch
```

## Setup

The beta and release workflows run in the `app-store` environment under
Settings > Environments, limited to `main` and `v*` tags. It holds:

| Name | Kind | Value |
| --- | --- | --- |
| `ASC_APP_ID` | Variable | `6813143320` |
| `TESTFLIGHT_BETA_GROUP_ID` | Variable | ID of the public TestFlight group |
| `ASC_KEY_ID` | Secret | Key ID of an App Manager API key |
| `ASC_ISSUER_ID` | Secret | Issuer ID from the API keys page |
| `ASC_PRIVATE_KEY` | Secret | The whole `.p8` file |

The key needs the App Manager role, which manages an app's App Store
information and delivery ([Apple's roles][roles]). The internal TestFlight
key in the `testflight` environment only has the Developer role.

Internal builds record themselves on their commit as the commit statuses
`testflight/IOS` and `testflight/MAC_OS`, described as
`<version> (<build number>)`. GitHub shows them next to the commit, and
`scripts/testflight_builds.sh` reads them to find a commit's builds.

[roles]: https://developer.apple.com/help/app-store-connect/reference/account-management/role-permissions
