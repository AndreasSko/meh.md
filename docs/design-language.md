# Design language

meh.md should feel like a proper Apple app first. Its own character comes
from the app icon: a sheet of paper, black ink, and a face made of three text
characters, `•_•`. The name is a joke too: everything works, nothing is
earth-shattering. The app can show that humor, but only where it does not get
in the way.

## Rules

- **The shell stays Apple.** System fonts, Liquid Glass toolbars, standard
  lists, menus, gestures and SF Symbols. No custom controls just for looks.
- **Faces where the screen would otherwise be empty, plus a few fixed
  spots.** Empty lists, no search results, an empty new note and Sync
  Details with nothing to report. The fixed spots are the library title,
  the end of the file list, the end of Settings and the launch screen, so
  the face shows up on a normal day too. Never in toolbars, menus or the
  rows of notes and folders. The sync button stays an SF Symbol because it
  is faster to read.
- **Dry, short copy.** One plain sentence that says what is going on. No
  extra punchline sentence after it.
- **No jokes when something is wrong.** Errors, sync problems and anything
  that deletes notes stay factual and keep their SF Symbols.
- **Motion is optional.** Every animation has a still version when Reduce
  Motion is on.

## Faces

`MehFace` draws a face in bold SF Mono in the secondary label color and
scales with Dynamic Type. Faces are hidden from VoiceOver; the text next to
them carries the meaning.

| Face | Mood | Used for |
| --- | --- | --- |
| `•_•` | neutral | title, end of files and Settings, empty note, launch |
| `•_•` | neutral | empty library, no selection, no backlinks |
| `•_•?` | puzzled | search without results |
| `^_^` | pleased | empty Trash |
| `•‿•` | relaxed | Sync Details when everything is synced |
| `-_-` | asleep | Sync Details when sync is off |

Faces with dot eyes blink every few seconds. Tapping a face cycles through
all moods for a moment and then settles back. This is an easter egg, not a
feature, so nothing depends on it. The face under the file list (next to
the note count) and the one at the end of Settings (next to the version)
are the everyday places to find it.

On iPhone the large title reads `meh.md •_•`. The navigation title stays
`meh.md` for VoiceOver and the collapsed bar. iOS 27 passes no taps to a
view in the large-title slot, so that face only blinks.

## Color

Like the icon, the app writes with two pens on paper. People can pick both
pens under Settings > Appearance, next to a small sample.

- **Ink** is the accent for buttons, links, checkboxes and selection. The
  default is black: near-black in light mode and near-white in dark mode,
  like the lettering on the icon. Royal blue and forest green are the
  other inks. System controls put white glyphs on the accent, so with
  black ink the app-wide accent is a mid gray in dark mode. The editor,
  where we choose the color on top, always uses true ink. On the Mac,
  black ink leaves standard controls on the system accent color, as usual
  for Mac apps.
- **Highlighter** is the second color, so the app never looks flat. It marks
  `==highlights==`, the spot a search result or link jumps to, link underlines,
  the blockquote bar, a short stroke under every folder icon and the main
  action: the New Note button on iPhone and iPad, and Start Writing. On the Mac
  the toolbar's New Note button stays standard, like other Mac apps. Every
  folder gets the same stroke, so it never reads as a favorite. Lines such as
  link underlines use a deeper stroke of it in light mode, so they stand out on
  paper. Glyphs on it are always near-black, because every highlighter is
  light. Yellow is the default; pink, green and blue are the others. It can't
  be the app-wide accent, since white glyphs on it would be unreadable.
- **Paper** is the page behind notes and the library: a light paper gray in
  light mode and a slightly lifted black in dark mode. It also covers link
  previews, Version History, the launch and loading screens, and the Mac's
  window toolbar. The Recents card stays a lighter sheet on top. Settings keep
  system colors.
- Semantic colors stay system colors: red for destructive actions, orange
  for warnings, gray for neutral swipe actions.

The colors live in `MehStyle` and `MehPalette`. SwiftUI views read the
chosen pens from the environment (`\.mehPalette`); the editor gets them
like its font settings and redraws when they change. Black ink's accent
also lives in the asset catalog (`AccentColor`), and the launch screen
uses `LaunchPaper` and `LaunchFace`.

## Small moments

- Moving the open note to Trash briefly crumples the page toward its top
  corner. Swipe actions in lists keep the system animation.
- Checking the last open task of a note plays a light success haptic on
  iPhone. iPads have no haptics.
