import SwiftUI

/// The app icon's face, drawn from text characters. See
/// docs/design-language.md for where each mood belongs.
struct MehFace: View {
    enum Mood: CaseIterable {
        case neutral, pleased, asleep, surprised, skeptical, relaxed, broken, puzzled

        var glyphs: String {
            switch self {
            case .neutral: "•_•"
            case .pleased: "^_^"
            case .asleep: "-_-"
            case .surprised: "•o•"
            case .skeptical: "¬_¬"
            case .relaxed: "•‿•"
            case .broken: "×_×"
            case .puzzled: "•_•?"
            }
        }

        var next: Mood {
            let all = Mood.allCases
            return all[(all.firstIndex(of: self)! + 1) % all.count]
        }
    }

    let mood: Mood
    var size: CGFloat = 44

    @State private var easterEgg = MehFaceEasterEgg()
    @State private var isBlinking = false
    @ScaledMetric(relativeTo: .largeTitle) private var scale = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = easterEgg.mood ?? mood
        Text(verbatim: isBlinking ? shown.glyphs.replacingOccurrences(of: "•", with: "-")
                                  : shown.glyphs)
            .font(.system(size: size * scale, weight: .bold, design: .monospaced))
            .foregroundStyle(.secondary)
            .scaleEffect(easterEgg.isBouncing && !reduceMotion ? 0.88 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.5), value: easterEgg.isBouncing)
            .contentShape(Rectangle())
            .onTapGesture { easterEgg.advance(from: mood) }
            .sensoryFeedback(.selection, trigger: easterEgg.taps)
            .accessibilityHidden(true)
            .task(id: reduceMotion) {
                guard !reduceMotion else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Double.random(in: 3...6)))
                    isBlinking = true
                    try? await Task.sleep(for: .milliseconds(140))
                    isBlinking = false
                }
            }
    }
}

/// The library's large title: the app name with the face after it. iOS gives
/// views in the large-title slot no taps, so this face only blinks.
struct MehTitle: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: "meh.md")
                .font(.largeTitle.bold())
            MehFace(mood: .neutral, size: 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "meh.md"))
        .accessibilityAddTraits(.isHeader)
    }
}

/// Cycles through every mood on tap and returns to the resting face after a
/// short pause without taps.
@Observable
final class MehFaceEasterEgg {
    private(set) var mood: MehFace.Mood?
    private(set) var taps = 0
    private(set) var isBouncing = false
    private var settle: Task<Void, Never>?

    func advance(from resting: MehFace.Mood?) {
        mood = (mood ?? resting)?.next ?? .neutral
        taps += 1
        isBouncing = true
        settle?.cancel()
        settle = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.isBouncing = false
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.mood = nil
        }
    }
}
