# Getting started

The first launch offers one short welcome screen. Start Writing creates and
opens a blank note with the keyboard ready in its body. Tap the title to
rename it later. Explore Example Notes adds an optional folder containing
three ordinary notes. Import Markdown opens the native file or folder picker.
Not now opens the notebook without adding anything.

Keeping the guide optional and available in Settings follows Apple's
[onboarding guidance][onboarding-guidance].

The notebook opens in the background while the welcome is visible. An iCloud
account and a connection are required for the initial cloud setup. The screen
explains that requirement and offers retry when setup fails. Once the notebook
is ready, its writing, example, and import actions become available. Existing
notebooks continue to open offline as before.

## Returning users

Completion is a device-local preference, shared by the app's windows. Existing
catalog files, including damaged or previous copies, bypass the welcome when
upgrading; the normal recovery screen remains responsible for damaged data.
Receiving a Markdown file or a Home Screen action also bypasses the welcome
so the requested action can proceed.

Open Settings > Help > Getting Started to revisit the screen. Opening Settings
flushes current editor changes before presenting it. The guide adds nothing
until an example or new-note action is chosen. Cancelling an import leaves the
ordinary notebook available.

## Optional examples

Example Notes contains Start Here, Try Markdown, and Meeting. Start Here
explains everyday actions and links to the other two notes. Try Markdown
contains formatting, checkboxes, a quote, and a small editable table. Meeting
is registered as a working template with a date-based filename and copies
created at the notebook root. It does not change the user's usual new-note
destination.

The examples use the existing journalled Markdown importer and normal synced
template metadata. Each installation has random note identities. A local
receipt retains the plan through retries; reopening examples preserves edits
and template defaults rather than importing another copy. Interrupted imports
are resumed by the normal import-recovery flow. Removed examples remain in
Trash; reopening the guide does not restore or overwrite them.

The notes remain ordinary editable, exportable Markdown. There is no special
tutorial notebook or permanent navigation section. Welcome completion and
example receipts are local preferences, not new CloudKit records.

## Illustration

The welcome uses a monochrome crumpled-paper illustration inspired by the
existing app icon, with rough marker strokes and a straight, deadpan face.
The built-in image generation tool produced the transparent source. The
selected image is stored in
`meh.md/Assets.xcassets/WelcomeSketch.imageset/welcome-sketch.png`.

The final prompt used the app icon as its reference:

> Use the supplied meh.md app icon as the style reference. Create a new small
> welcome illustration in precisely that rough DIY spirit: a very crumpled
> scrap of plain white paper, slightly wonky with a dog-eared corner, heavy
> black uneven marker strokes, two small solid dot eyes and a straight deadpan
> mouth. This is a bored, matter-of-fact note, not a cute happy character. The
> paper should feel crumpled by hand and photographed or roughly scanned, with
> stark creases and rough edges. No smile, no blush, no eyelashes, no cute
> cloud, no warm yellow pencil, no pastel colors, no soft glow. Monochrome
> black, white and neutral gray only. One simple black marker or pencil lying
> beside the scrap is okay, if kept plain and rough. Compact landscape
> composition for display 240 points wide; actual transparent background,
> crisp cutout with NO background halo or drop shadow. Remove all wording from
> the reference: no text, letters, numbers, app name, watermark, UI, or logos.
> The result must look homemade, unpolished and dry-humored, like the existing
> icon.

## Verification

Model tests cover first-use eligibility, skipping, existing and damaged
notebooks, one-time action consumption across windows, sample preservation,
interrupted import recovery, template independence, deletion, and ordinary
replica convergence. UI regressions cover writing, skipping, relaunch, keeping
example edits, and creating a separate note from the Meeting template. iCloud
Dev simulator checks use isolated loopback notebooks with fictional data.
They do not establish live CloudKit delivery.

Debug preview and loopback fixtures preserve their existing launch behavior.
Set `MEH_WELCOME_TEST=1` to exercise the real welcome in an isolated fixture.
Production and ordinary local builds offer it automatically on fresh storage.

[onboarding-guidance]:
  https://developer.apple.com/design/human-interface-guidelines/onboarding
