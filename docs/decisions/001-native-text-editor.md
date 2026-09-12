# ADR 001: Use native text views in SwiftUI

- Status: Accepted
- Date: 2026-09-12

## Context

- The editor must retain literal Markdown while presenting syntax styles.
- Styling must not add formatting-only undo entries.
- The app should use SwiftUI wherever it meets those requirements.
- macOS, iPhone, and iPad should share syntax and document behavior.

## Decision

- Use SwiftUI for the application interface and editor container.
- Wrap `NSTextView` on macOS and `UITextView` on iOS and iPadOS.
- Configure both native views to use TextKit 2 explicitly.
- Use TextKit 2 rendering attributes for paint-only presentation such as
  foreground and background colors.
- Apply font attributes through native text storage, with undo registration
  suppressed and never during marked-text composition.
- Keep headings at body size in milestone 0; bold distinguishes them until
  layout-changing heading styles are implemented and tested in milestone 1.
- Keep syntax detection and future document operations in shared Swift code.
- Treat native UTF-16 ranges as a platform boundary, not a storage encoding.

## Rationale

- An attributed SwiftUI `TextEditor` rendered the required styles and retained
  literal source on the current deployment targets.
- Reapplying derived attributes created a separate undo action before the text
  edit, both after change observation and inside a custom binding setter.
- Disabling SwiftUI's environment undo manager did not suppress that action.
- SwiftUI exposes neither the underlying text view nor marked-text state.
- TextKit 2 rendering attributes do not mutate the document, but they also do
  not affect layout. A probe with a 40-point rendering font retained the
  14-point line-fragment height.
- Native text views provide TextKit 2, undo, selection, and composition hooks
  through a small platform-specific surface.

## Consequences

- Most of the app remains SwiftUI and shared Swift.
- The text adapter requires separate AppKit and UIKit implementations.
- Paint-only styling does not enter the document's undo history.
- Layout-changing styles require carefully managed text-storage attributes or
  a later custom layout implementation.
- Input-method composition remains unverified by product choice. The owner has
  tested iPhone undo; iPad undo remains open.
- FSNotes remains a behavioral reference and no source dependency is added.
