import Automerge
import Foundation

/// The first note of a new notebook. Every device builds the exact same
/// Automerge change from `text`, so welcome notes created offline on several
/// devices share one history and merge on first sync.
///
/// To change the text, also use a new `id` and `heads`: disconnected
/// histories cannot merge. `NotebookWelcomeNoteTests` prints the new heads.
public enum NotebookWelcomeNote {
    public static let id = UUID(uuidString: "CCB4E987-B2CC-47EB-B509-0B6D1476D403")!
    public static let name = "Hi •_•"
    static let heads: Set<String> = [
        "2abdae288ffada0c3db8de164cba97ca1eae7052a631c2471fd659dbff463eba",
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
        I'm your first note. Edit, keep, or toss me.

        meh.md keeps it simple: plain Markdown notes and sync that just works. Your notes sync through your iCloud, no extra account or login. Edit the same note on multiple devices, even offline. Changes merge, no conflicts.

        A few things to poke at, no pressure:

        - [ ] Style a word with the formatting bar. On Mac: **Formatting** in the toolbar.
        - [ ] Type `[[` to link another note.
        - [ ] Open meh.md on another device. I'll be there.

        Good to know:

        - Recent notes wait at the top of Files. Pin the ones you love.
        - Long-press (or right-click) a note: **Use as Template** or **Use as Snippet**.
        - Rewrite as often as you like. Every version stays in **…** › **Version History**.

        > P.S. I built meh.md as the notes app I always wanted: minimal, Markdown, great sync. A bit meh, almost boring. It just works. Hope it does for you too. – Andreas

        """
}
