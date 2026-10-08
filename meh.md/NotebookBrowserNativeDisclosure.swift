#if os(macOS)
import AppKit
import SwiftUI

/// Gives folder disclosure independent native control tracking during drags.
@MainActor
struct NotebookNativeDisclosureButton: NSViewRepresentable {
    let isExpanded: Bool
    let label: String
    let identifier: String
    let action: @MainActor () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NativeDisclosureButton {
        let button = NativeDisclosureButton(frame: .zero)
        button.title = ""
        button.setButtonType(.momentaryChange)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.symbolConfiguration = NSImage.SymbolConfiguration(
            textStyle: .caption1
        )
        button.keyEquivalent = ""
        // Keep native AppKit tracking, keyboard focus and accessibility press.
        button.target = context.coordinator
        button.action = #selector(Coordinator.activate(_:))
        button.isEnabled = isEnabled
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier(identifier)
        button.updateExpansion(isExpanded, notifying: false)
        return button
    }

    func updateNSView(_ button: NativeDisclosureButton, context: Context) {
        context.coordinator.action = action
        if button.isEnabled != isEnabled { button.isEnabled = isEnabled }
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier(identifier)
        button.updateExpansion(isExpanded, notifying: true)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NativeDisclosureButton,
        context: Context
    ) -> CGSize? {
        let height = proposal.height.map { $0.isFinite ? max(28, $0) : 28 } ?? 28
        return CGSize(width: 20, height: height)
    }

    static func dismantleNSView(
        _ button: NativeDisclosureButton, coordinator: Coordinator
    ) {
        button.target = nil
        button.action = nil
        coordinator.action = {}
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: @MainActor () -> Void

        init(action: @escaping @MainActor () -> Void) {
            self.action = action
        }

        @objc func activate(_ sender: NSButton) {
            guard sender.isEnabled else { return }
            action()
        }
    }

    /// Overrides only the value presentation, not native tracking or AX press.
    @MainActor
    final class NativeDisclosureButton: NSButton {
        private var isExpanded = false

        override func accessibilityValue() -> Any? {
            isExpanded ? "Expanded" : "Collapsed"
        }

        func updateExpansion(_ expanded: Bool, notifying: Bool) {
            let changed = isExpanded != expanded
            isExpanded = expanded
            if changed || image == nil {
                image = NSImage(
                    systemSymbolName: expanded ? "chevron.down" : "chevron.right",
                    accessibilityDescription: nil
                )
            }
            if changed && notifying {
                NSAccessibility.post(element: self, notification: .valueChanged)
            }
        }
    }
}
#endif
