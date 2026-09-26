# Product brief

Updated: 2026-09-13

## Idea

meh.md is a small, beautiful, native Markdown note app for personal use on Mac,
iPhone, and iPad. It should replace the owner's current Obsidian workflow with
a calmer interface and dependable sync, without accumulating features the owner
does not need.

This is the owner's vibe-coded Swift app, with a SwiftUI interface and native
text editing. Its features follow personal needs and preferences. An App Store
release is a possibility later, after the app works well for daily use.

The existing library contains hundreds of notes in a few subdirectories. It
does not depend on Obsidian-specific wiki links, frontmatter, or embedded
files.

## First-version requirements

- Native interface on all three device types, including an adaptable iPad
  layout and hardware-keyboard use.
- Markdown editing with formatted headings, emphasis, lists, links, and code.
  Visible Markdown syntax is explicitly acceptable initially.
- A simple folder hierarchy with creating, opening, renaming, moving, and
  deleting notes and folders.
- Immediate local editing and saving without a network connection; reliable
  synchronization after reconnecting.
- Ordinary Markdown copies continuously maintained in user-visible local
  storage, with folder structure preserved. These are readable portable
  copies, not an external editing interface.
- Initial import of the existing Markdown directory without changing the source
  library.
- Basic native selection and undo, recoverable deletion, and a way to recover
  earlier note content.

Target iOS 27, iPadOS 27, and macOS 27 on the owner's devices.

## Explicitly outside initial scope

- External editing, file watching, and merging changes from other editors.
- Inline image rendering, interactive checkboxes, and rendered tables. Preserve
  their source text if encountered.
- Obsidian plugins, graphs, backlinks, databases, collaboration, and other
  expanded productivity features.
- Application-level end-to-end encryption. The first version may rely on a
  CloudKit private database and the platforms' normal data protection.
- Public release preparation, commercial features, support for other users'
  older devices, and non-Apple platforms.

Top-level [table rendering and editing](table-rendering.md) is a later
addition, with ordinary Markdown editing when a table is active and source
commands for insertion, rows, columns, alignment, and cell navigation.

Syntax hiding/revealing around the cursor is now in milestone 4, alongside
search, richer Markdown presentation, and everyday writing conveniences.
Advanced cursor preservation and undo behavior across remote changes can also
be refined later; ordinary typing, selection, and undo must work from the
beginning.

## What success looks like

The owner can write comfortably on any of the three devices, switch devices
without manually managing files, and find the same notes and folders. Offline
work survives restarting the app and eventually reaches the other devices. The
library remains accessible as ordinary Markdown if the app is abandoned.

Sync does not need live multiplayer behavior. It does need understandable
pending/error states, tested recovery, and no silent loss of acknowledged local
edits.

## Development approach

The app uses SwiftUI with native AppKit/UIKit text editors, following the
completed editor investigation. Most implementation, builds, and automated
checks are agent-driven. The owner directs product decisions and tests actual
writing and device handoff. Keep scope narrow and deliver usable increments.
