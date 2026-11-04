import Foundation
import Testing
@testable import MehWidgetData

@Suite struct MehWidgetLinkTests {
    @Test func noteLinkRoundTrips() throws {
        let id = UUID()
        let url = MehWidgetLink.note(id).url
        #expect(url.absoluteString == "mehmd://note/\(id.uuidString)")
        #expect(MehWidgetLink(url: url) == .note(id))
    }

    @Test func newNoteLinkRoundTrips() {
        #expect(MehWidgetLink(url: MehWidgetLink.newNote.url) == .newNote)
    }

    @Test func otherURLsAreNotWidgetLinks() throws {
        for string in [
            "file:///tmp/a.md", "mehmd://note/not-a-uuid", "mehmd://note",
            "mehmd://new/extra", "https://example.com/note/\(UUID().uuidString)",
        ] {
            #expect(MehWidgetLink(url: try #require(URL(string: string))) == nil)
        }
    }
}

@Suite struct MehWidgetSnapshotTests {
    let pinned = MehWidgetSnapshot.Note(id: UUID(), title: "Lisbon in May", folders: ["Projects"])
    let recent = MehWidgetSnapshot.Note(id: UUID(), title: "Groceries", folders: [])
    let older = MehWidgetSnapshot.Note(id: UUID(), title: "Packing list", folders: [])
    let other = MehWidgetSnapshot.Note(id: UUID(), title: "Archive note", folders: ["Archive"])

    var snapshot: MehWidgetSnapshot {
        MehWidgetSnapshot(
            notes: [other, older, recent, pinned],
            recents: [
                .init(id: pinned.id, isPinned: true),
                .init(id: recent.id, isPinned: false),
                .init(id: UUID(), isPinned: false),
                .init(id: older.id, isPinned: false),
            ],
            contents: [.init(id: recent.id, text: "- [ ] lemons", excerpt: "lemons", modifiedAt: nil)],
            ink: "black", highlighter: "yellow"
        )
    }

    @Test func recentRowsKeepPinsFirstAndSkipMissingNotes() {
        let rows = snapshot.recentRows(limit: 5)
        #expect(rows.map(\.note) == [pinned, recent, older])
        #expect(rows.map(\.isPinned) == [true, false, false])
        #expect(rows[1].content?.text == "- [ ] lemons")
    }

    @Test func recentRowsStopAtTheLimit() {
        #expect(snapshot.recentRows(limit: 2).map(\.note) == [pinned, recent])
        #expect(snapshot.recentRows(limit: 0).isEmpty)
    }

    @Test func pickerStartsWithRecentsThenTitles() {
        #expect(snapshot.notesForPicker == [pinned, recent, older, other])
    }
}

@Suite struct MehWidgetStoreTests {
    func temporaryStore() -> MehWidgetStore {
        MehWidgetStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("MehWidgetStoreTests-\(UUID().uuidString)"))
    }

    @Test func saveReportsOnlyChanges() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let snapshot = MehWidgetSnapshot(
            notes: [.init(id: UUID(), title: "A", folders: [])], recents: [],
            contents: [], ink: "black", highlighter: "pink"
        )
        #expect(store.load() == nil)
        #expect(try store.save(snapshot))
        #expect(try !store.save(snapshot))
        #expect(store.load() == snapshot)
    }

    @Test func requestsAccumulateAndArePruned() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let first = UUID(), second = UUID()
        try store.requestContent(for: first)
        try store.requestContent(for: second)
        try store.requestContent(for: first)
        #expect(store.requestedNoteIDs() == [first, second])
        try store.keepRequests([second, UUID()])
        #expect(store.requestedNoteIDs() == [second])
    }

    @Test func requestsKeepOnlyTheNewest() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let ids = (0..<(MehWidgetStore.requestLimit + 2)).map { _ in UUID() }
        for id in ids { try store.requestContent(for: id) }
        try store.requestContent(for: ids[2])
        #expect(store.requestedNoteIDs() == Set(ids.suffix(MehWidgetStore.requestLimit)))
    }
}

@Suite struct MehWidgetTimeTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    let locale = Locale(identifier: "en_US")

    func label(_ secondsAgo: TimeInterval, compact: Bool = false) -> String {
        MehWidgetTime.label(
            for: now.addingTimeInterval(-secondsAgo), now: now, compact: compact,
            calendar: calendar, locale: locale
        )
    }

    @Test func recentChangesUseMinutesAndHours() {
        #expect(label(20) == "now")
        #expect(label(2 * 60) == "2 min")
        #expect(label(2 * 60, compact: true) == "2m")
        #expect(label(3 * 3_600) == "3 h")
        #expect(label(3 * 3_600, compact: true) == "3h")
    }

    @Test func olderChangesUseWeekdayThenDate() {
        #expect(label(2 * 86_400) == "Wed")
        #expect(label(30 * 86_400) == "Dec 16")
    }

    @Test func futureDatesCountAsNow() {
        #expect(label(-120) == "now")
    }
}

@Suite struct MehWidgetMarkdownTests {
    @Test func recognizesBlocks() {
        let text = """
        # Trip
        Four days.

        - [ ] Book table
        - [x] Flights
        * Pastéis
        2. Sintra
        > Quote
        ---
        ```
        code
        ```
        """
        #expect(MehWidgetMarkdown.blocks(from: text) == [
            .heading("Trip"), .paragraph("Four days."),
            .task("Book table", done: false), .task("Flights", done: true),
            .bullet("Pastéis"), .numbered("Sintra", number: "2"), .quote("Quote"),
            .paragraph("code"),
        ])
    }

    @Test func splitsHighlightsAndLinks() {
        #expect(MehWidgetMarkdown.spans(in: "See [[Packing list]] and ==Pastéis== *now*") == [
            .text("See "), .link("Packing list"), .text(" and "),
            .highlight("Pastéis"), .text(" *now*"),
        ])
        #expect(MehWidgetMarkdown.spans(in: "[[Target|Shown]]") == [.link("Shown")])
        #expect(MehWidgetMarkdown.spans(in: "plain") == [.text("plain")])
    }
}

@Suite struct MehWidgetRecentsLayoutTests {
    typealias Layout = MehWidgetRecentsLayout

    @Test func eachSizeCapsTheChosenCount() {
        #expect(Layout.limit(count: 12, previews: false, size: .small) == 5)
        #expect(Layout.limit(count: 12, previews: false, size: .medium) == 6)
        #expect(Layout.limit(count: 12, previews: false, size: .large) == 12)
        #expect(Layout.limit(count: 4, previews: false, size: .medium) == 4)
    }

    @Test func previewsShowFewerNotes() {
        #expect(Layout.limit(count: 12, previews: true, size: .small) == 3)
        #expect(Layout.limit(count: 12, previews: true, size: .medium) == 3)
        #expect(Layout.limit(count: 12, previews: true, size: .large) == 8)
        #expect(Layout.limit(count: 12, previews: true, size: .extraLarge) == 8)
    }

    // Line heights of the default text size: subheadline 20, footnote 18.
    // A medium iPhone widget has 134 points for its rows.
    @Test func moreRowsSwitchToCompactText() {
        let five = Layout.plan(limit: 5, columns: 1, height: 134, regularText: 20, compactText: 18)
        #expect(five.count == 5 && !five.isCompact)
        let six = Layout.plan(limit: 6, columns: 1, height: 134, regularText: 20, compactText: 18)
        #expect(six.count == 6 && six.isCompact)
    }

    @Test func rowsShareTheHeight() {
        let plan = Layout.plan(limit: 5, columns: 1, height: 330, regularText: 20, compactText: 18)
        #expect(plan.rowHeight == 66)
    }

    @Test func largeTextDropsRows() {
        let plan = Layout.plan(limit: 6, columns: 1, height: 134, regularText: 40, compactText: 36)
        #expect(plan.count == 3)
    }

    @Test func zeroHeightKeepsOneRow() {
        let plan = Layout.plan(limit: 5, columns: 1, height: 0, regularText: 20, compactText: 18)
        #expect(plan.count == 1 && plan.rowHeight == 0)
    }

    @Test func columnsShareTheRows() {
        let plan = Layout.plan(limit: 12, columns: 2, height: 134, regularText: 20, compactText: 18)
        #expect(plan.count == 12 && plan.isCompact)
    }

    @Test func buttonCoversTheLastRowsOfADenseList() {
        func covered(_ rows: Int, gap: Double = 0) -> Int {
            Layout.rowsUnderButton(
                rows: rows, rowHeight: 134 / Double(rows), text: 18, gap: gap,
                buttonTop: 30
            )
        }
        #expect(covered(3) == 1)
        #expect(covered(5) == 1)
        #expect(covered(6) == 2)
        #expect(covered(3, gap: 40) == 0)
    }
}
