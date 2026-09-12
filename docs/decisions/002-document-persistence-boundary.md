# ADR 002: Separate documents from Markdown copies

## Status

| Date       | Status      | Contributors |
| ---------- | ----------- | ------------ |
| 2026-09-12 | ✅ Accepted | Andreas      |

## Context

- Milestone 1 needs a durable note without coupling the editor to storage.
- Milestone 2 may change internal document mechanics when sync is introduced.
- Markdown files must stay portable without becoming a second source of truth.

## Considerations

- A note needs an identity that does not change with its filename or location.
- A successful save must mean authoritative state is durable locally.
- Markdown materialization can fail and be retried independently of editing.
- External file changes must not silently replace authoritative content.

## Decision

We will place a shared document core between the native editor and all storage.

- The core owns stable note identity, literal Markdown text, metadata, and edit
  application.
- A local store persists authoritative document state before a save is
  acknowledged.
- A separate writer maintains user-visible Markdown as a derived copy and
  tracks materialization work that still needs retrying.
- The editor and future sync transport depend on the document core, not on
  each other or on Markdown files.

## Consequences

- Milestone 1 can start with local document mechanics without exposing them to
  the AppKit or UIKit adapters.
- Milestone 2 can introduce Automerge behind the document core boundary.
- A note may be durably saved while its Markdown copy is visibly pending.
- Storage schema, transaction details, and recovery policy remain Milestone 1
  decisions.

## Alternatives considered

- Markdown files as authoritative state were rejected because external edits
  and later synchronization would create competing writers.
- Persistence inside the native editor was rejected because it would duplicate
  platform code and couple editing behavior to storage.
- Introducing Automerge during Milestone 0 was rejected until the local
  durability contract is implemented and tested.

## Related decisions

- [ADR 001](001-native-text-editor.md) keeps platform text views behind a
  shared SwiftUI editor boundary.
