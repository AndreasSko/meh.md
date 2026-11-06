import Foundation

/// A fictional note together with what Live Preview must draw for it.
/// Each block records its source range as the note is built, so the checks
/// know where every bullet, checkbox, rule and panel belongs without asking
/// the drawing code.
struct EditorRenderingFixture {
    struct List: Equatable {
        /// The text after each item's marker.
        var items: [NSRange]
        var isTaskList: Bool
    }

    struct Panel: Equatable {
        enum Kind { case quote, code }
        let kind: Kind
        /// From the first line's first character to the last line's last.
        let range: NSRange
    }

    private(set) var source = ""
    private(set) var lists: [List] = []
    private(set) var rules: [Int] = []
    private(set) var panels: [Panel] = []
    /// The `=` of each `Total =` line.
    private(set) var totals: [Int] = []
    /// Paragraphs that history marks as changed.
    var changedRanges: [NSRange] { olderLines.map(\.range) }
    /// What an older version had in place of each changed line.
    private var olderLines: [(range: NSRange, text: String)] = []

    private var length: Int { (source as NSString).length }

    private mutating func block(_ text: String) -> Int {
        if !source.isEmpty { source += "\n\n" }
        let start = length
        source += text
        return start
    }

    mutating func heading(_ text: String) {
        _ = block("# " + text)
    }

    mutating func paragraph(_ text: String) {
        _ = block(text)
    }

    /// A list, or a task list when `checked` is given, optionally right
    /// below a paragraph with no blank line between them.
    mutating func list(
        _ items: [String], checked: [Bool]? = nil, after paragraph: String? = nil
    ) {
        var ranges: [NSRange] = []
        var text = paragraph.map { $0 + "\n" } ?? ""
        for (index, item) in items.enumerated() {
            if index > 0 { text += "\n" }
            if let checked {
                text += checked[index] ? "- [x] " : "- [ ] "
            } else {
                text += "- "
            }
            ranges.append(NSRange(
                location: (text as NSString).length, length: (item as NSString).length
            ))
            text += item
        }
        let start = block(text)
        lists.append(List(
            items: ranges.map { NSRange(location: start + $0.location, length: $0.length) },
            isTaskList: checked != nil
        ))
    }

    mutating func quote(_ lines: [String]) {
        let text = lines.map { "> " + $0 }.joined(separator: "\n")
        let start = block(text)
        panels.append(Panel(
            kind: .quote, range: NSRange(location: start, length: (text as NSString).length)
        ))
    }

    mutating func code(_ lines: [String]) {
        let text = (["```"] + lines + ["```"]).joined(separator: "\n")
        let start = block(text)
        panels.append(Panel(
            kind: .code, range: NSRange(location: start, length: (text as NSString).length)
        ))
    }

    mutating func rule() {
        rules.append(block("---"))
    }

    /// Time values followed by a `Total =` line.
    mutating func total(_ lines: [String]) {
        let text = (lines + ["Total ="]).joined(separator: "\n")
        let start = block(text)
        totals.append(start + (text as NSString).length - 1)
    }

    /// A paragraph that an older version of the note had in another form.
    mutating func changedParagraph(_ text: String, was older: String) {
        let start = block(text)
        olderLines.append((NSRange(location: start, length: (text as NSString).length), older))
    }

    /// The same note with text typed at its end.
    func appending(_ text: String) -> Self {
        var note = self
        note.source += text
        return note
    }

    /// The note as it was before `changedParagraph` lines were written.
    var historicalSource: String {
        var result = source as NSString
        for line in olderLines.reversed() {
            result = result.replacingCharacters(in: line.range, with: line.text) as NSString
        }
        return result as String
    }
}

extension EditorRenderingFixture {
    /// Every kind of decoration on about one screen. Irregular on purpose:
    /// with evenly spaced lines, a mark one line off would still find a line.
    static var showcase: Self {
        var note = Self()
        note.heading("Packing")
        note.list(
            [
                "Amber lantern",
                "Blue compass with a deliberately long description that wraps "
                    + "across several lines in the editor",
                "Cedar basket",
            ],
            after: "Before the trip we check the list."
        )
        note.quote(["Patient observation", "continues here."])
        note.code(["let lantern = 17", "print(\"Cedar\")"])
        note.rule()
        note.list(["Pack a map", "Mark the route"], checked: [false, true])
        note.total(["Ferry 1h 20m", "Walk 45m"])
        note.paragraph("Final words of the fictional journal.")
        return note
    }

    /// Many screens of irregular sections, long enough that TextKit only
    /// estimates the lines outside the window.
    static func long(sections: Int) -> Self {
        var note = Self()
        let prose = "The fictional Cedar Observatory team measured the clouds "
            + "above Lake Amber, with sentences long enough to wrap across "
            + "the width of the editor."
        for section in 1...sections {
            note.heading("Field journal \(section)")
            note.paragraph(String(repeating: prose + " ", count: 1 + section % 3))
            if section.isMultiple(of: 2) {
                note.list(
                    ["Amber lantern \(section)", "Cedar basket \(section)"],
                    after: "Items for section \(section):"
                )
            } else {
                note.list([
                    "Amber lantern \(section)",
                    "Blue compass \(section) with a long description that wraps "
                        + "across several lines of the editor",
                    "Cedar basket \(section)",
                ])
            }
            if section.isMultiple(of: 3) {
                note.quote(["Patient observation \(section)", "continues here."])
            } else {
                note.code(["let section = \(section)"])
            }
            note.rule()
            if section % 4 == 1 {
                note.list(["Map \(section)", "Route \(section)"], checked: [false, true])
            }
        }
        note.paragraph("End of the journal.")
        return note
    }

    /// Changed lines between unchanged ones, for history's margin marks.
    static var history: Self {
        var note = Self()
        note.heading("Harbor log")
        note.paragraph("The ferry left on time.")
        note.changedParagraph("The wind turned north after noon.", was: "The wind was calm.")
        note.paragraph("Gulls followed the boat.")
        note.list(["Amber lantern", "Cedar basket"])
        note.changedParagraph(
            "A longer changed paragraph that wraps across several lines of the "
                + "editor, so its mark must cover every one of them.",
            was: "A short paragraph."
        )
        note.paragraph("The harbor lights came on.")
        return note
    }
}
