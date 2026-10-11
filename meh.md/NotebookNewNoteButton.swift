#if os(iOS)
import SwiftUI
import UIKit

/// Keeps the primary tap and secondary menu gesture on the same native control.
struct NotebookNewNoteButton: UIViewRepresentable {
    let isEnabled: Bool
    let hasTemplates: Bool
    let onNewNote: () -> Void
    let onNewFromTemplate: () -> Void
    let onNewFolder: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "plus")
        configuration.preferredSymbolConfigurationForImage =
            UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        configuration.indicator = .automatic
        configuration.buttonSize = .small
        configuration.contentInsets = .zero
        let button = UIButton(configuration: configuration)
        button.showsMenuAsPrimaryAction = false
        button.preferredMenuElementOrder = .fixed
        button.accessibilityLabel = String(localized: "New Note")
        button.accessibilityHint = String(
            localized: "Touch and hold for note and folder options."
        )
        button.accessibilityIdentifier = "notebook-new-item"
        button.addTarget(context.coordinator, action: #selector(Coordinator.createNote),
                         for: .primaryActionTriggered)
        button.addTarget(context.coordinator, action: #selector(Coordinator.prepareFeedback),
                         for: .touchDown)
        button.addTarget(context.coordinator, action: #selector(Coordinator.menuWillPresent),
                         for: .menuActionTriggered)
        context.coordinator.feedback = UIImpactFeedbackGenerator(
            style: .medium, view: button
        )
        configure(button, coordinator: context.coordinator)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        configure(button, coordinator: context.coordinator)
    }

    private func configure(_ button: UIButton, coordinator: Coordinator) {
        coordinator.isEnabled = isEnabled
        coordinator.canCreateFromTemplate = isEnabled && hasTemplates
        coordinator.onNewNote = onNewNote
        coordinator.onNewFromTemplate = onNewFromTemplate
        coordinator.onNewFolder = onNewFolder
        button.isEnabled = isEnabled
        let attributes: UIMenuElement.Attributes = isEnabled ? [] : .disabled
        button.menu = UIMenu(children: [
            UIAction(title: String(localized: "New Note"),
                     image: UIImage(systemName: "plus"),
                     identifier: UIAction.Identifier("notebook-menu-new-note"),
                     attributes: attributes) { [weak coordinator] _ in
                coordinator?.createNote()
            },
            UIAction(title: String(localized: "New from Template…"),
                     image: UIImage(systemName: "doc.on.doc"),
                     identifier: UIAction.Identifier("notebook-new-from-template"),
                     attributes: coordinator.canCreateFromTemplate ? [] : .disabled) { [weak coordinator] _ in
                coordinator?.createFromTemplate()
            },
            UIAction(title: String(localized: "New Folder"),
                     image: UIImage(systemName: "folder.badge.plus"),
                     identifier: UIAction.Identifier("notebook-menu-new-folder"),
                     attributes: attributes) { [weak coordinator] _ in
                coordinator?.createFolder()
            },
        ])
        button.accessibilityCustomActions = [
            UIAccessibilityCustomAction(
                name: String(localized: "New from Template…")
            ) { [weak coordinator] _ in
                guard let coordinator, coordinator.canCreateFromTemplate else { return false }
                coordinator.createFromTemplate()
                return true
            },
        ].filter { _ in coordinator.canCreateFromTemplate }
        button.accessibilityCustomActions?.append(UIAccessibilityCustomAction(
            name: String(localized: "New Folder")
        ) { [weak coordinator] _ in
            guard let coordinator, coordinator.isEnabled else { return false }
            coordinator.createFolder()
            return true
        })
    }

    @MainActor
    final class Coordinator: NSObject {
        var isEnabled = true
        var canCreateFromTemplate = false
        var onNewNote: (() -> Void)?
        var onNewFromTemplate: (() -> Void)?
        var onNewFolder: (() -> Void)?
        var feedback: UIImpactFeedbackGenerator?

        @objc func createNote() {
            guard isEnabled else { return }
            onNewNote?()
        }

        func createFromTemplate() {
            guard canCreateFromTemplate else { return }
            onNewFromTemplate?()
        }

        func createFolder() {
            guard isEnabled else { return }
            onNewFolder?()
        }

        @objc func prepareFeedback() { feedback?.prepare() }

        @objc func menuWillPresent() {
            guard isEnabled else { return }
            // UIKit sends this event once the menu gesture succeeds, before
            // presenting the menu. Ordinary taps never request feedback.
            feedback?.impactOccurred()
        }
    }
}
#endif
