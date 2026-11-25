import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Speaker Mode's island: a small stopwatch dial and the time. Tapping it
/// shows Reset, the talk length and Start or Pause in a popover. It starts
/// in the note's toolbar and can be dragged out anywhere in the window and
/// back.
struct SpeakerIsland: View {
    let timer: SpeakerTimer
    let placement: SpeakerIslandPlacement
    /// Floating rather than in the toolbar.
    var isFloating = false
    @State private var showsControls = false
    @State private var anchor = SpeakerWindowAnchor()
    @GestureState private var isDragging = false

    var body: some View {
        TimelineView(.periodic(from: timer.startedAt ?? .now, by: 1)) { context in
            SpeakerIslandContent(
                timer: timer, reading: timer.reading(at: context.date),
                showsControls: $showsControls,
                move: !isFloating ? (Text("Move Over Note"), { placement.spot = .topTrailing })
                    : placement.canDock ? (Text("Move to Toolbar"), { placement.spot = nil })
                    : nil
            )
        }
        .background(SpeakerAnchorView(anchor: anchor))
        .highPriorityGesture(DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .updating($isDragging) { _, dragging, _ in dragging = true }
            .onChanged { value in
                if placement.dragCenter == nil {
                    showsControls = false
                    placement.dragStart = anchor.frame.map { CGPoint(x: $0.midX, y: $0.midY) }
                        ?? value.startLocation
                }
                placement.dragCenter = CGPoint(x: placement.dragStart.x + value.translation.width,
                                               y: placement.dragStart.y + value.translation.height)
            }
            .onEnded { _ in
                withAnimation(.snappy(duration: 0.25)) { placement.drop() }
            })
        // A drag the system cancels never ends; drop the island where it was.
        .onChange(of: isDragging) { _, dragging in
            if !dragging { withAnimation(.snappy(duration: 0.25)) { placement.drop() } }
        }
        .onDisappear { placement.drop() }
        // Dragged from the toolbar, its floating copy follows the
        // pointer while this one keeps the drag going.
        .opacity(!isFloating && placement.dragCenter != nil ? 0 : 1)
    }
}

#if os(macOS)
/// The island in the Mac toolbar. Its top half reaches into the title bar,
/// where dragging would move the window instead of the island, so it gets
/// a host view that keeps the window still.
struct SpeakerToolbarIsland: NSViewRepresentable {
    let timer: SpeakerTimer
    let placement: SpeakerIslandPlacement

    struct Root: View {
        let timer: SpeakerTimer
        let placement: SpeakerIslandPlacement

        var body: some View {
            SpeakerIsland(timer: timer, placement: placement).mehAppearance()
        }
    }

    final class HostingView: NSHostingView<Root> {
        override var mouseDownCanMoveWindow: Bool { false }
    }

    func makeNSView(context: Context) -> HostingView {
        HostingView(rootView: Root(timer: timer, placement: placement))
    }

    func updateNSView(_ view: HostingView, context: Context) {
        view.rootView = Root(timer: timer, placement: placement)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: HostingView,
                      context: Context) -> CGSize? {
        nsView.fittingSize
    }
}
#endif

/// Where Speaker Mode's island sits in a window: in the toolbar, or
/// floating wherever it was dropped.
@Observable
final class SpeakerIslandPlacement {
    /// The floating island's centre, from top leading (0, 0) to bottom
    /// trailing (1, 1) of where it fits. Nil keeps it in the toolbar.
    var spot: UnitPoint?
    /// The island's centre in the window while it's dragged.
    var dragCenter: CGPoint?
    /// Whether the note's toolbar is there to take the island back.
    var canDock = false
    @ObservationIgnored var dragStart = CGPoint.zero
    /// The window's content below the toolbar, where the island floats.
    @ObservationIgnored let area = SpeakerWindowAnchor()
    var areaSize = CGSize.zero
    var islandSize = CGSize.zero

    /// Dropped near one of these, the island clicks into place.
    static let snapSpots: [UnitPoint] = [
        .topLeading, .top, .topTrailing, .bottomLeading, .bottom, .bottomTrailing,
    ]
    #if os(macOS)
    static let snapDistance: CGFloat = 28
    static let margin: CGFloat = 12
    #else
    static let snapDistance: CGFloat = 40
    static let margin: CGFloat = 16
    #endif

    /// Where the island's centre can go, in the area's space.
    var range: CGRect {
        let inset = CGSize(width: Self.margin + islandSize.width / 2,
                           height: Self.margin + islandSize.height / 2)
        return CGRect(x: inset.width, y: inset.height,
                      width: max(areaSize.width - inset.width * 2, 0),
                      height: max(areaSize.height - inset.height * 2, 0))
    }

    func point(for spot: UnitPoint) -> CGPoint {
        CGPoint(x: range.minX + range.width * spot.x, y: range.minY + range.height * spot.y)
    }

    /// The dragged island's centre in the area's space.
    var dragPoint: CGPoint? {
        guard let dragCenter, let frame = area.frame else { return nil }
        return CGPoint(x: dragCenter.x - frame.minX, y: dragCenter.y - frame.minY)
    }

    /// Where the island is shown: under the pointer, clicked into a snap spot
    /// it's near, or where it was dropped.
    var shownPoint: CGPoint? {
        guard let dragPoint else { return spot.map(point(for:)) }
        return snapSpot(near: dragPoint).map(point(for:)) ?? dragPoint
    }

    func drop() {
        defer { dragCenter = nil }
        guard let dragPoint else { return }
        // Reaching up into the toolbar docks it again, wherever it was
        // grabbed.
        guard !canDock || dragPoint.y - islandSize.height / 2 >= 0 else {
            spot = nil
            return
        }
        spot = snapSpot(near: dragPoint) ?? UnitPoint(
            x: range.width > 0 ? min(max((dragPoint.x - range.minX) / range.width, 0), 1) : 0.5,
            y: range.height > 0 ? min(max((dragPoint.y - range.minY) / range.height, 0), 1) : 0
        )
    }

    private func snapSpot(near point: CGPoint) -> UnitPoint? {
        Self.snapSpots.first { spot in
            let snap = self.point(for: spot)
            return hypot(snap.x - point.x, snap.y - point.y) < Self.snapDistance
        }
    }
}

/// The island once it's out of the toolbar: it stays wherever it was
/// dropped in the window, with a × that turns Speaker Mode off.
struct SpeakerFloatingIsland: View {
    let timer: SpeakerTimer
    let placement: SpeakerIslandPlacement
    /// Whether the note's toolbar is showing, to dock the island in.
    let canDock: Bool
    let onClose: () -> Void

    var body: some View {
        Color.clear
            .background(SpeakerAnchorView(anchor: placement.area))
            .onGeometryChange(for: CGSize.self, of: \.size) { placement.areaSize = $0 }
            .onChange(of: canDock, initial: true) { placement.canDock = canDock }
            .overlay {
                if let point = placement.shownPoint {
                    // The × sits just off the island's corner: where it overlaps
                    // the glass, taps fall through to the note.
                    SpeakerIsland(timer: timer, placement: placement, isFloating: true)
                        .padding(SpeakerMetrics.closeSize * 0.75)
                        .overlay(alignment: .topLeading) {
                            if placement.dragCenter == nil { closeButton }
                        }
                        .onGeometryChange(for: CGSize.self, of: \.size) {
                            placement.islandSize = $0
                        }
                        .position(point)
                }
            }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: SpeakerMetrics.closeSize * 0.45, weight: .bold))
                .frame(width: SpeakerMetrics.closeSize, height: SpeakerMetrics.closeSize)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(Text("Turn Off Speaker Mode"))
        .accessibilityIdentifier("speaker-close")
    }
}

/// Finds a view's frame in its window, from the top left, so the toolbar
/// and the floating island can share one space.
final class SpeakerWindowAnchor {
    #if os(iOS)
    weak var view: UIView?
    #else
    weak var view: NSView?
    #endif

    var frame: CGRect? {
        #if os(iOS)
        guard let view, view.window != nil else { return nil }
        return view.convert(view.bounds, to: nil)
        #else
        guard let view, let content = view.window?.contentView else { return nil }
        var frame = view.convert(view.bounds, to: content)
        if !content.isFlipped { frame.origin.y = content.bounds.height - frame.maxY }
        return frame
        #endif
    }
}

#if os(iOS)
private struct SpeakerAnchorView: UIViewRepresentable {
    let anchor: SpeakerWindowAnchor

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        anchor.view = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        anchor.view = view
    }
}
#else
private struct SpeakerAnchorView: NSViewRepresentable {
    let anchor: SpeakerWindowAnchor

    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        anchor.view = view
    }
}
#endif

private enum SpeakerMetrics {
    #if os(macOS)
    static let islandHeight: CGFloat = 30
    static let controlSize: CGFloat = 32
    static let dialSize = CGSize(width: 19, height: 22)
    static let font = Font.system(size: 13, weight: .semibold).monospacedDigit()
    static let cardWidth: CGFloat = 240
    static let sliderFont = Font.system(size: 12, weight: .semibold).monospacedDigit()
    static let sliderIconFont = Font.system(size: 13, weight: .semibold)
    static let closeSize: CGFloat = 18
    /// Opens the controls below the island, unless there's no room. The Mac
    /// default is above.
    static let popoverEdge = Edge.bottom
    #else
    static let islandHeight: CGFloat = 44
    static let controlSize: CGFloat = 44
    static let dialSize = CGSize(width: 24, height: 27)
    static let font = Font.body.weight(.semibold).monospacedDigit()
    static let cardWidth: CGFloat = 300
    static let sliderFont = Font.subheadline.weight(.semibold).monospacedDigit()
    static let sliderIconFont = Font.body.weight(.semibold)
    static let closeSize: CGFloat = 24
    /// iOS already opens them below; `.bottom` would cover the island.
    static let popoverEdge = Edge.top
    #endif
}

private struct SpeakerIslandContent: View {
    let timer: SpeakerTimer
    let reading: SpeakerTimerReading
    @Binding var showsControls: Bool
    /// Moves the island in or out of the toolbar without dragging.
    let move: (title: Text, action: () -> Void)?
    @State private var pulse = false
    @Environment(\.mehPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let style = SpeakerIslandStyle(phase: reading.phase, palette: palette)
        Button {
            showsControls.toggle()
        } label: {
            HStack(spacing: 7) {
                SpeakerDial(reading: reading, style: style)
                    .frame(width: SpeakerMetrics.dialSize.width,
                           height: SpeakerMetrics.dialSize.height)
                // Sized for over time's "+", so the island doesn't grow
                // at zero.
                ZStack(alignment: .leading) {
                    Text(verbatim: "+00:00").hidden()
                    Text(verbatim: reading.text)
                        .modifier(SpeakerPausedBlink(isPaused: reading.isPaused))
                }
                .font(SpeakerMetrics.font)
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .frame(minHeight: SpeakerMetrics.islandHeight)
            .contentShape(.capsule)
            // Set on the label, or the Mac toolbar tints the time blue.
            .foregroundStyle(style.foreground)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.accessibilityLabel(reading))
        .accessibilityHint(showsControls ? "Hides the timer controls."
                                         : "Shows the timer controls.")
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityActions {
            if let move {
                Button { withAnimation(.snappy) { move.action() } } label: { move.title }
            }
        }
        .accessibilityIdentifier("speaker-island")
        .glassEffect(style.glass, in: .capsule)
        .scaleEffect(pulse ? 1.1 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: reading.phase)
        .popover(isPresented: $showsControls, arrowEdge: SpeakerMetrics.popoverEdge) {
            // Once the talk starts, the island alone keeps the note clear.
            SpeakerControlCard(timer: timer, onStart: { showsControls = false })
                .presentationCompactAdaptation(.popover)
        }
        .onChange(of: reading.phase) { _, phase in
            if phase == .timeUp { playPulse() }
        }
        #if os(iOS)
        .sensoryFeedback(.warning, trigger: reading.phase) { _, phase in phase == .timeUp }
        #endif
    }

    /// Two soft beats when the countdown reaches zero.
    private func playPulse() {
        guard !reduceMotion else { return }
        Task {
            for _ in 0..<2 {
                withAnimation(.easeOut(duration: 0.22)) { pulse = true }
                try? await Task.sleep(for: .milliseconds(240))
                withAnimation(.easeIn(duration: 0.3)) { pulse = false }
                try? await Task.sleep(for: .milliseconds(340))
            }
        }
    }

    static func accessibilityLabel(_ reading: SpeakerTimerReading) -> String {
        let time = Duration.seconds(reading.seconds)
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
        let label = if !reading.isCountdown {
            String(localized: "Speaker timer, \(time)")
        } else {
            switch reading.phase {
            case .normal, .lastMinutes: String(localized: "Speaker timer, \(time) left")
            case .timeUp: String(localized: "Speaker timer, time’s up")
            case .overTime: String(localized: "Speaker timer, \(time) over time")
            }
        }
        return reading.isPaused ? String(localized: "\(label), paused") : label
    }
}

/// The island's colors for each phase of a talk. Over time inverts to ink
/// so it's hard to miss without turning red.
struct SpeakerIslandStyle {
    let glass: Glass
    let foreground: Color
    /// The face of the small dial.
    let dialFace: Color
    let highlighter: Color
    /// Behind the length chip and Reset.
    let quietFill: Color
    /// Behind Start and Pause, with `onPrimary` glyphs.
    let primaryFill: Color
    let onPrimary: Color

    init(phase: SpeakerTimerReading.Phase, palette: MehPalette) {
        highlighter = palette.highlighterColor
        switch phase {
        case .normal:
            glass = .regular.interactive()
            foreground = palette.inkColor
            dialFace = MehStyle.paperColor
            onPrimary = palette.onInkColor
        case .lastMinutes:
            glass = .regular.tint(palette.highlighterColor.opacity(0.4)).interactive()
            foreground = palette.inkColor
            dialFace = MehStyle.paperColor
            onPrimary = palette.onInkColor
        case .timeUp:
            glass = .regular.tint(palette.highlighterColor).interactive()
            foreground = MehStyle.onHighlighterColor
            dialFace = MehStyle.paperColor
            onPrimary = palette.highlighterColor
        case .overTime:
            glass = .regular.tint(palette.inkColor).interactive()
            foreground = palette.onInkColor
            dialFace = palette.inkColor
            onPrimary = palette.inkColor
        }
        quietFill = foreground.opacity(0.1)
        primaryFill = foreground
    }
}

/// A small mechanical stopwatch: a crown on top and a face that fills with
/// highlighter. In over time a hand sweeps the seconds instead.
struct SpeakerDial: View {
    let reading: SpeakerTimerReading
    let style: SpeakerIslandStyle

    var body: some View {
        Canvas { context, size in
            let line = max(1.2, size.width / 16)
            let radius = size.width / 2 - line / 2
            let center = CGPoint(x: size.width / 2, y: size.height - size.width / 2)
            let crown = CGRect(x: center.x - size.width * 0.09, y: 0,
                               width: size.width * 0.18, height: size.height - size.width + line)
            context.fill(Path(roundedRect: crown, cornerRadius: 1), with: .foreground)
            let face = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                              width: radius * 2, height: radius * 2))
            context.fill(face, with: .color(style.dialFace))
            if reading.dialFraction > 0 {
                context.fill(Self.sector(center: center, radius: radius - line * 0.9,
                                         fraction: reading.dialFraction),
                             with: .color(style.highlighter))
            }
            context.stroke(face, with: .foreground, lineWidth: line)
            var ticks = Path()
            for quarter in 0..<4 {
                let angle = Double(quarter) * .pi / 2
                ticks.move(to: Self.point(center, radius - line * 1.1, angle))
                ticks.addLine(to: Self.point(center, radius - line * 2.3, angle))
            }
            context.stroke(ticks, with: .foreground, style: StrokeStyle(lineWidth: line * 0.8,
                                                                        lineCap: .round))
            if reading.phase == .overTime {
                var hand = Path()
                let angle = Double(reading.seconds % 60) / 60 * 2 * .pi
                hand.move(to: center)
                hand.addLine(to: Self.point(center, radius * 0.72, angle))
                context.stroke(hand, with: .foreground,
                               style: StrokeStyle(lineWidth: line, lineCap: .round))
            }
            let dot = line * 1.1
            context.fill(Path(ellipseIn: CGRect(x: center.x - dot, y: center.y - dot,
                                                width: dot * 2, height: dot * 2)),
                         with: .foreground)
        }
        .accessibilityHidden(true)
    }

    /// A point on the dial, clockwise from twelve.
    static func point(_ center: CGPoint, _ radius: CGFloat, _ angle: Double) -> CGPoint {
        CGPoint(x: center.x + radius * sin(angle), y: center.y - radius * cos(angle))
    }

    static func sector(center: CGPoint, radius: CGFloat, fraction: Double) -> Path {
        if fraction >= 0.999 {
            return Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                          width: radius * 2, height: radius * 2))
        }
        var path = Path()
        path.move(to: center)
        path.addArc(center: center, radius: radius, startAngle: .degrees(-90),
                    endAngle: .degrees(-90 + 360 * fraction), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// A paused time slowly fades in and out. With Reduce Motion it stays
/// dimmed instead.
private struct SpeakerPausedBlink: ViewModifier {
    let isPaused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if !isPaused {
            content
        } else if reduceMotion {
            content.opacity(0.45)
        } else {
            content.phaseAnimator([1.0, 0.4]) { view, opacity in
                view.opacity(opacity)
            } animation: { _ in .easeInOut(duration: 1.2) }
        }
    }
}

private struct SpeakerStartPauseButton: View {
    let timer: SpeakerTimer
    let style: SpeakerIslandStyle
    let size: CGFloat
    let onStart: () -> Void

    var body: some View {
        Button {
            let starts = !timer.isRunning
            timer.toggle(at: .now)
            if starts { onStart() }
        } label: {
            Image(systemName: timer.isRunning ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(style.onPrimary)
                .frame(width: size, height: size)
                .background(style.primaryFill, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(timer.isRunning ? Text("Pause") : Text("Start"))
        .accessibilityIdentifier("speaker-start-pause")
    }
}

private struct SpeakerResetButton: View {
    let timer: SpeakerTimer
    let style: SpeakerIslandStyle
    let size: CGFloat

    var body: some View {
        Button {
            timer.reset()
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: size * 0.4, weight: .semibold))
                .frame(width: size, height: size)
                .background(style.quietFill, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(!timer.hasStarted)
        .opacity(timer.hasStarted ? 1 : 0.4)
        .accessibilityLabel(Text("Reset"))
        .accessibilityIdentifier("speaker-reset")
    }
}

/// The popover: Reset, the talk length and Start in one row.
private struct SpeakerControlCard: View {
    let timer: SpeakerTimer
    let onStart: () -> Void
    @Environment(\.mehPalette) private var palette

    var body: some View {
        let style = SpeakerIslandStyle(phase: .normal, palette: palette)
        HStack(spacing: 10) {
            SpeakerResetButton(timer: timer, style: style, size: SpeakerMetrics.controlSize)
            SpeakerLengthSlider(timer: timer, style: style, height: SpeakerMetrics.controlSize)
            SpeakerStartPauseButton(timer: timer, style: style, size: SpeakerMetrics.controlSize,
                                    onStart: onStart)
        }
        .foregroundStyle(style.foreground)
        .padding(12)
        .frame(width: SpeakerMetrics.cardWidth)
    }
}

/// The talk length as a pill, like the sliders in Control Center. Its left
/// end is the stopwatch; the rest counts down from 5 to 60 minutes, with a
/// timer glyph. Dragging snaps to 5 minutes; scrolling, or dragging with
/// the finger moved off the pill, fine-tunes by one. The
/// length is locked once the timer has started, until it's reset.
private struct SpeakerLengthSlider: View {
    let timer: SpeakerTimer
    let style: SpeakerIslandStyle
    let height: CGFloat
    @AppStorage(SpeakerTimer.lengthKey, store: NotebookEditorPreferences.store)
    private var storedLength = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where a fine drag began: the finger's x and the length then.
    @State private var fineStart: (x: CGFloat, minutes: Int)?

    private static let steps = SpeakerTimer.lengthRange.upperBound / SpeakerTimer.lengthStep
    /// How far above or below the pill a drag turns fine, like scrubbing in
    /// Music.
    private static let fineDistance: CGFloat = 30
    private static let finePointsPerMinute: CGFloat = 8

    static func title(_ minutes: Int?) -> Text {
        if let minutes { Text("\(minutes) min") } else { Text("Stopwatch") }
    }

    /// 0 is the stopwatch.
    private var minutes: Int { timer.lengthMinutes ?? 0 }
    private var lengthFraction: CGFloat {
        CGFloat(minutes) / CGFloat(SpeakerTimer.lengthRange.upperBound)
    }
    private var isLocked: Bool { timer.hasStarted }

    var body: some View {
        GeometryReader { proxy in
            let track = max(proxy.size.width - height, 1)
            ZStack(alignment: .leading) {
                // Locked, the pill dims but its length stays easy to read.
                ZStack(alignment: .leading) {
                    Capsule().fill(style.quietFill)
                    Capsule().fill(style.foreground.opacity(0.14))
                        .frame(width: height + track * lengthFraction)
                    Image(systemName: minutes == 0 ? "stopwatch" : "timer")
                        .font(SpeakerMetrics.sliderIconFont)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: height, height: height)
                }
                .opacity(isLocked ? 0.45 : 1)
                Self.title(timer.lengthMinutes)
                    .font(SpeakerMetrics.sliderFont)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .contentTransition(.numericText())
                    // Mirrors the glyph's inset from the left end, and never
                    // runs under it.
                    .padding(.leading, height)
                    .padding(.trailing, height * 0.28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
            .contentShape(.capsule)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard !isLocked else { return }
                    let location = value.location
                    if max(-location.y, location.y - height) > Self.fineDistance {
                        let start = fineStart ?? (location.x, minutes)
                        fineStart = start
                        let steps = (location.x - start.x) / Self.finePointsPerMinute
                        set(from: start.minutes, by: Int(steps.rounded(.towardZero)))
                    } else {
                        fineStart = nil
                        let step = ((location.x - height / 2) / track * CGFloat(Self.steps))
                            .rounded()
                        set(minutes: Int(step) * SpeakerTimer.lengthStep)
                    }
                }
                .onEnded { _ in fineStart = nil })
        }
        .frame(height: height)
        .animation(reduceMotion ? nil : .snappy(duration: 0.15), value: minutes)
        #if os(iOS)
        .sensoryFeedback(.selection, trigger: timer.lengthMinutes)
        #endif
        .accessibilityElement()
        .accessibilityLabel(Text("Talk Length"))
        .accessibilityValue(Self.title(timer.lengthMinutes))
        .accessibilityHint(isLocked ? Text("Reset the timer to change the length.") : Text(""))
        .accessibilityRespondsToUserInteraction(!isLocked)
        .accessibilityAdjustableAction { direction in
            guard !isLocked else { return }
            switch direction {
            case .increment: set(from: minutes, by: 1)
            case .decrement: set(from: minutes, by: -1)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("speaker-length")
        .modifier(SpeakerScrollSteps { steps in
            guard !isLocked else { return }
            set(from: minutes, by: steps)
        })
    }

    /// Steps a minute at a time. Up from the stopwatch starts at the
    /// shortest length; below that goes back to the stopwatch.
    private func set(from start: Int, by steps: Int) {
        let lower = SpeakerTimer.lengthRange.lowerBound
        let target = (start == 0 ? lower - 1 : start) + steps
        set(minutes: target < lower ? 0 : target)
    }

    /// 0 or less is the stopwatch.
    private func set(minutes: Int) {
        let minutes = minutes <= 0 ? nil : min(minutes, SpeakerTimer.lengthRange.upperBound)
        guard minutes != timer.lengthMinutes else { return }
        timer.setLength(minutes)
        storedLength = minutes ?? 0
    }
}

/// Scrolling over the pill steps the length a minute at a time: right or up
/// for longer, with a trackpad or a mouse wheel.
private struct SpeakerScrollSteps: ViewModifier {
    let onStep: (Int) -> Void
    /// How far a trackpad scrolls for one step. A mouse wheel steps once per
    /// notch.
    static let stepDistance: CGFloat = 12

    func body(content: Content) -> some View {
        #if os(iOS)
        content.gesture(Recognizer(onStep: onStep))
        #else
        content.background(Monitor(onStep: onStep))
        #endif
    }

    #if os(iOS)
    private struct Recognizer: UIGestureRecognizerRepresentable {
        let onStep: (Int) -> Void

        final class Coordinator {
            var consumed: CGFloat = 0
        }

        func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

        func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
            let pan = UIPanGestureRecognizer()
            pan.allowedScrollTypesMask = .all
            // Touches drag the pill; this only hears pointer scrolling.
            pan.allowedTouchTypes = []
            return pan
        }

        func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
            if pan.state == .began { context.coordinator.consumed = 0 }
            let translation = pan.translation(in: pan.view)
            let distance = translation.x - translation.y - context.coordinator.consumed
            let steps = Int((distance / SpeakerScrollSteps.stepDistance).rounded(.towardZero))
            guard steps != 0 else { return }
            context.coordinator.consumed += CGFloat(steps) * SpeakerScrollSteps.stepDistance
            onStep(steps)
        }
    }
    #else
    private struct Monitor: NSViewRepresentable {
        let onStep: (Int) -> Void

        func makeNSView(context: Context) -> MonitorView {
            let view = MonitorView()
            view.onStep = onStep
            return view
        }

        func updateNSView(_ view: MonitorView, context: Context) {
            view.onStep = onStep
        }

        final class MonitorView: NSView {
            var onStep: (Int) -> Void = { _ in }
            private var monitor: Any?
            private var pending: CGFloat = 0

            override func hitTest(_ point: NSPoint) -> NSView? { nil }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
                guard window != nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    guard let self, let window = self.window, event.window === window,
                          self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                    else { return event }
                    self.scroll(event)
                    return nil
                }
            }

            private func scroll(_ event: NSEvent) {
                // In the direction the fingers or the wheel moved, whatever
                // the natural scrolling setting.
                let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
                let distance = sign * (event.scrollingDeltaX - event.scrollingDeltaY)
                guard event.hasPreciseScrollingDeltas else {
                    if distance != 0 { onStep(distance > 0 ? 1 : -1) }
                    return
                }
                if event.phase == .began { pending = 0 }
                // Momentum would overshoot; the length stops with the fingers.
                guard event.momentumPhase.isEmpty else { return }
                pending += distance
                let steps = Int((pending / SpeakerScrollSteps.stepDistance).rounded(.towardZero))
                guard steps != 0 else { return }
                pending -= CGFloat(steps) * SpeakerScrollSteps.stepDistance
                onStep(steps)
            }
        }
    }
    #endif
}

/// Keeps the screen on from the first Start until the timer is reset or
/// Speaker Mode is turned off, so the display doesn't dim mid-talk. A
/// docked island hidden with its note lets the screen sleep meanwhile.
struct SpeakerKeepsScreenAwake: ViewModifier {
    let scene: NotebookSceneState
    @AppStorage(SpeakerTimer.enabledKey, store: NotebookEditorPreferences.store)
    private var isAvailable = false

    func body(content: Content) -> some View {
        content
            .onChange(of: isAvailable && scene.speakerTimer?.hasStarted == true
                      && (scene.speakerIsland.spot != nil || scene.speakerIsland.canDock),
                      initial: true) { _, awake in
                SpeakerScreenAwake.set(ObjectIdentifier(scene), awake: awake)
            }
            .onChange(of: isAvailable) { _, available in
                if !available { scene.speakerTimer = nil }
            }
            .onDisappear {
                SpeakerScreenAwake.set(ObjectIdentifier(scene), awake: false)
            }
    }
}

/// Every window with a started timer holds the screen awake; the last one
/// to let go lets it sleep again.
@MainActor
private enum SpeakerScreenAwake {
    private static var holders = Set<ObjectIdentifier>()
    #if os(macOS)
    private static var activity: NSObjectProtocol?
    #endif

    static func set(_ holder: ObjectIdentifier, awake: Bool) {
        if awake { holders.insert(holder) } else { holders.remove(holder) }
        let keepsAwake = !holders.isEmpty
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = keepsAwake
        #else
        if keepsAwake, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .idleDisplaySleepDisabled, reason: "Speaker Mode timer is running"
            )
        } else if !keepsAwake, let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
        #endif
    }
}
