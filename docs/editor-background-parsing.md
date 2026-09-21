# Background Markdown parsing

Deferred editor refreshes parse an immutable text snapshot outside the main
actor. The syntax cache allows one running parse and keeps only the latest
pending request. A character-edit generation and request identifier prevent a
result for an older buffer from being installed after the user has typed again.

The parser's input and output value types are `Sendable` and nonisolated.
Native text storage, presentation state, and styling remain on the main actor.
Initial editor configuration and explicit whole-buffer replacements remain
synchronous; only the refresh already deferred until the next main-queue turn
uses background preparation.

This trades immediate formatting completion for a more responsive main actor
when a full parse is expensive. Formatting can visibly catch up after the text
edit. A prior combined experiment measured roughly 1.2 seconds of final
presentation catch-up on a 500 KB simulator fixture. That run also included
other editor optimizations, so it does not validate this isolated change or
support a standalone speed claim. Physical-device performance and input-method
composition remain unmeasured.
