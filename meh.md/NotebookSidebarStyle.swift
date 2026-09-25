import SwiftUI

enum NotebookSidebarPalette {
    static var background: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
    }

    static var recents: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemGroupedBackground)
        #endif
    }
}

struct NotebookSectionToggle: View {
    let title: LocalizedStringResource
    let isExpanded: Bool
    let identifier: String
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Color.secondary)
            .frame(minHeight: minimumHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }

    private var minimumHeight: CGFloat {
        #if os(macOS)
        28
        #else
        44
        #endif
    }
}

struct NotebookRecentRow: View {
    let title: String
    let preview: String
    let isPinned: Bool
    let isCurrent: Bool
    let showsDivider: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if isPinned {
                            Spacer(minLength: 4)
                            Image(systemName: "pin.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isCurrent {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 12)
            if showsDivider {
                Divider()
            }
        }
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(
            [isPinned ? "Pinned" : nil, isCurrent ? "Current note" : nil]
                .compactMap { $0 }.joined(separator: ", ")
        )
    }
}

enum NotebookRecentCardPosition {
    case only
    case first
    case middle
    case last
}

struct NotebookRecentCardBackground: View {
    let position: NotebookRecentCardPosition

    var body: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: topRadius,
            bottomLeadingRadius: bottomRadius,
            bottomTrailingRadius: bottomRadius,
            topTrailingRadius: topRadius
        )
        .fill(NotebookSidebarPalette.recents)
    }

    private var topRadius: CGFloat {
        switch position {
        case .only, .first: 16
        case .middle, .last: 0
        }
    }

    private var bottomRadius: CGFloat {
        switch position {
        case .only, .last: 16
        case .first, .middle: 0
        }
    }
}

struct NotebookSidebarControls: View {
    let busy: Bool
    let showSettings: () -> Void
    let showTrash: () -> Void

    var body: some View {
        HStack {
            NotebookFloatingButton(
                title: "Settings", symbol: "gearshape",
                identifier: "notebook-settings", action: showSettings
            )
            Spacer(minLength: 0)
            NotebookFloatingButton(
                title: "Trash", symbol: "trash",
                identifier: "notebook-trash-toggle", action: showTrash
            )
        }
        .disabled(busy)
        .padding(12)
    }
}

private struct NotebookFloatingButton: View {
    let title: LocalizedStringResource
    let symbol: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label { Text(title) } icon: { Image(systemName: symbol) }
                .labelStyle(.iconOnly)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: controlSize, height: controlSize)
                .contentShape(Circle())
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .help(Text(title))
        .accessibilityIdentifier(identifier)
    }

    private var controlSize: CGFloat {
        #if os(macOS)
        36
        #else
        44
        #endif
    }
}
