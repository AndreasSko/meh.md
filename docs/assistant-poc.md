# Private ChatGPT proof of concept

This preview adds ChatGPT account connection and a native iPhone notes chat.
It is available only in the iOS `meh.md iCloud Dev` scheme's `Debug-iCloud`
configuration, behind `CHATGPT_POC`. Release builds do not expose it. The app
version is 0.15.0.

## Current scope

- Settings offers **Continue with ChatGPT** in a private preview screen.
- Settings saves a default model for new chats, separately for each provider
  and account. It survives relaunch. The chat picker can override the model
  for a conversation during the current app session.
- A connected account enables a glass chat button above the leading end of
  the notebook's bottom toolbar. It hides while the keyboard is visible.
- Chat supports streaming replies, Stop, a model picker, New Chat, local
  history, and the system keyboard's dictation.
- History opens a native Chats sheet after dismissing composer focus. The
  model menu labels its choices as applying to the current chat.
- The assistant can search and read active notes in the current notebook.
  It can create normal saved notes and update notes when you request changes.
  Each reply shows one button per saved note, even when several tools refer
  to it. Buttons open the actual note. There is no separate draft stage.
- Messages and replies persist locally, partitioned by provider and account.
  They are excluded from device backup and notebook synchronization.
- Disconnect clears local credentials and requests remote revocation. Saved
  chats remain on the device and reappear when the same account reconnects.

This proof of concept does not record audio, call transcription APIs, or expose
ChatGPT conversation history. Those capabilities need separate implementation
work. Licensing and public distribution remain deferred.

## Integration boundary

`AssistantProvider` supplies a model catalog and a stream of text, tool
activity, and completion events. Tool definitions, calls, results, and
execution are provider independent. The chat controller owns turns and threads.
The ChatGPT adapter owns HTTP requests and the function-call loop. Only the
ChatGPT adapter is implemented. Future providers can reuse the notebook tools.
Providers await tool-activity callbacks before execution and after the result
so saved actions remain recorded when Stop closes the stream consumer.

Notebook tools use the existing `NotebookReplica` and `NoteSession` operations.
Creation saves a normal Markdown note in the default new-note folder. Updates
require a full read and its revision token; a newer edit causes the update to
fail rather than overwrite that edit. Trash, deleted or unavailable notes, and
switched or resetting notebooks are unavailable to tools. Existing Automerge
history and notebook synchronization continue to apply to saved AI changes.

Tools send selected note content to the provider as part of answering your
request. Reading a note does not upload the entire notebook. Tool output is
untrusted document content; provider instructions restrict writes to changes
requested by the user. Chats are scoped to their notebook and account.

Writes are executed sequentially with bounded calls and payloads. Successful
call IDs are deduplicated. Stop prevents further work; a write already started
may finish saving. Its result remains visible in chat even if the reply stops.
Local save failures are surfaced and are never automatically retried.

The authentication actor uses the documented public SIWC authorization and
token endpoints, dynamic client registration, PKCE, state, nonce, and verified
ID tokens. Issued client IDs remain bound to their original account. This
preview supports one account registration per device. Credentials use a
non-synchronizing, device-only Keychain item and are separate from transcripts.

On iOS, a foreground loopback listener binds `127.0.0.1` before opening
`SFSafariViewController`. Its callback checks the exact host, port, path, and
state. Sign-in times out after five minutes and cancels on backgrounding.
Cancelling an old attempt cannot invalidate a replacement attempt.

Safari can show **This Connection Is Not Secure** after login while returning
to this local HTTP callback. A physical iPhone check confirmed this warning
and successful sign-in/replies after returning. Current SIWC registration
requires HTTP loopback; Safari exposes no documented per-callback HTTPS-only
exemption. This is a private-preview limitation and a blocker for a seamless
public sign-in experience. The reported timing fits Safari's HTTP callback
warning. Login and inference requests continue to use HTTPS.

Inference uses public `/v1/models` and `/v1/responses`, bearer authorization,
`store: false`, and full input context. Notebook functions are supplied in a
namespace. Response items, including reasoning and function results, are
collected from completed stream items when the terminal event omits its
output list, then carried through tool continuations. Interrupted text stays
visible in chat but is omitted from subsequent model input. Completed tool
results inform later turns.
Network failures do not automatically repeat requests. Model refusals are
displayed as replies.

Official references:

- [SIWC sign-in][sign-in]
- [SIWC quickstart][quickstart]
- [SIWC overview][overview]
- [Function calling][functions]

[sign-in]: https://developers.openai.com/siwc/token-sharing-open-source/sign-in
[quickstart]: https://developers.openai.com/siwc/quickstart
[overview]: https://developers.openai.com/siwc
[functions]: https://developers.openai.com/api/docs/guides/function-calling

## Automated validation

Run `swift test --filter AssistantCoreTests` for synthetic OAuth/JWT/refresh,
request and SSE fixtures, account-separated local history, and a real host
loopback socket. Notebook fixtures cover durable creation and updates, search,
read revisions, stale-update rejection, and scope/cancellation boundaries.
These tests never use a real ChatGPT account.

`AssistantUITests` runs only with `CHATGPT_POC` on iOS. It uses the existing
isolated notebook preview with a unique run ID and automatic sync disabled.
The assistant fixture requires all preview checks to pass before bypassing
Keychain and networking. It exercises two turns, thread history after
relaunch, Stop, failure recovery, and optional connection settings. An iPhone
geometry check verifies that the button clears Search and New Note, hides
while typing, and returns after native keyboard dismissal on note detail.
It also checks button availability and toolbar separation in landscape.
The default-model case checks Settings selection, a distinct chat override,
New Chat returning to the default, and preference persistence after relaunch.
Tool fixtures use the real notebook executor, saving fictional notes and
checking their content through the native UI.

The dedicated PR workflow runs both groups and preserves logs, screenshots,
and an iPhone result bundle. Simulator and synthetic success do not establish
that a live SIWC grant works on a physical iPhone.

## Physical iPhone acceptance

Before treating the integration as ready for wider use:

1. Open the private iCloud Dev build on a physical iPhone, using a fictional
   local notebook preview when testing through automation.
2. Connect in Settings. Complete ChatGPT sign-in and allow plan access. Verify
   the browser returns to the app and a model is available.
3. Choose a default model in Settings. Start a new chat and confirm it uses
   that model. Relaunch and verify the saved preference is still selected.
4. Send a fictional question and a follow-up that depends on the first turn.
   Confirm both streamed replies are visible.
5. Start a new chat, reopen the earlier chat through History, and relaunch.
   Confirm the earlier chat is still available.
6. Try keyboard dictation, Stop, cancelling sign-in, and reconnecting. Verify
   errors leave the app usable.
7. Ask the assistant to create a fictional note, find and summarize it, then
   update a sentence. Open the saved-note button and verify its content and
   History. Verify the changed text remains after relaunch. Disconnect when
   the checks are complete.

Real account access, physical-device callback behavior, dictation, and plan
limits require this acceptance check; they are not covered by fixtures.
