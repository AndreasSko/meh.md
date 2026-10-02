#if os(macOS)
import AppKit
import NoteCore
import ObjectiveC
import SwiftUI

/// Resolves the compact rows and footer as one surface, even in a native List.
struct NotebookMacRecentsAnchorKey: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] { [] }

    static func reduce(value: inout [Anchor<CGRect>],
                       nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

struct NotebookMacRecentsCompactHeader: View {
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack {
                Text("Recents").font(.headline)
                Spacer()
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(NotebookMacOverlayScrollbar())
        .accessibilityIdentifier("notebook-recents-toggle")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}

private struct NotebookMacRecentsCompactGeometry: Equatable {
    let frame: CGRect
    let viewportWidth: CGFloat
}

struct NotebookMacRecentsExpansionHost<Browser: View, Row: View>: View {
    let items: [NotebookPlacement]
    let selectedNoteID: UUID?
    @Binding var isExpanded: Bool
    let onSelect: (UUID) -> Void
    let onCollapse: () -> Void
    let onVisibleIDs: ([UUID]) -> Void
    @ViewBuilder let rowContent: (NotebookPlacement, Int, Int) -> Row
    @ViewBuilder let browser: () -> Browser
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var compactGeometry: NotebookMacRecentsCompactGeometry?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                browser()
                    // Keep Files mounted, including its native scroll state.
                    .opacity(isExpanded ? 0 : 1)
                    .scrollDisabled(isExpanded)
                    .disabled(isExpanded)
                    .allowsHitTesting(!isExpanded)
                    .accessibilityHidden(isExpanded)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2),
                               value: isExpanded)
            }
            .overlayPreferenceValue(NotebookMacRecentsAnchorKey.self) { anchors in
                ZStack(alignment: .topLeading) {
                    if isExpanded || !anchors.isEmpty {
                        // The menu can open Recents while its compact rows are
                        // outside the native List's mounted viewport.
                        let measuredFrame = anchors.first.map { first in
                            anchors.dropFirst().reduce(geometry[first]) {
                                $0.union(geometry[$1])
                            }
                        } ?? CGRect(x: 8, y: 8,
                                    width: max(0, geometry.size.width - 16),
                                    height: min(330, max(0, geometry.size.height - 16)))
                        let measuredGeometry = NotebookMacRecentsCompactGeometry(
                            frame: measuredFrame, viewportWidth: geometry.size.width
                        )
                        // Disabling Files can remove its scrollbar and widen
                        // the anchors. Preserve the bounds from before opening.
                        let source = isExpanded
                            ? compactGeometry ?? measuredGeometry : measuredGeometry
                        let compactFrame = source.frame
                        // The host already sits below the window toolbar.
                        let minimumTop: CGFloat = 0
                        let bottom = max(minimumTop, geometry.size.height
                                         - geometry.safeAreaInsets.bottom - 8)
                        let top = max(minimumTop, min(compactFrame.minY, bottom - 72))
                        let expandedFrame = CGRect(
                            // Only the bottom edge moves as the card unfolds.
                            x: compactFrame.minX, y: top,
                            width: max(0, compactFrame.width + geometry.size.width
                                       - source.viewportWidth),
                            height: max(0, bottom - top)
                        )
                        let frame = isExpanded ? expandedFrame : compactFrame
                        NotebookMacRecentsSurface(
                            items: items, selectedNoteID: selectedNoteID,
                            isExpanded: isExpanded,
                            onSelect: onSelect, onCollapse: onCollapse,
                            onVisibleIDs: onVisibleIDs, rowContent: rowContent
                        )
                        .frame(width: frame.width, height: frame.height)
                        .background(NotebookSidebarPalette.recents)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .opacity(isExpanded ? 1 : 0)
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Color(nsColor: .separatorColor),
                                              lineWidth: 1)
                        }
                        .offset(x: frame.minX, y: frame.minY)
                        .disabled(!isExpanded)
                        .allowsHitTesting(isExpanded)
                        .accessibilityHidden(!isExpanded)
                        .animation(reduceMotion ? nil : .smooth(duration: 0.3),
                                   value: isExpanded)
                        .onChange(of: measuredGeometry, initial: true) { _, value in
                            if !isExpanded, !anchors.isEmpty {
                                compactGeometry = value
                            }
                        }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height,
                       alignment: .topLeading)
                .clipped()
                .allowsHitTesting(isExpanded)
            }
        }
        .background(NotebookSidebarPalette.background)
        .onChange(of: isExpanded) { _, expanded in
            if !expanded { onVisibleIDs([]) }
        }
        .onChange(of: items.isEmpty) { _, empty in
            if empty { isExpanded = false }
        }
    }
}

private struct NotebookMacRecentsSurface<Row: View>: View {
    let items: [NotebookPlacement]
    let selectedNoteID: UUID?
    let isExpanded: Bool
    let onSelect: (UUID) -> Void
    let onCollapse: () -> Void
    let onVisibleIDs: ([UUID]) -> Void
    @ViewBuilder let rowContent: (NotebookPlacement, Int, Int) -> Row

    @State private var selection: UUID?
    @State private var visibleIDs = Set<UUID>()
    @FocusState private var listFocused: Bool

    private var displayedItems: [NotebookPlacement] {
        isExpanded ? items : Array(items.prefix(5))
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Recents")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .fixedSize(horizontal: false, vertical: true)
            List(selection: $selection) {
                ForEach(Array(displayedItems.enumerated()), id: \.element.item.id) {
                    index, placement in
                    rowContent(placement, index, displayedItems.count)
                        .background {
                            if index == 0 {
                                NotebookMacOverlayScrollbar(removesColumnSpacing: true)
                            }
                        }
                        .tag(placement.item.id)
                        .onAppear { visibleIDs.insert(placement.item.id) }
                        .onDisappear { visibleIDs.remove(placement.item.id) }
                }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            // Match the compact native list so existing rows do not shift.
            .listStyle(.plain)
            .scrollIndicators(.automatic)
            .contentMargins(.horizontal, 0, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 0, maxHeight: .infinity)
            .focused($listFocused)
            .accessibilityIdentifier("notebook-all-recents")
            .onChange(of: selection) { _, id in
                if isExpanded, let id { onSelect(id) }
            }
            .onChange(of: visibleIDs) { _, _ in publishVisibleIDs() }
            .onChange(of: items.map(\.item.id)) { _, ids in
                visibleIDs.formIntersection(ids)
                if let selection, !ids.contains(selection) { self.selection = nil }
                publishVisibleIDs()
            }
            NotebookMacRecentsFooter(onCollapse: onCollapse)
        }
        .clipped()
        .onExitCommand(perform: onCollapse)
        .onAppear {
            if isExpanded { selection = selectedNoteID }
            listFocused = isExpanded
            publishVisibleIDs()
        }
        .onChange(of: isExpanded) { _, expanded in
            if expanded { selection = selectedNoteID }
            listFocused = expanded
            if expanded { publishVisibleIDs() }
        }
        .onChange(of: selectedNoteID) { _, id in
            if isExpanded { selection = id }
        }
    }

    private func publishVisibleIDs() {
        guard isExpanded else { return }
        onVisibleIDs(items.map(\.item.id).filter { visibleIDs.contains($0) })
    }
}

private struct NotebookMacRecentsFooter: View {
    let onCollapse: () -> Void

    var body: some View {
        Button(action: onCollapse) {
            Label("Less", systemImage: "chevron.up")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Back to Files (Escape)")
        .accessibilityLabel("Back to Files")
        .accessibilityIdentifier("notebook-recents-collapse")
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Configure the containing native scroll view without replacing SwiftUI's
/// List, selection, swipe actions or scrolling. A row/content background
/// places this view inside that scroll view, using only public AppKit APIs.
struct NotebookMacOverlayScrollbar: NSViewRepresentable {
    // Plain NSTableView adds half its column spacing at each row edge.
    // Expanded Recents already supplies the same padding as compact rows.
    var removesColumnSpacing = false

    func makeNSView(context: Context) -> NotebookMacOverlayScrollbarView {
        let view = NotebookMacOverlayScrollbarView()
        view.removesColumnSpacing = removesColumnSpacing
        return view
    }

    func updateNSView(_ view: NotebookMacOverlayScrollbarView, context: Context) {
        view.removesColumnSpacing = removesColumnSpacing
        view.applyOverlayStyle()
    }
}

final class NotebookMacOverlayScrollbarView: NSView {
    private static var controllerKey: UInt8 = 0
    var removesColumnSpacing = false

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        applyOverlayStyle()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyOverlayStyle()
    }

    override func layout() {
        super.layout()
        applyOverlayStyle()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func applyOverlayStyle() {
        guard let scrollView = enclosingScrollView else { return }
        if let controller = objc_getAssociatedObject(scrollView, &Self.controllerKey)
            as? NotebookMacOverlayScrollbarController {
            controller.removesColumnSpacing = removesColumnSpacing
            controller.applyOverlayStyle()
        } else {
            let controller = NotebookMacOverlayScrollbarController(
                scrollView: scrollView, removesColumnSpacing: removesColumnSpacing
            )
            objc_setAssociatedObject(scrollView, &Self.controllerKey, controller,
                                     .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}

/// Keep the preference scoped to this scroll view even when its first row is
/// offscreen. SwiftUI can reset the style when the drawer opens, and AppKit
/// can reset it when pointing devices/settings change.
@MainActor
private final class NotebookMacOverlayScrollbarController: NSObject {
    private weak var scrollView: NSScrollView?
    private var observer: NSObjectProtocol?
    private var styleObservation: NSKeyValueObservation?
    private var applicationScheduled = false
    private var isApplyingOverlayStyle = false
    var removesColumnSpacing: Bool

    init(scrollView: NSScrollView, removesColumnSpacing: Bool) {
        self.scrollView = scrollView
        self.removesColumnSpacing = removesColumnSpacing
        super.init()
        styleObservation = scrollView.observe(\.scrollerStyle, options: [.new]) {
            [weak self] _, change in
            guard change.newValue != .overlay else { return }
            // AppKit view changes run on the main thread. Restore the style
            // before this setter returns, so expansion cannot draw even one
            // frame with a legacy scrollbar or its reserved gutter. Our own
            // overlay write is ignored above, avoiding recursive correction.
            MainActor.assumeIsolated { self?.applyOverlayStyle() }
        }
        observer = NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Run after AppKit has applied the system preference.
            DispatchQueue.main.async { [weak self] in self?.scheduleOverlayStyle() }
        }
        applyOverlayStyle()
        scheduleOverlayStyle()
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        styleObservation?.invalidate()
    }

    private func scheduleOverlayStyle() {
        guard !applicationScheduled else { return }
        applicationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applicationScheduled = false
            self.applyOverlayStyle()
        }
    }

    func applyOverlayStyle() {
        guard !isApplyingOverlayStyle, let scrollView else { return }
        // Both setters can trigger native layout or style observations.
        isApplyingOverlayStyle = true
        defer { isApplyingOverlayStyle = false }
        if removesColumnSpacing, let table = scrollView.documentView as? NSTableView,
           table.intercellSpacing.width != 0 {
            table.intercellSpacing = NSSize(width: 0, height: table.intercellSpacing.height)
        }
        if scrollView.scrollerStyle != .overlay {
            // An incompatible native scroller can reject overlay style.
            // Avoid reentering if that setter reports legacy style again.
            scrollView.scrollerStyle = .overlay
        }
    }
}
#endif
