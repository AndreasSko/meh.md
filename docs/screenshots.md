# Screenshots

The README and App Store screenshots should look like a real, tidy
notebook: fictional notes, a clean status bar, and sync shown as working.
They come from the actual app, captured by a UI test, so they can be
retaken in a few minutes whenever the UI changes.

## What the screenshots show

`ReadmeScreenshotUITests` launches the app with the `readme` fixture. It
seeds a small PARA-style notebook: the "Lisbon in May" trip note with a
version history, a weekly review made from a template, and a training log
with one snippet per workout.
`testReadmeScreens` opens the library, notes, and History.
`testSnippetScreens` opens the snippet menu over the training log. Each
screen is attached to the test result.

To change what a screenshot shows, change the fixture in
`NotebookUITestFixture.seedReadme` or the steps in the test. Keep the
content fictional.

## Launch settings

The test sets these, and they help for any other screenshot or recording:

| Setting | Effect |
| --- | --- |
| `MEH_NOTEBOOK_PREVIEW=1` | Uses a throwaway preview notebook. |
| `MEH_NOTEBOOK_PREVIEW_RUN` | Names the run, so each run starts fresh. |
| `MEH_NOTEBOOK_TEST_FIXTURE` | Seeds sample content, such as `readme`. |
| `MEH_NOTEBOOK_PREVIEW_SYNC=1` | Syncs with an in-memory iCloud stand-in. |
| `MEH_SYNC_AUTOMATIC=0` | Skips scheduled sync after startup. |
| `-editor.mode livePreview` | Shows rendered Markdown. |
| `-AppleLanguages "(en)"` | Keeps the app in English. |

A preview notebook never talks to iCloud, so without
`MEH_NOTEBOOK_PREVIEW_SYNC` the toolbar shows sync as off. With it, the
preview syncs with an in-memory copy and shows the normal synced state.
This only works in Debug builds.

From the shell, prefix test environment variables with `TEST_RUNNER_`, and
app environment variables for `simctl launch` with `SIMCTL_CHILD_`.

## Capture

```sh
Tools/AppStore/capture.sh            # iPhone, iPad and Mac
Tools/AppStore/capture.sh iphone     # just one device
SCREENSHOT_TEST=testSnippetScreens \
  Tools/AppStore/capture.sh          # just one test
```

The script builds the `meh.md Local` scheme and runs the test on its own
simulators, named "meh shots iPhone" and "meh shots iPad", so it never
touches a simulator another session is using. It creates them on the
latest iOS runtime if needed, sets them to English, and sets the status bar
to 9:41 with a full battery that is not charging. The iPhone runs twice,
the second time in dark mode for the iPhone snippets image. The Mac run
takes over the mouse for about a minute and sizes the window to
1440 × 900 points, the App Store's 2880 × 1800 pixels.

The script exports the attachments into `Tools/AppStore/raw/`.
Logs and result bundles stay in `build/app-store-shots/`.

## App Store framing

`Tools/AppStore/render.sh` turns the raw screenshots into the
App Store images in `out/`. Each one gets a headline and a device frame,
with zoomed details where a feature is small on screen. Headlines and
layouts live in `shots.js`. Crop positions are in raw screenshot pixels,
so check them after a UI change moves things around. The script needs
Google Chrome, which renders `template.html` headless at the exact App
Store sizes.

To upload the images to the App Store, see [App Store page](app-store.md).
