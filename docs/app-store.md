# App Store page

The App Store page lives in the repo, so a change to it is a normal PR, and
a merged change can go out at any time with one script. The text is in
`Tools/AppStore/metadata/`, the screenshots come from the tools described in
[Screenshots](screenshots.md), and `Tools/AppStore/publish.sh` sends both to
App Store Connect.

## Text

Each language has a folder named after its App Store locale, with one plain
text file per field:

| File | Field | Notes |
| --- | --- | --- |
| `name.txt` | Name | 30 characters. Shared by all versions. |
| `subtitle.txt` | Subtitle | 30 characters. Shared by all versions. |
| `privacy_url.txt` | Privacy policy URL | Shared by all versions. |
| `description.txt` | Description | 4000 characters. Not used for search. |
| `keywords.txt` | Keywords | 100 characters, commas, no spaces. |
| `support_url.txt` | Support URL | |
| `marketing_url.txt` | Marketing URL | Optional. |
| `promotional_text.txt` | Promotional text | Optional, 170 characters. |
| `whats_new.txt` | What's New | Optional. |

A field without a file stays as it is in App Store Connect. Keywords should
not repeat words from the name or subtitle, since Apple already searches
those, and must not name other apps. See Apple's
[search guidance](https://developer.apple.com/app-store/search/).

PRs that touch the text run `publish.sh --check` in CI, which checks the
character limits and URLs offline.

## Publishing

```sh
Tools/AppStore/render.sh                      # screenshots into out/
Tools/AppStore/publish.sh                     # dry run, shows what changes
Tools/AppStore/publish.sh --confirm           # writes it
Tools/AppStore/publish.sh --skip-screenshots  # text only
```

The script works on the App Store version that is being prepared for iOS
and for macOS. Apple allows only one per platform. With `--confirm` it gives
that version the app's `MARKETING_VERSION`, or the one passed with
`--version`, so it matches the build you submit. If there is none, it
creates one. It then writes the text and replaces the screenshots: iPhone
6.9" and iPad 13" for iOS, and the Mac set for macOS. All languages use the
same English screenshots for now.

Apple only accepts changes to a version that's still being prepared. Once a
version is live, most text changes go with the next version. Choosing the
build, answering review questions, and submitting for review still happen in
App Store Connect.

## Credentials

The script uses the `asc` CLI. Locally, log in once with an App Store
Connect API key:

```sh
asc auth login --name meh --key-id KEY_ID --issuer-id ISSUER_ID \
  --private-key /path/to/AuthKey.p8
```

The key needs the App Manager role, which covers
[App Store information](https://developer.apple.com/help/app-store-connect/reference/account-management/role-permissions).
The TestFlight CI key has the Developer role, so it can upload builds but
not edit the store page. `ASC_APP_ID` is optional; without it the script
looks the app up by its bundle ID.
