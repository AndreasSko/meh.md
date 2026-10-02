#if os(iOS)
import SwiftUI
import UIKit

/// Files keeps its place while matching recent rows unfold above it.
struct NotebookRecentsAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?,
                       nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

struct NotebookRecentsFooterSpacer: View {
    @ScaledMetric(relativeTo: .subheadline) private var height = 44.0

    var body: some View {
        Color.clear.frame(height: height).allowsHitTesting(false)
    }
}

struct NotebookRecentsExpansionHost<Browser: View, Row: View>: View {
    let items: [NotebookRecentUIKitItem]
    let compactCount: Int
    @Binding var isExpanded: Bool
    @ViewBuilder let rowContent: (UUID, Int, Int) -> Row
    let onTogglePin: (UUID) -> Void
    let contextMenu: (UUID) -> UIMenu
    let onVisibleIDs: ([UUID]) -> Void
    @ViewBuilder let browser: (Bool) -> Browser

    @State private var isPulling = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                browser(isExpanded || isPulling)
                    .scrollDisabled(isExpanded || isPulling)
                    .allowsHitTesting(!isExpanded && !isPulling)
                    .accessibilityHidden(isExpanded || isPulling)
            }
            .overlayPreferenceValue(NotebookRecentsAnchorKey.self) { anchor in
                if let anchor {
                    NotebookRecentsSurface(
                        items: items, compactCount: compactCount,
                        compactFrame: geometry[anchor],
                        availableSize: geometry.size,
                        isExpanded: $isExpanded, isPulling: $isPulling,
                        rowContent: rowContent, onTogglePin: onTogglePin,
                        contextMenu: contextMenu,
                        onVisibleIDs: onVisibleIDs
                    )
                    .clipped()
                }
            }
        }
        .background(NotebookSidebarPalette.background)
        .onChange(of: isExpanded) { _, expanded in
            if !expanded && !isPulling { onVisibleIDs([]) }
        }
        .onChange(of: isPulling) { _, pulling in
            if !pulling && !isExpanded { onVisibleIDs([]) }
        }
        .onChange(of: compactCount) { _, count in
            if count == 0 {
                isExpanded = false
                isPulling = false
            }
        }
    }
}

private struct NotebookRecentsSurface<Row: View>: View {
    let items: [NotebookRecentUIKitItem]
    let compactCount: Int
    let compactFrame: CGRect
    let availableSize: CGSize
    @Binding var isExpanded: Bool
    @Binding var isPulling: Bool
    let rowContent: (UUID, Int, Int) -> Row
    let onTogglePin: (UUID) -> Void
    let contextMenu: (UUID) -> UIMenu
    let onVisibleIDs: ([UUID]) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .headline) private var headerSize = 44.0
    @ScaledMetric(relativeTo: .subheadline) private var footerSize = 44.0
    @AccessibilityFocusState private var grabberFocused: Bool
    @GestureState private var isDragging = false
    @State private var dragFrame: CGRect?
    @State private var dragStartFrame: CGRect?
    @State private var dragKind: DragKind?
    @State private var isArmed = false
    @State private var thresholdFeedback = 0
    @State private var settleFeedback = 0
    @State private var isClosing = false
    @State private var transitionGeneration = 0

    private enum DragKind { case opening, closing }

    private var expandedFrame: CGRect {
        let inset = max(16, compactFrame.minX)
        return CGRect(x: inset, y: 12,
                      width: max(0, availableSize.width - inset * 2),
                      height: max(0, availableSize.height - 24))
    }

    private var frame: CGRect {
        if !reduceMotion, let dragFrame { return dragFrame }
        return isExpanded ? expandedFrame : compactFrame
    }

    private var progress: CGFloat {
        let range = expandedFrame.height - compactFrame.height
        guard range > 0 else { return isExpanded ? 1 : 0 }
        return min(1, max(0, (frame.height - compactFrame.height) / range))
    }

    private var commitDistance: CGFloat {
        min(80, max(44, (compactFrame.minY - expandedFrame.minY) * 0.5))
    }

    private var animation: Animation {
        reduceMotion ? .easeOut(duration: 0.15)
            : .spring(response: 0.38, dampingFraction: 0.9)
    }

    var body: some View {
        let showingHistory = isExpanded || isPulling
        let hasMore = items.count > compactCount
        VStack(spacing: 0) {
            if showingHistory {
                Text("Recents").font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .frame(height: isExpanded ? headerSize : 0)
                .opacity(isExpanded ? 1 : 0)
                .clipped()
                .accessibilityHidden(!isExpanded)
            }
            if showingHistory {
                NotebookRecentUIKitList(
                    items: items,
                    rowContent: { id in
                        if let index = items.firstIndex(where: { $0.id == id }) {
                            rowContent(id, index, items.count)
                        }
                    },
                    onTogglePin: onTogglePin, contextMenu: contextMenu,
                    usesViewport: true,
                    scrollingEnabled: isExpanded && !isPulling,
                    accessibilityHidden: !isExpanded || isPulling,
                    onVisibleIDs: { ids in
                        if !isClosing { onVisibleIDs(ids) }
                    }
                )
                .frame(maxHeight: .infinity)
                .allowsHitTesting(isExpanded && !isPulling)
                .opacity(isClosing ? progress : 1)
                .overlay(alignment: .top) {
                    if isClosing {
                        VStack(spacing: 0) {
                            ForEach(Array(items.prefix(compactCount).enumerated()),
                                    id: \.element.id) { index, item in
                                rowContent(item.id, index, compactCount)
                            }
                        }
                        .opacity(1 - progress)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
            } else {
                Color.clear.allowsHitTesting(false)
            }
            if hasMore || showingHistory {
                NotebookRecentsExpansionFooter(
                    isExpanded: isExpanded,
                    toggle: { if isExpanded { close() } else { open() } }
                )
                .accessibilityFocused($grabberFocused)
                .frame(height: footerSize)
                .contentShape(Rectangle())
                .highPriorityGesture(cardGesture)
                .accessibilityHidden(isPulling)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("notebook-recents-drag-area")
            }
        }
        .frame(width: frame.width, height: frame.height)
        .background(showingHistory ? NotebookSidebarPalette.recents : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(showingHistory ? 0.06 : 0), radius: 12, y: 4)
        .offset(x: frame.minX, y: frame.minY)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.45),
                         trigger: thresholdFeedback)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.65),
                         trigger: settleFeedback)
        .onChange(of: isExpanded) { _, expanded in
            if !isPulling { grabberFocused = true }
            if !expanded && !isPulling {
                dragFrame = nil
                dragKind = nil
            }
        }
        .onChange(of: isPulling) { _, pulling in
            if !pulling { grabberFocused = true }
        }
        .onChange(of: isDragging) { _, dragging in
            if !dragging, dragKind != nil { cancelDrag() }
        }
    }

    private var cardGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .updating($isDragging) { _, dragging, _ in dragging = true }
            .onChanged { value in
                if dragKind == nil {
                    let direction = (isExpanded ? -1 : 1) * value.translation.height
                    guard direction > 0,
                          direction > abs(value.translation.width) else { return }
                    beginDrag(isExpanded ? .closing : .opening)
                }
                guard let kind = dragKind else { return }
                updateDrag(extent: (kind == .opening ? 1 : -1) * value.translation.height)
            }
            .onEnded { value in
                guard let kind = dragKind else { return }
                let sign: CGFloat = kind == .opening ? 1 : -1
                finishDrag(extent: sign * value.translation.height,
                           projectedExtent: sign * value.predictedEndTranslation.height)
            }
    }

    private func beginDrag(_ kind: DragKind) {
        transitionGeneration += 1
        dragKind = kind
        dragStartFrame = isExpanded ? expandedFrame : compactFrame
        isClosing = kind == .closing
        isPulling = true
    }

    private func updateDrag(extent: CGFloat) {
        guard let kind = dragKind, let start = dragStartFrame else { return }
        // The lower grabber stays under the finger in both states. Only
        // release animates the upper edge to its final resting position.
        let maximumHeight = kind == .opening
            ? max(start.height, expandedFrame.maxY - start.minY)
            : expandedFrame.height
        let height = start.height + (kind == .opening ? 1 : -1) * max(0, extent)
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            dragFrame = CGRect(x: start.minX, y: start.minY, width: start.width,
                               height: min(maximumHeight,
                                           max(compactFrame.height, height)))
        }
        let armed = extent >= commitDistance
        if armed && !isArmed { thresholdFeedback += 1 }
        isArmed = armed
    }

    private func finishDrag(extent: CGFloat, projectedExtent: CGFloat) {
        guard let kind = dragKind else { return }
        let commits = extent >= commitDistance
            || (extent > 24 && projectedExtent > commitDistance * 1.5)
        if commits {
            if kind == .opening { open() } else { close() }
        } else {
            cancelDrag()
        }
    }

    private func open() {
        guard !isExpanded else { return }
        transitionGeneration += 1
        let generation = transitionGeneration
        dragKind = nil
        isArmed = false
        isClosing = false
        settleFeedback += 1
        isPulling = true
        withAnimation(animation) {
            isExpanded = true
            dragFrame = nil
        } completion: {
            guard transitionGeneration == generation else { return }
            if isExpanded { isPulling = false }
        }
    }

    private func close() {
        transitionGeneration += 1
        let generation = transitionGeneration
        dragKind = nil
        isArmed = false
        settleFeedback += 1
        isClosing = true
        isPulling = true
        withAnimation(animation) {
            isExpanded = false
            dragFrame = nil
        } completion: {
            guard transitionGeneration == generation else { return }
            if !isExpanded {
                isPulling = false
                isClosing = false
            }
        }
    }

    private func cancelDrag() {
        transitionGeneration += 1
        let generation = transitionGeneration
        dragKind = nil
        isArmed = false
        withAnimation(animation) { dragFrame = nil } completion: {
            guard transitionGeneration == generation else { return }
            if dragKind == nil {
                isPulling = false
                isClosing = false
            }
        }
    }
}

private struct NotebookRecentsExpansionFooter: View {
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Capsule().frame(width: 36, height: 5)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Close Recents" : "Show all recent notes")
        .accessibilityHint(isExpanded ? "Tap or pull up here to return to Files."
                           : "Tap or pull down here to browse older notes.")
        .accessibilityIdentifier(isExpanded ? "notebook-recents-close"
                                    : "notebook-recents-show-all")
    }
}
#endif
