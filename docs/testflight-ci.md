# Internal TestFlight delivery

The `Internal TestFlight` workflow validates the merged commit, archives the
regular `meh.md` Release scheme for iOS/iPadOS and macOS, and distributes both
builds to one existing internal TestFlight group. It is the first step of
[Releasing](releasing.md): the beta and App Store workflows promote these
builds instead of building their own.

## Pull request checks

Every PR installs the pinned ASC CLI, validates the export plists, runs the
tests of the release scripts, and builds Release for iOS Simulator and macOS
with signing disabled. These jobs have
no Apple secrets and never upload builds. The separate notebook workflow runs
its existing tests. Signed archives and Apple processing are checked only
when publishing from `main`; there is no separate signing rehearsal.

## Triggers and concurrency

- Every push to `main` triggers a run, unless it only changes `docs/`,
  Markdown files or `Tools/AppStore/`.
- Use Actions > Internal TestFlight > Run workflow on `main` to retry or build
  after changing only credentials or workflow configuration.
- GitHub's built-in concurrency cancels superseded runs and replaces pending
  runs. There is no custom queue, debounce, or latest-commit selection logic.
  A canceled run may already have uploaded one or both builds; cancellation
  cannot retract uploads accepted by Apple or guarantee atomic delivery of
  both platforms. Pushes excluded by the path filter do not cancel a run.
- Both platforms use the standard `xcode-27` arm64 runner. It is currently a
  public preview. The workflow fails if its selected Xcode is not version 27.
- Every workflow on that runner selects Xcode 27.2 through `DEVELOPER_DIR`.
  The image defaults to 27.1, whose `AppIntentsTesting` doesn't load on the
  iOS 27.2 simulators, so UI tests and shipped builds use the same Xcode.
- Notebook validation must pass before signing starts. Pushes to `main`
  skip the unsigned Release builds, since the signed archives compile the
  same code.
- One job publishes both platforms. It archives iOS first, then archives
  the Mac while the iOS build uploads and waits for Apple processing in a
  background step. A failure on one platform does not stop the other.

## Version, build number and test notes

The version comes from `scripts/app_version.sh`, one minor version above
the newest release tag; [Releasing](releasing.md#version-numbers) explains
the rule. At build time, `asc builds next-build-number` chooses the next
integer from processed builds and in-flight uploads across versions,
separately for each platform. Both are passed to `xcodebuild` and never
committed. Retries receive new numbers, and existing manual uploads are
included. Do not upload independently while CI publishes.

The test notes are the first paragraph of the merged PR's description,
followed by the commit. After each platform is processed and assigned, the
job records the build on its commit as a commit status, `testflight/IOS` or
`testflight/MAC_OS`, described as `<version> (<build number>)`. The beta
and release workflows use it to find a commit's builds.

## GitHub environment

Create an environment named `testflight` under repository Settings >
Environments. Restrict its deployment branches to `main`. Leave required
reviewers disabled if merges should publish without another approval.

Add these environment variables (they are identifiers, not credentials):

| Variable | Value |
| --- | --- |
| `ASC_APP_ID` | Numeric App Store Connect app ID for `meh.md`. |
| `APPLE_TEAM_ID` | `9YFM7J3EH3`, the project's Apple Developer team. |
| `TESTFLIGHT_INTERNAL_GROUP_ID` | ID of an existing internal tester group. |

The app record must already include both iOS and macOS. The group must contain
the intended internal testers. The workflow checks that the group belongs to
this app and is internal before building. Apple may also give other internal
groups access through their existing automatic-distribution settings.

## API key and permissions

In App Store Connect > Users and Access > Integrations > App Store Connect
API, an Account Holder or Admin creates the dedicated team key. The current
CI key has the Developer role, following Apple's internal-testing guide.
That guide includes adding builds to internal groups. Apple's general
build-assignment guide instead lists Account Holder, Admin, or App Manager.
These documents do not establish the API's internal-group exception clearly;
upload authentication has been verified, but group-assignment permission has
not. Do not treat a successful read-only API check as proof of write access.

Before considering delivery verified, the first publish must successfully
assign the build to the internal group. If Apple rejects that operation with
an authorization error, use an App Manager key after explicitly approving
the broader access, or configure automatic internal distribution instead.
The pipeline uses existing signing assets from secrets and does not create
signing resources or require access to the provisioning-profile API.

- [Internal testing permissions][internal-roles]
- [General build-assignment permissions][build-roles]

[internal-roles]: https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers
[build-roles]: https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-testers-to-builds

Team API keys apply to all apps on the account; they cannot be limited to
`meh.md`. Use a dedicated key so it can be rotated independently. This
workflow uses team-key authentication (including an issuer ID).

Add these GitHub environment secrets:

| Secret | Content |
| --- | --- |
| `ASC_KEY_ID` | Key ID from App Store Connect. |
| `ASC_ISSUER_ID` | Issuer ID shown on the API keys page. |
| `ASC_PRIVATE_KEY` | Entire downloaded `.p8` file, including PEM headers. |
| `SIGNING_CERTIFICATES_P12_BASE64` | Base64 of the signing identity export. |
| `SIGNING_CERTIFICATES_PASSWORD` | Password protecting that `.p12` export. |
| `IOS_PROFILE_BASE64` | Base64 of the iOS App Store profile. |
| `MACOS_PROFILE_BASE64` | Base64 of the Mac App Store profile. |
| `IOS_WIDGETS_PROFILE_BASE64` | Base64 of the iOS widget profile. |
| `MACOS_WIDGETS_PROFILE_BASE64` | Base64 of the Mac widget profile. |

The `.p8` key authenticates Apple API requests. It does not sign the app and
does not replace the `.p12` identities or provisioning profiles.

## Signing assets

Using your Apple account locally, prepare:

1. An Apple Distribution identity usable by both platform profiles, and a
   Mac Installer Distribution identity for the macOS `.pkg`.
2. In Keychain Access, export the identities **with their private keys** into
   one password-protected `.p12`. If the profiles use different app-signing
   identities, include both plus the installer identity. Cloud-managed
   certificates without a local private key cannot be used for this export.
3. An iOS App Store Connect distribution profile and a Mac App Store
   distribution profile for `de.andreas-sk.meh-md`, tied to the exported
   app-signing identities. Both must authorize the existing iCloud container,
   Production CloudKit, production push notifications, and the App Group
   `group.de.andreas-sk.meh-md`.
4. The same two kinds of profile for the widget extension,
   `de.andreas-sk.meh-md.widgets`. Its App ID needs only the App Group
   `group.de.andreas-sk.meh-md`. See [Widgets](widgets.md).

Use App Store distribution assets, not Developer ID or development profiles.
The certificate-import action manages a temporary keychain and its cleanup.
A short workflow step installs each manually managed App Store profile
from its existing secret in the Xcode 27 profile directory. Xcode-managed
team profiles cannot be used with this manual-signing workflow.
Xcode validates signing compatibility during
archive and export; the export plists explicitly select Production CloudKit
and leave the builds open to external testing and the App Store. GitHub
destroys the hosted VM after the job.

The selected profile names are checked into the workflow and export plists:

- iOS: `meh.md iOS TestFlight` and `meh.md Widgets iOS TestFlight`
- macOS: `meh.md Mac TestFlight` and `meh.md Widgets Mac TestFlight`

The archive step passes them as `MEH_APP_PROFILE` and
`MEH_WIDGETS_PROFILE`, which the Release configurations of the app and
the widget targets use as their provisioning profile.

Preserve those names when renewing profiles, or update both places.
The Mac export selects the installer certificate by its full Keychain name,
`3rd Party Mac Developer Installer: Andreas Skorczyk (9YFM7J3EH3)`.
Update that value if the certificate owner or team changes.

For each signing binary, copy its Base64 representation into the matching
secret using `base64 -i /path/to/file | pbcopy`. Paste `.p8` contents directly
into `ASC_PRIVATE_KEY`. Never commit the files or paste them into PRs.

Renew certificates and profiles by replacing their corresponding secrets.
The pipeline intentionally does not create or revoke Apple signing assets.

## First run and recovery

After adding the configuration, manually run the workflow on `main`. Check
the run's Actions summary for each platform's commit, version, build
number, and Apple build ID. Success means processing completed and the
internal group assignment was read back. Finally install both builds using TestFlight and
verify launch and Production CloudKit sync on real devices.

If Apple processing times out or a run is canceled after upload, inspect the
build in App Store Connect first. It may still finish processing. A full
rerun creates new builds; to reuse an existing processed build, add it to the
internal group in App Store Connect. Such a build has no commit status, so
the beta and release workflows won't find it; rerun the workflow for that.
API errors and partial publish results remain in the Actions logs. Do not
interpret an upload alone as delivery.

The setup action installs ASC 5.3.4 with checksum verification and caching.
All new actions are pinned to commit SHAs. Export settings live in
`.github/testflight/`; no custom publishing or signing scripts are needed. No
personal GitHub token is required. The publish job's token can read the
repository and pull requests and write commit statuses, nothing else.

## References

Apple's [App Store Connect Help][apple-help] documents the roles under
"Upload builds" and "Add internal testers", and key scope under
"App Store Connect API". GitHub's [Actions documentation][github-help]
includes "Installing an Apple certificate on macOS runners".

[apple-help]: https://developer.apple.com/help/app-store-connect/
[github-help]: https://docs.github.com/en/actions
