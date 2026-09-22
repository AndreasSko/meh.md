# Internal TestFlight delivery

The `Internal TestFlight` workflow validates the merged commit, archives the
regular `meh.md` Release scheme for iOS/iPadOS and macOS, and distributes both
builds to one existing internal TestFlight group. Exports are marked
internal-only. External testing and App Store submission are out of scope.

## Pull request checks

Every PR installs the pinned ASC CLI, validates the export plists, and builds
Release for iOS Simulator and macOS with signing disabled. These jobs have
no Apple secrets and never upload builds. The separate notebook workflow runs
its existing tests. Signed archives and Apple processing are checked only
when publishing from `main`; there is no separate signing rehearsal.

## Triggers and concurrency

- Pushes to `main` that change `meh.md.xcodeproj/project.pbxproj` trigger
  a run.
  The file contains the app version and build number. Other project-file
  changes also qualify; this is a path filter, not a semantic version check.
- Use Actions > Internal TestFlight > Run workflow on `main` to retry or build
  after changing only credentials or workflow configuration.
- GitHub's built-in concurrency cancels superseded runs and replaces pending
  runs. There is no custom queue, debounce, or latest-commit selection logic.
  A canceled run may already have uploaded one or both builds; cancellation
  cannot retract uploads accepted by Apple or guarantee atomic delivery of
  both platforms. Pushes excluded by the path filter do not cancel a run.
- Both platforms use the standard `xcode-27` arm64 runner. It is currently a
  public preview. The workflow fails if its selected Xcode is not version 27.
- Release builds and notebook validation must pass before signing starts. A
failure
  on one platform does not cancel the other platform's job.

The repository's per-PR marketing-version bump remains in place. At build
time, `asc builds next-build-number` chooses the next integer from processed
builds and in-flight uploads across versions, separately for each platform.
The override is not committed. Retries receive new numbers, and existing
manual uploads are included. Do not upload independently while CI publishes.

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
   Production CloudKit, and production push notifications.

Use App Store distribution assets, not Developer ID or development profiles.
The certificate-import action manages a temporary keychain and its cleanup.
A short workflow step installs each profile from its existing secret in the
Xcode 27 profile directory. We retain profile secrets because the existing
Xcode-managed iOS profile is not listed by Apple's profile API.
Xcode validates signing compatibility during
archive and export; the export plists explicitly select Production CloudKit
and internal-only distribution. GitHub destroys the hosted VM after the job.

The selected profile names are checked into the workflow and export plists:

- iOS: `iOS Team Store Provisioning Profile: de.andreas-sk.meh-md`
- macOS: `meh.md Mac TestFlight`

Preserve those names when renewing profiles, or update both places.

For each signing binary, copy its Base64 representation into the matching
secret using `base64 -i /path/to/file | pbcopy`. Paste `.p8` contents directly
into `ASC_PRIVATE_KEY`. Never commit the files or paste them into PRs.

Renew certificates and profiles by replacing their corresponding secrets.
The pipeline intentionally does not create or revoke Apple signing assets.

## First run and recovery

After adding the configuration, manually run the workflow on `main`. Check
each platform's Actions summary for the commit, version, build number, and
Apple build ID. Success means processing completed and the internal group
assignment was read back. Finally install both builds using TestFlight and
verify launch and Production CloudKit sync on real devices.

If Apple processing times out or a run is canceled after upload, inspect the
build in App Store Connect first. It may still finish processing. A full
rerun creates new builds; to reuse an existing processed build, add it to the
internal group in App Store Connect. API errors and partial publish results
remain in the Actions logs. Do not interpret an upload alone as delivery.

The setup action installs ASC 5.3.4 with checksum verification and caching.
All new actions are pinned to commit SHAs. Export settings live in
`.github/testflight/`; no custom publishing or signing scripts are needed. No
personal
GitHub token is required; the workflow's token only has `contents: read`.

## References

Apple's [App Store Connect Help][apple-help] documents the roles under
"Upload builds" and "Add internal testers", and key scope under
"App Store Connect API". GitHub's [Actions documentation][github-help]
includes "Installing an Apple certificate on macOS runners".

[apple-help]: https://developer.apple.com/help/app-store-connect/
[github-help]: https://docs.github.com/en/actions
