# Design language

meh.md should feel like a proper Apple app first. Its own character comes
from the app icon: a sheet of paper, black ink, and a face made of three text
characters, `•_•`. The name is a joke too: everything works, nothing is
earth-shattering. The app can show that humor, but only where it does not get
in the way.

## Rules

- **The shell stays Apple.** System fonts, Liquid Glass toolbars, standard
  lists, menus, gestures and SF Symbols. No custom controls just for looks.
- **Faces only where the screen would otherwise be empty.** Empty lists, no
  search results, Sync Details with nothing to report, and one at the end
  of Settings. Never in toolbars, menus or the rows of notes and folders.
  The sync button stays an SF Symbol because it is faster to read.
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
| `•_•` | neutral | empty library, no selection, no backlinks, Settings |
| `•_•?` | puzzled | search without results |
| `^_^` | pleased | empty Trash |
| `•‿•` | relaxed | Sync Details when everything is synced |
| `-_-` | asleep | Sync Details when sync is off |

Faces with dot eyes blink every few seconds. Tapping a face cycles through
all moods for a moment and then settles back. This is an easter egg, not a
feature, so nothing depends on it. The end of Settings always has a face
next to the version, so there is one place to find it.

The `meh.md` title stays the native large title. iOS 27 neither passes taps
to a custom view in the large-title slot nor shows it to VoiceOver.

## Color

- **Ink** is the accent: near-black in light mode and near-white in dark
  mode, like the lettering on the icon. It replaces system blue for buttons,
  links, checkboxes, selection and the blockquote bar. System controls put
  white glyphs on the accent, so in dark mode the app-wide accent is a mid
  gray instead of near-white. The editor and the main buttons, where we
  choose the color on top, always use true ink. On the Mac the system
  accent setting still wins for standard controls, as usual for Mac apps.
- **Paper** is the page behind a note: a light paper gray in light mode
  and a slightly lifted black in dark mode. It covers the editor, link
  previews and Version History. Lists and Settings keep system colors.
- **Highlighter** is a marker yellow for `==highlights==` and for the spot
  a search result or link jumps to. It is dimmer in dark mode, so white
  text on it stays readable.
- Semantic colors stay system colors: red for destructive actions, orange
  for warnings, gray for neutral swipe actions.

The colors live in `MehStyle`, and the accent also in the asset catalog
(`AccentColor`) for SwiftUI.

## Small moments

- Moving the open note to Trash briefly crumples the page toward its top
  corner. Swipe actions in lists keep the system animation.
- Checking the last open task of a note plays a light success haptic on
  iPhone. iPads have no haptics.
