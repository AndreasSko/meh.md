import Automerge
import Foundation

/// The first note of a new notebook. Every device builds the exact same
/// Automerge change from `text`, so welcome notes created offline on several
/// devices share one history and merge on first sync.
///
/// To change the text, also use a new `id` and `heads`: disconnected
/// histories cannot merge. `NotebookWelcomeNoteTests` prints the new heads.
public enum NotebookWelcomeNote {
    public static let id = UUID(uuidString: "CE0DE997-2CAB-4B2F-9420-77D607896935")!
    public static let name = "Hi •_•"
    static let heads: Set<String> = [
        "f0f72859b7ee8039158b323907fd4c7ed04fb0aaf52f8f1c04eea403bd806ecb",
    ]

    static func snapshot() throws -> NoteSnapshot {
        let date = Date(timeIntervalSince1970: 1_792_195_200)
        return try NoteDocument(
            noteID: id, text: text,
            metadata: NoteMetadata(createdAt: date, modifiedAt: date),
            actor: ActorId(uuid: UUID(uuidString: "A51A9304-C091-428A-AD8E-DE78E527E77B")!)
        ).snapshot()
    }

    static let text = """
        I'm your first note. Edit me, keep me, or just throw me away.

        meh.md is meant to be simple: Markdown notes and iCloud sync that just works. Edit the same note on multiple devices, even offline. Changes merge automatically, without conflicts 🙌

        ### A few things you can try out

        - [ ] Style a word or sentence with the formatting bar.
        - [ ] Type `[[` to link another note.
        - [ ] Open meh.md on another device. I'll be there.

        ### Good to know

        - Recent notes wait at the top of Files. Pin the ones you love.
        - Long-press (or right-click) a note or folder to use it as a **template** or **snippet**.
        - Rewrite as often as you like. Every version stays in **…** › **Version History**.

        New to Markdown? Tap (or click) this line to peek behind it: **bold**, *italic*, ~~strike~~, ==highlight==, `code`. Or switch to **Markdown Source** to see it all.

        > P.S. I built meh.md as the notes app I always wanted: minimal, Markdown, great sync.
        > Almost boring (dare I say "meh"?), but in a good way: It just works 👌
        > Hope it does for you too :)
        > 
        > Andreas

        (P.P.S. meh.md is still a work in progress. If you notice a bug, feel free to send feedback on [GitHub](https://github.com/AndreasSko/meh.md) or via the settings.)
        """
}
