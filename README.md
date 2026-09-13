<img
  src="meh.md/icon.icon/Assets/0ff96f7b-6dd6-4ea2-ada8-84abd131a5b1.png"
  alt="meh.md app icon: a crumpled note with a meh face"
  width="160"
/>

# meh.md

A small, native Markdown notes app for Mac, iPhone, and iPad.

This is my vibe-coded app, built to solve my own note-taking problems and fit
how I like to work. I want a comfortable native editor, simple Markdown, and
sync I can trust when I switch devices. Nothing fancy beyond that.

I might bring it to the App Store eventually. For now, making it useful for
me comes first.

## What I'm building

- A native Apple app, written in Swift with a SwiftUI interface.
- Easy Markdown editing, with familiar text selection and undo.
- Notes in simple folders, with Markdown import and readable Markdown copies.
- Local saving and offline writing, with dependable iCloud sync as the goal.

The scope stays small: a place to write and find my notes, without turning it
into a whole productivity system.

## Where it stands

The app is in active development. It already has a Markdown editor, multiple
notes, nested folders, import, Trash, and an iCloud development build. Daily
use, sync recovery, and device testing are still being worked through. See the
[roadmap](docs/plan.md) for recorded progress and follow-up work.

Under the hood, native AppKit/UIKit text views handle editing, Automerge
stores and merges document state, and CloudKit carries sync data. The app
maintains ordinary Markdown copies for portability; changes made to those
copies in another editor are not imported back into the app.

## Run it from Xcode

The project currently targets macOS 27, iOS 27, and iPadOS 27 and needs Xcode
with the corresponding SDKs.

1. Open `meh.md.xcodeproj`.
2. Choose `meh.md Local` for local notes or `meh.md iCloud Dev` for development
   iCloud sync.
3. Select your Mac, simulator, or connected device and run the app.

For signing, iCloud setup, and the separate development app identities, see
[development builds](docs/development-builds.md) and
[CloudKit setup](docs/cloudkit-sync-setup.md).

## Documentation

- [Product brief](docs/product.md): goals, scope, and what success looks like.
- [Roadmap](docs/plan.md): milestones and remaining acceptance work.
- [Architecture](docs/architecture.md): how the app fits together.
- [Documentation index](docs/README.md): development guides, contracts,
  decisions, and historical verification records.
