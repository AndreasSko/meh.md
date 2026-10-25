import NoteCore
import SwiftUI
import TipKit

private struct NoteHistoryDetailTip: Tip {
    var title: Text { Text("See every change") }
    var message: Text? {
        #if os(macOS)
        Text("Pinch the timeline or press ⌘+.")
        #else
        Text("Slide your finger up while dragging the timeline.")
        #endif
    }
}

/// History's bottom rail. See docs/note-history.md.
struct NoteHistoryTimelineView: View {
    let isLoading: Bool
    let timeline: NoteHistoryTimeline
    let versions: [NoteHistoryVersion]
    let selectedIndex: Int
    let changes: NoteHistoryChanges
    @Binding var isDetailed: Bool
    let select: (_ index: Int, _ base: Int?) -> Void

    private struct Drag {
        var consumed: CGFloat = 0
        var residual: CGFloat = 0
        var isLifted = false
        var hasMoved = false
    }

    @State private var drag: Drag?
    @State private var hoverX: CGFloat?
    @FocusState private var isFocused: Bool
    @Environment(\.mehPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var sizeClass
    private let tip = NoteHistoryDetailTip()

    /// Detail spacing between single saved states.
    private static let detailSpacing: CGFloat = 8
    /// How far above the rail a finger switches to every saved state.
    private static let detailLift: CGFloat = 40
    /// Dragging less than one tick still has to feel like a step.
    private static let minimumStep: CGFloat = 6
    private static let baseline: CGFloat = 40
    private static let height: CGFloat = 58
    private static let maxTick: CGFloat = 22

    private var showsDetail: Bool { isDetailed || drag?.isLifted == true }
    /// A state picked inside a session, by lifting the finger or with ⌥,
    /// stays a single state after the rail folds back.
    private var showsSingleState: Bool {
        showsDetail || !timeline.isSessionEnd(selectedIndex)
    }
    private var metrics: NoteHistoryTimeline.Metrics {
        sizeClass == .compact ? .compact : .regular
    }
    private var selectedItem: NoteHistoryTimeline.Item {
        selectedIndex >= versions.count ? .current : timeline.item(containing: selectedIndex)
    }

    var body: some View {
        VStack(spacing: 6) {
            VStack(spacing: 6) {
                GeometryReader { geometry in
                    rail(width: geometry.size.width)
                }
                .frame(height: Self.height)
                .frame(maxWidth: 560)
                .popoverTip(tip, arrowEdge: .bottom)
                caption
            }
            .frame(maxWidth: .infinity)
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
                step(by: press.key == .leftArrow ? -1 : 1,
                     detailed: isDetailed || press.modifiers.contains(.option))
                return .handled
            }
            .background { zoomShortcuts }
            // The current text's index grows while History loads; only a
            // new selection should tick.
            .sensoryFeedback(.selection, trigger: selectedIndex >= versions.count ? -1 : selectedIndex)
            .onAppear { isFocused = true }
            .accessibilityElement()
            .accessibilityLabel("Version timeline")
            .accessibilityValue(accessibilityValue)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: step(by: 1, detailed: isDetailed)
                case .decrement: step(by: -1, detailed: isDetailed)
                @unknown default: break
                }
            }
            .accessibilityAction(named: isDetailed ? "Show Edit Sessions" : "Show Every Change") {
                isDetailed.toggle()
            }
            .accessibilityActions {
                if !changes.removed.isEmpty {
                    Button("Read Removed Text") {
                        let text = changes.removed.map(\.text).joined(separator: "\n")
                        AccessibilityNotification.Announcement(
                            String(localized: "Removed: \(text)")
                        ).post()
                    }
                }
            }
            .accessibilityIdentifier("note-history-timeline")
        }
        .onChange(of: isDetailed) { _, detailed in
            if detailed { tip.invalidate(reason: .actionPerformed) }
        }
        // Each level compares with its own previous version.
        .onChange(of: showsDetail) { _, detailed in
            guard selectedIndex < versions.count else { return }
            select(selectedIndex, base(of: selectedIndex, detailed: detailed))
        }
        // Like the jumper, loading floats so the preview does not shift
        // when it ends.
        .overlay(alignment: .top) {
            if isLoading {
                ProgressView("Loading versions…")
                    .font(.caption)
                    .accessibilityIdentifier("note-history-index-loading")
                    .alignmentGuide(.top) { $0[.bottom] + 4 }
            }
        }
    }

    // MARK: Rail

    private struct Tick: Identifiable {
        enum Tone { case selected, near, far }
        let id: Int
        let x: CGFloat
        let height: CGFloat
        let tone: Tone
        var isDot = false
    }

    private struct DayLabel: Identifiable {
        let id: Int
        let text: String
        let x: CGFloat
    }

    @ScaledMetric(relativeTo: .caption2) private var labelCharacterWidth: CGFloat = 5.8

    private func rail(width: CGFloat) -> some View {
        let item = selectedItem
        let layout = timeline.layout(spreading: timeline.day(of: item), metrics: metrics)
        let residual = drag?.residual ?? 0
        let center = width / 2
        let offset = center - layout.x(of: item) + residual
        let detail = showsDetail
        let ticks = detail
            ? detailTicks(center: center + residual, width: width)
            : overviewTicks(layout: layout, offset: offset, width: width, selected: item)
        let labels = detail
            ? detailLabels(center: center + residual, width: width)
            : overviewLabels(layout: layout, offset: offset, width: width, selected: item)
        let selectedHeight = detail ? detailTickHeight(selectedIndex) : itemTickHeight(item)
        return ZStack(alignment: .topLeading) {
            if !detail, let day = timeline.day(of: item) {
                let range = layout.dayRanges[day]
                RoundedRectangle(cornerRadius: 7)
                    .fill(.quaternary.opacity(0.6))
                    .frame(width: range.upperBound - range.lowerBound + 14, height: Self.maxTick + 9)
                    .position(
                        x: (range.lowerBound + range.upperBound) / 2 + offset,
                        y: Self.baseline - Self.maxTick / 2 + 0.5
                    )
            }
            ForEach(ticks) { tick in
                tickView(tick)
            }
            ForEach(labels) { label in
                Text(label.text)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .position(x: label.x, y: Self.baseline + 11)
            }
            MehFace(mood: .neutral, size: 8)
                .frame(width: 22, height: 22)
                .background(MehStyle.paperColor, in: .circle)
                .overlay(Circle().strokeBorder(.separator))
                .allowsHitTesting(false)
                .position(x: center + residual, y: Self.baseline - selectedHeight - 14)
            if let hoverX, drag == nil, !detail {
                hoverLabel(at: hoverX, layout: layout, offset: offset)
            }
        }
        .frame(width: width, height: Self.height)
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.12),
                    .init(color: .black, location: 0.88),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading, endPoint: .trailing
            )
        }
        .contentShape(Rectangle())
        // Following a finger must not lag behind it; only taps, keys and
        // releases animate.
        .animation(reduceMotion || drag != nil ? nil : .spring(duration: 0.3), value: selectedIndex)
        .animation(reduceMotion ? nil : .spring(duration: 0.3), value: detail)
        .gesture(dragGesture(width: width))
        .simultaneousGesture(
            MagnifyGesture().onEnded { value in
                if value.magnification > 1.15 { isDetailed = true }
                if value.magnification < 0.87 { isDetailed = false }
            }
        )
        .onContinuousHover { phase in
            switch phase {
            case let .active(location): hoverX = location.x
            case .ended: hoverX = nil
            }
        }
    }

    @ViewBuilder
    private func tickView(_ tick: Tick) -> some View {
        let style: AnyShapeStyle = switch tick.tone {
        case .selected: AnyShapeStyle(palette.inkColor)
        case .near: AnyShapeStyle(.secondary)
        case .far: AnyShapeStyle(.tertiary)
        }
        if tick.isDot {
            Circle()
                .fill(style)
                .frame(width: 7, height: 7)
                .position(x: tick.x, y: Self.baseline - 3.5)
        } else {
            let width: CGFloat = tick.tone == .selected ? 2.5 : 2
            Capsule()
                .fill(style)
                .frame(width: width, height: tick.height)
                .position(x: tick.x, y: Self.baseline - tick.height / 2)
        }
    }

    private func overviewTicks(
        layout: NoteHistoryTimeline.Layout, offset: CGFloat, width: CGFloat,
        selected: NoteHistoryTimeline.Item
    ) -> [Tick] {
        let selectedDay = timeline.day(of: selected)
        var ticks: [Tick] = []
        var lastX = -CGFloat.infinity
        var index = firstSession(atOrAfter: -offset - 8, in: layout)
        while index < timeline.sessions.count, layout.sessionX[index] + offset <= width + 8 {
            let x = layout.sessionX[index] + offset
            let isSelected = selected == .session(index)
            // A busy folded day draws more ticks than fit; skip the hidden ones.
            if isSelected || x - lastX >= 1.5 {
                ticks.append(Tick(
                    id: index, x: x,
                    height: NoteHistoryTimeline.tickHeight(for: timeline.sessions[index].size),
                    tone: isSelected ? .selected
                        : (timeline.dayIndex(ofSession: index) == selectedDay ? .near : .far)
                ))
                lastX = x
            }
            index += 1
        }
        ticks.append(Tick(
            id: -1, x: layout.currentX + offset, height: 7,
            tone: selected == .current ? .selected : .near, isDot: true
        ))
        return ticks
    }

    private func overviewLabels(
        layout: NoteHistoryTimeline.Layout, offset: CGFloat, width: CGFloat,
        selected: NoteHistoryTimeline.Item
    ) -> [DayLabel] {
        let selectedDay = timeline.day(of: selected)
        var occupied: [ClosedRange<CGFloat>] = []
        if let selectedDay {
            let range = layout.dayRanges[selectedDay]
            occupied.append(range.lowerBound + offset - 10 ... range.upperBound + offset + 10)
        }
        var labels: [DayLabel] = []
        func add(_ text: String, at x: CGFloat, id: Int) {
            let half = CGFloat(text.count) * labelCharacterWidth / 2 + 4
            let span = x - half ... x + half
            guard span.lowerBound > 0, span.upperBound < width,
                  !occupied.contains(where: { $0.overlaps(span) }) else { return }
            occupied.append(span)
            labels.append(DayLabel(id: id, text: text, x: x))
        }
        if selected != .current {
            add(String(localized: "Now"), at: layout.currentX + offset, id: -1)
        }
        for dayIndex in timeline.days.indices.reversed() where dayIndex != selectedDay {
            let range = layout.dayRanges[dayIndex]
            let x = (range.lowerBound + range.upperBound) / 2 + offset
            if x < -60 { break }
            guard x < width + 60 else { continue }
            add(Self.dayLabel(timeline.days[dayIndex].day), at: x, id: dayIndex)
        }
        return labels
    }

    private func detailRange(width: CGFloat) -> ClosedRange<Int> {
        let reach = Int(width / 2 / Self.detailSpacing) + 1
        return max(0, selectedIndex - reach) ... min(versions.count, selectedIndex + reach)
    }

    private func detailTicks(center: CGFloat, width: CGFloat) -> [Tick] {
        detailRange(width: width).map { index in
            let x = center + CGFloat(index - selectedIndex) * Self.detailSpacing
            let tone: Tick.Tone = index == selectedIndex ? .selected
                : (index == versions.count || versions[index].isOverviewStop ? .near : .far)
            return Tick(
                id: index, x: x, height: detailTickHeight(index), tone: tone,
                isDot: index == versions.count
            )
        }
    }

    private func detailLabels(center: CGFloat, width: CGFloat) -> [DayLabel] {
        var labels: [DayLabel] = []
        var previousDay: Date??
        var right = -CGFloat.infinity
        for index in detailRange(width: width) where index < versions.count {
            let day = versions[index].date.map(Calendar.current.startOfDay(for:))
            defer { previousDay = day }
            guard previousDay.map({ $0 != day }) ?? true else { continue }
            let text = Self.dayLabel(day)
            let x = center + CGFloat(index - selectedIndex) * Self.detailSpacing
            let half = CGFloat(text.count) * labelCharacterWidth / 2 + 4
            guard x - half > max(0, right), x + half < width else { continue }
            labels.append(DayLabel(id: index, text: text, x: x))
            right = x + half
        }
        return labels
    }

    private func hoverLabel(
        at x: CGFloat, layout: NoteHistoryTimeline.Layout, offset: CGFloat
    ) -> some View {
        let item = layout.item(nearest: x - offset)
        let itemX = layout.x(of: item) + offset
        return Text(hoverText(for: item))
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.regularMaterial, in: .capsule)
            .fixedSize()
            .position(x: itemX, y: 6)
            .allowsHitTesting(false)
    }

    // MARK: Caption

    private var caption: some View {
        VStack(spacing: 2) {
            Text(captionTitle)
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
            Group {
                if let detail = captionDetail { Text(detail) }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .frame(height: 32)
        .accessibilityHidden(true)
    }

    private var captionTitle: String {
        guard versions.indices.contains(selectedIndex) else {
            return String(localized: "Now")
        }
        return Self.timeLabel(versions[selectedIndex].date, seconds: showsSingleState)
    }

    private var captionDetail: String? {
        guard versions.indices.contains(selectedIndex) else { return nil }
        let version = versions[selectedIndex]
        let versionSize = Self.sizeLabel(
            added: version.addedCharacters, removed: version.removedCharacters
        )
        if showsDetail { return String(localized: "Every change · \(versionSize)") }
        if showsSingleState { return versionSize }
        guard case let .session(session) = selectedItem else { return nil }
        let day = timeline.days[timeline.dayIndex(ofSession: session)]
        let position = session - day.sessions.lowerBound + 1
        let size = timeline.sessions[session]
        return String(localized: "\(position) of \(day.sessions.count) that day · \(Self.sizeLabel(added: size.addedCharacters, removed: size.removedCharacters))")
    }

    /// The caption, then what the preview's margin shows.
    private var accessibilityValue: String {
        guard versions.indices.contains(selectedIndex) else {
            return String(localized: "Current version")
        }
        var parts = [captionTitle]
        if let captionDetail { parts.append(captionDetail) }
        if !changes.changed.isEmpty {
            parts.append(String(localized: "Changed places: \(changes.changed.count)"))
        }
        if !changes.removed.isEmpty {
            parts.append(String(localized: "Removed places: \(changes.removed.count)"))
        }
        return parts.joined(separator: ", ")
    }

    private func hoverText(for item: NoteHistoryTimeline.Item) -> String {
        guard case let .session(index) = item else { return String(localized: "Now") }
        let session = timeline.sessions[index]
        let date = versions[session.last].date
        let time = date?.formatted(date: .omitted, time: .shortened)
            ?? String(localized: "Date unavailable")
        return "\(time) · \(Self.sizeLabel(added: session.addedCharacters, removed: session.removedCharacters))"
    }

    static func dayLabel(_ day: Date?) -> String {
        guard let day else { return String(localized: "Date unavailable") }
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        if let days = calendar.dateComponents([.day], from: day, to: .now).day, days < 6 {
            return day.formatted(.dateTime.weekday(.abbreviated))
        }
        if calendar.isDate(day, equalTo: .now, toGranularity: .year) {
            return day.formatted(.dateTime.day().month(.abbreviated))
        }
        return day.formatted(.dateTime.day().month(.abbreviated).year())
    }

    static func timeLabel(_ date: Date?, seconds: Bool) -> String {
        guard let date else { return String(localized: "Date unavailable") }
        let time = seconds
            ? date.formatted(.dateTime.hour().minute().second())
            : date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) || calendar.isDateInYesterday(date) {
            return "\(dayLabel(calendar.startOfDay(for: date))) · \(time)"
        }
        var day = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated)
        if !calendar.isDate(date, equalTo: .now, toGranularity: .year) { day = day.year() }
        return "\(date.formatted(day)) · \(time)"
    }

    static func sizeLabel(added: Int, removed: Int) -> String {
        switch (added, removed) {
        case (0, 0): String(localized: "no text changes")
        case (_, 0): "+\(added.formatted())"
        case (0, _): "−\(removed.formatted())"
        default: "+\(added.formatted()) −\(removed.formatted())"
        }
    }

    // MARK: Input

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                var state = drag ?? Drag()
                let lifted = value.location.y < -Self.detailLift
                if lifted != state.isLifted {
                    state.isLifted = lifted
                    state.consumed = value.translation.width
                    if lifted { tip.invalidate(reason: .actionPerformed) }
                }
                if abs(value.translation.width) > 3 || abs(value.translation.height) > 3 {
                    state.hasMoved = true
                }
                // Finger to the right brings older versions to the center.
                var delta = value.translation.width - state.consumed
                let detailed = isDetailed || state.isLifted
                var position = position(detailed: detailed)
                let start = position
                while true {
                    if delta > 0, let spacing = spacing(from: position, by: -1, detailed: detailed),
                       delta >= spacing {
                        position -= 1
                        delta -= spacing
                        state.consumed += spacing
                    } else if delta < 0, let spacing = spacing(from: position, by: 1, detailed: detailed),
                              -delta >= spacing {
                        position += 1
                        delta += spacing
                        state.consumed -= spacing
                    } else {
                        break
                    }
                }
                state.residual = max(-Self.detailSpacing, min(Self.detailSpacing, delta))
                drag = state
                if position != start { select(position: position, detailed: detailed) }
            }
            .onEnded { value in
                // Arrow keys follow the rail again after reading the text.
                isFocused = true
                let state = drag ?? Drag()
                if !state.hasMoved { tap(at: value.location.x, width: width) }
                withAnimation(reduceMotion ? nil : .spring(duration: 0.25)) { drag = nil }
            }
    }

    private func tap(at x: CGFloat, width: CGFloat) {
        let center = width / 2
        if showsDetail {
            let index = selectedIndex + Int(((x - center) / Self.detailSpacing).rounded())
            select(position: min(max(index, 0), versions.count), detailed: true)
            return
        }
        let item = selectedItem
        let layout = timeline.layout(spreading: timeline.day(of: item), metrics: metrics)
        let target = layout.item(nearest: x - (center - layout.x(of: item)))
        select(position: overviewPosition(of: target), detailed: false)
    }

    private func step(by offset: Int, detailed: Bool) {
        let position = position(detailed: detailed)
        let limit = detailed ? versions.count : timeline.sessions.count
        let target = min(max(position + offset, 0), limit)
        if target != position { select(position: target, detailed: detailed) }
    }

    /// Overview positions count sessions, then the current text; detail
    /// positions count every saved state.
    private func position(detailed: Bool) -> Int {
        detailed ? selectedIndex : overviewPosition(of: selectedItem)
    }

    private func overviewPosition(of item: NoteHistoryTimeline.Item) -> Int {
        if case let .session(index) = item { return index }
        return timeline.sessions.count
    }

    private func spacing(from position: Int, by offset: Int, detailed: Bool) -> CGFloat? {
        let target = position + offset
        if detailed {
            return (0...versions.count).contains(target) ? Self.detailSpacing : nil
        }
        guard (0...timeline.sessions.count).contains(target) else { return nil }
        let distance = timeline.distance(
            afterSession: min(position, target),
            spreading: timeline.day(of: item(at: position)), metrics: metrics
        )
        return max(Self.minimumStep, distance)
    }

    private func item(at position: Int) -> NoteHistoryTimeline.Item {
        position >= timeline.sessions.count ? .current : .session(position)
    }

    private func select(position: Int, detailed: Bool) {
        let index = detailed ? position : timeline.versionIndex(of: item(at: position))
        select(index, base(of: index, detailed: detailed))
    }

    /// Sessions compare with the session before; single states with the
    /// state before.
    private func base(of index: Int, detailed: Bool) -> Int? {
        if !detailed, timeline.isSessionEnd(index),
           case let .session(session) = timeline.item(containing: index) {
            return timeline.baseVersionIndex(ofSession: session)
        }
        return index > 0 ? index - 1 : nil
    }

    private func firstSession(atOrAfter x: CGFloat, in layout: NoteHistoryTimeline.Layout) -> Int {
        var low = 0
        var high = layout.sessionX.count
        while low < high {
            let middle = (low + high) / 2
            if layout.sessionX[middle] < x { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private func itemTickHeight(_ item: NoteHistoryTimeline.Item) -> CGFloat {
        guard case let .session(index) = item else { return 7 }
        return NoteHistoryTimeline.tickHeight(for: timeline.sessions[index].size)
    }

    private func detailTickHeight(_ index: Int) -> CGFloat {
        guard versions.indices.contains(index) else { return 7 }
        let version = versions[index]
        return NoteHistoryTimeline.tickHeight(
            for: version.addedCharacters + version.removedCharacters, minimum: 4, maximum: 16
        )
    }

    /// ⌘+ and ⌘− zoom the timeline, like other timelines on the Mac.
    private var zoomShortcuts: some View {
        Group {
            Button("Show Every Change") { isDetailed = true }
                .keyboardShortcut("+", modifiers: .command)
            Button("Show Every Change") { isDetailed = true }
                .keyboardShortcut("=", modifiers: .command)
            Button("Show Edit Sessions") { isDetailed = false }
                .keyboardShortcut("-", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
