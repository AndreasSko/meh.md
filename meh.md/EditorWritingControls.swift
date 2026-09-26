import SwiftUI
import Observation

#if os(iOS)
import UIKit
#endif

struct EditorModeControl: View {
    @Binding var mode: MarkdownEditorMode
    let isEnabled: Bool

    var body: some View {
        Picker("Editor Mode", selection: $mode) {
            Label("Source", systemImage: "doc.plaintext")
                .tag(MarkdownEditorMode.source)
                .accessibilityIdentifier("editor-mode-source")
            Label("Live Preview", systemImage: "text.document")
                .tag(MarkdownEditorMode.livePreview)
                .accessibilityIdentifier("editor-mode-live-preview")
        }
        .disabled(!isEnabled)
        .accessibilityIdentifier("editor-mode")
    }
}

struct EditorWritingControls: View {
    let navigation: MarkdownEditorNavigation
    let isEnabled: Bool

    var body: some View {
        Menu {
            commandButton("Bold", systemImage: "bold", command: .bold)
            commandButton("Italic", systemImage: "italic", command: .italic)
            commandButton("Link", systemImage: "link", command: .link)
            commandButton(
                "Heading", systemImage: "textformat.size.larger",
                command: .heading
            )
            commandButton(
                "Inline Code", systemImage: "chevron.left.forwardslash.chevron.right",
                command: .inlineCode
            )

            Divider()

            commandButton(
                "Strikethrough", systemImage: "strikethrough",
                command: .strikethrough
            )
            commandButton(
                "Highlight", systemImage: "highlighter", command: .highlight
            )
            commandButton(
                "Code Block", systemImage: "curlybraces.square", command: .codeBlock
            )
            Divider()
            EditorTableMenu(navigation: navigation)
            Divider()

            commandButton(
                "Indent", systemImage: "increase.indent", command: .indent
            )
            commandButton(
                "Outdent", systemImage: "decrease.indent", command: .outdent
            )
        } label: {
            Label("Formatting", systemImage: "textformat")
                .labelStyle(.iconOnly)
        }
        .disabled(!isEnabled)
        .accessibilityIdentifier("editor-formatting")
    }

    private func commandButton(
        _ title: String,
        systemImage: String,
        command: MarkdownEditingCommand
    ) -> some View {
        Button {
            navigation.performCommand?(command)
        } label: {
            Label(title, systemImage: systemImage)
        }
        .accessibilityIdentifier(command.accessibilityIdentifier)
    }
}

private extension MarkdownEditingCommand {
    var accessibilityIdentifier: String {
        switch self {
        case .continueLine: "editor-command-continue-line"
        case .indent: "editor-command-indent"
        case .outdent: "editor-command-outdent"
        case .bold: "editor-command-bold"
        case .italic: "editor-command-italic"
        case .strikethrough: "editor-command-strikethrough"
        case .highlight: "editor-command-highlight"
        case .heading: "editor-command-heading"
        case .link: "editor-command-link"
        case .inlineCode: "editor-command-inline-code"
        case .codeBlock: "editor-command-code-block"
        case .insertTable: "editor-command-insert-table"
        case .tableRowAbove: "editor-command-table-row-above"
        case .tableRowBelow: "editor-command-table-row-below"
        case .tableColumnBefore: "editor-command-table-column-before"
        case .tableColumnAfter: "editor-command-table-column-after"
        case .tableDeleteRow: "editor-command-table-delete-row"
        case .tableDeleteColumn: "editor-command-table-delete-column"
        case .tableAlignLeft: "editor-command-table-align-left"
        case .tableAlignCenter: "editor-command-table-align-center"
        case .tableAlignRight: "editor-command-table-align-right"
        case .tableNextCell: "editor-command-table-next-cell"
        case .tablePreviousCell: "editor-command-table-previous-cell"
        }
    }
}

/// Only the formatting controls observe availability, never the document view.
@Observable
@MainActor
final class MarkdownTableCommandState {
    var available: Set<MarkdownEditingCommand> = []
    var currentAlignment: MarkdownTableAlignment?
    @ObservationIgnored private var refreshPending = false

    func scheduleRefresh(from textView: MarkdownTextView) {
        guard !refreshPending else { return }
        refreshPending = true
        // Native delegates can run during representable updates. Publish the
        // menu state after that update, using the latest source and selection.
        DispatchQueue.main.async { [weak self, weak textView] in
            guard let self else { return }
            self.refreshPending = false
            self.available = textView?.availableTableCommands ?? []
            self.currentAlignment = textView?.currentTableAlignment
        }
    }
}

extension MarkdownTextView {
    var commandSource: String {
#if os(macOS)
        string
#else
        text ?? ""
#endif
    }

    var commandSelection: NSRange {
#if os(macOS)
        selectedRange()
#else
        selectedRange
#endif
    }

    var availableTableCommands: Set<MarkdownEditingCommand> {
#if os(macOS)
        guard isEditable, !hasMarkedText() else { return [] }
#else
        guard isEditable, markedTextRange == nil else { return [] }
#endif
        return MarkdownTableEditing.availableCommands(
            text: commandSource, selection: commandSelection,
            syntax: markdownSyntaxCache.result(for: commandSource)
        )
    }

    var currentTableAlignment: MarkdownTableAlignment? {
#if os(macOS)
        guard isEditable, !hasMarkedText() else { return nil }
#else
        guard isEditable, markedTextRange == nil else { return nil }
#endif
        return MarkdownTableEditing.currentAlignment(
            text: commandSource, selection: commandSelection,
            syntax: markdownSyntaxCache.result(for: commandSource)
        )
    }

    /// Confirmation must not target a different cell after a remote update.
    func preparedMarkdownCommand(
        _ command: MarkdownEditingCommand
    ) -> (() -> Void)? {
        guard availableTableCommands.contains(command) else { return nil }
        let source = commandSource
        let selection = commandSelection
        return { [weak self] in
            guard let self,
                  self.commandSource.utf8.elementsEqual(source.utf8),
                  self.commandSelection == selection else { return }
            _ = self.performMarkdownCommand(command)
        }
    }
}

private struct TableCommandDefinition: Identifiable {
    let title: LocalizedStringResource
    let image: String
    let command: MarkdownEditingCommand
    var id: MarkdownEditingCommand { command }
    var isDestructive: Bool {
        command == .tableDeleteRow || command == .tableDeleteColumn
    }
    var alignment: MarkdownTableAlignment? {
        switch command {
        case .tableAlignLeft: .left
        case .tableAlignCenter: .center
        case .tableAlignRight: .right
        default: nil
        }
    }

    static let groups: [[Self]] = [
        [.init(title: "Insert Table", image: "tablecells", command: .insertTable)],
        [
            .init(title: "Add Row Above", image: "arrow.up", command: .tableRowAbove),
            .init(title: "Add Row Below", image: "arrow.down", command: .tableRowBelow),
        ],
        [
            .init(title: "Add Column Before", image: "arrow.left", command: .tableColumnBefore),
            .init(title: "Add Column After", image: "arrow.right", command: .tableColumnAfter),
        ],
        [
            .init(title: "Align Left", image: "text.alignleft", command: .tableAlignLeft),
            .init(title: "Align Center", image: "text.aligncenter", command: .tableAlignCenter),
            .init(title: "Align Right", image: "text.alignright", command: .tableAlignRight),
        ],
        [
            .init(title: "Previous Cell", image: "chevron.left", command: .tablePreviousCell),
            .init(title: "Next Cell", image: "chevron.right", command: .tableNextCell),
        ],
        [
            .init(title: "Delete Row", image: "trash", command: .tableDeleteRow),
            .init(title: "Delete Column", image: "trash", command: .tableDeleteColumn),
        ],
    ]
}

private struct EditorTableMenu: View {
    let navigation: MarkdownEditorNavigation
    @State private var showsDeletionConfirmation = false
    @State private var deletionAction: (() -> Void)?

    var body: some View {
        Menu {
            // Group identity is its first, stable command.
            ForEach(TableCommandDefinition.groups, id: \.first!.id) { group in
                Section {
                    ForEach(group) { item in
                        Button(role: item.isDestructive ? .destructive : nil) {
                            if item.isDestructive {
                                deletionAction = navigation.prepareCommand?(item.command)
                                showsDeletionConfirmation = deletionAction != nil
                            } else {
                                navigation.performCommand?(item.command)
                            }
                        } label: {
                            Label {
                                Text(item.title)
                            } icon: {
                                Image(systemName: item.alignment != nil
                                      && item.alignment == navigation.tableCommands.currentAlignment
                                      ? "checkmark" : item.image)
                            }
                        }
                        .disabled(!navigation.tableCommands.available.contains(item.command))
                        .accessibilityAddTraits(item.alignment != nil
                            && item.alignment == navigation.tableCommands.currentAlignment
                            ? .isSelected : [])
                        .accessibilityIdentifier(item.command.accessibilityIdentifier)
                    }
                }
            }
        } label: {
            Label("Table", systemImage: "tablecells")
        }
        .accessibilityIdentifier("editor-table-menu")
        .confirmationDialog("Delete table content?", isPresented: $showsDeletionConfirmation) {
            Button("Delete", role: .destructive) {
                deletionAction?()
                deletionAction = nil
            }
        } message: {
            Text("The selected row or column and its contents will be removed.")
        }
    }
}

#if os(iOS)
extension MarkdownTextView {
    func installMarkdownKeyboardToolbar() {
        inputAccessoryView = MarkdownKeyboardAccessoryView(textView: self)
    }
}

private final class MarkdownKeyboardAccessoryView: UIView,
    UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private struct CommandDefinition {
        let id: String
        let title: String
        let systemImage: String
        let command: MarkdownEditingCommand
    }

    private static let orderDefaultsKey = "editor.keyboardToolbar.commands"
    private static let definitions = [
        CommandDefinition(
            id: "indent", title: "Indent",
            systemImage: "increase.indent", command: .indent
        ),
        CommandDefinition(
            id: "outdent", title: "Outdent",
            systemImage: "decrease.indent", command: .outdent
        ),
        CommandDefinition(
            id: "bold", title: "Bold", systemImage: "bold", command: .bold
        ),
        CommandDefinition(
            id: "italic", title: "Italic", systemImage: "italic",
            command: .italic
        ),
    ]
    private static let defaultOrder = definitions.map(\.id)

    private weak var textView: MarkdownTextView?
    private var order: [String]
    private var isMovingCommand = false
    private let layout = UICollectionViewFlowLayout()
    private lazy var collectionView = MarkdownKeyboardCollectionView(
        frame: .zero,
        collectionViewLayout: layout
    )

    init(textView: MarkdownTextView) {
        self.textView = textView
        order = Self.savedOrder()
        super.init(
            frame: CGRect(x: 0, y: 0, width: textView.bounds.width, height: 50)
        )
        configureView()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let spacing = max(4, (collectionView.bounds.width - 5 * 44) / 4)
        if layout.minimumLineSpacing != spacing {
            layout.minimumLineSpacing = spacing
            layout.invalidateLayout()
        }
    }

    private func configureView() {
        autoresizingMask = [.flexibleWidth]
        backgroundColor = .secondarySystemBackground
        tintColor = .label
        accessibilityIdentifier = "editor-keyboard-toolbar"

        let separator = UIView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.backgroundColor = .separator
        addSubview(separator)

        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: 44, height: 44)
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = .zero
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.isScrollEnabled = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(
            MarkdownKeyboardButtonCell.self,
            forCellWithReuseIdentifier: MarkdownKeyboardButtonCell.reuseIdentifier
        )
        let longPress = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleLongPress(_:))
        )
        collectionView.addGestureRecognizer(longPress)
        addSubview(collectionView)

        let adaptiveWidth = collectionView.widthAnchor.constraint(
            equalTo: widthAnchor,
            constant: -24
        )
        adaptiveWidth.priority = UILayoutPriority(
            rawValue: UILayoutPriority.defaultHigh.rawValue + 1
        )
        let preferredTabletWidth = collectionView.widthAnchor.constraint(
            equalToConstant: 480
        )
        preferredTabletWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),
            collectionView.centerXAnchor.constraint(equalTo: centerXAnchor),
            collectionView.centerYAnchor.constraint(equalTo: centerYAnchor),
            collectionView.heightAnchor.constraint(equalToConstant: 44),
            collectionView.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor,
                constant: 12
            ),
            collectionView.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -12
            ),
            collectionView.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            adaptiveWidth,
            preferredTabletWidth,
        ])
    }

    func collectionView(
        _ collectionView: UICollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        order.count + 1
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: MarkdownKeyboardButtonCell.reuseIdentifier,
            for: indexPath
        ) as! MarkdownKeyboardButtonCell
        if indexPath.item == order.count {
            cell.configure(
                title: "More Formatting",
                systemImage: "ellipsis.circle",
                accessibilityIdentifier: "editor-formatting",
                action: nil,
                menu: UIMenu(children: [
                    UIDeferredMenuElement.uncached { [weak self] completion in
                        completion(self?.formattingMenuElements() ?? [])
                    },
                ]),
                accessibilityActions: []
            )
            return cell
        }

        let definition = definition(at: indexPath.item)
        let action = UIAction { [weak textView] _ in
            _ = textView?.performMarkdownCommand(definition.command)
        }
        cell.configure(
            title: definition.title,
            systemImage: definition.systemImage,
            accessibilityIdentifier: definition.command.accessibilityIdentifier,
            action: action,
            menu: nil,
            accessibilityActions: accessibilityMoveActions(for: definition.id)
        )
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        canMoveItemAt indexPath: IndexPath
    ) -> Bool {
        indexPath.item < order.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        moveItemAt sourceIndexPath: IndexPath,
        to destinationIndexPath: IndexPath
    ) {
        let command = order.remove(at: sourceIndexPath.item)
        order.insert(command, at: min(destinationIndexPath.item, order.count))
        saveOrder()
    }

    func collectionView(
        _ collectionView: UICollectionView,
        targetIndexPathForMoveFromItemAt originalIndexPath: IndexPath,
        toProposedIndexPath proposedIndexPath: IndexPath
    ) -> IndexPath {
        IndexPath(
            item: min(proposedIndexPath.item, order.count - 1),
            section: proposedIndexPath.section
        )
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        let location = gesture.location(in: collectionView)
        switch gesture.state {
        case .began:
            guard let indexPath = collectionView.indexPathForItem(at: location),
                  indexPath.item < order.count else { return }
            isMovingCommand = collectionView.beginInteractiveMovementForItem(
                at: indexPath
            )
        case .changed:
            if isMovingCommand {
                collectionView.updateInteractiveMovementTargetPosition(location)
            }
        case .ended:
            if isMovingCommand {
                collectionView.endInteractiveMovement()
                DispatchQueue.main.async { [weak self] in
                    self?.refreshVisibleAccessibilityActions()
                }
            }
            isMovingCommand = false
        default:
            if isMovingCommand { collectionView.cancelInteractiveMovement() }
            isMovingCommand = false
        }
    }

    private func definition(at index: Int) -> CommandDefinition {
        let id = order[index]
        return Self.definitions.first { $0.id == id }!
    }

    private func accessibilityMoveActions(
        for id: String
    ) -> [UIAccessibilityCustomAction] {
        guard let index = order.firstIndex(of: id) else { return [] }
        var actions: [UIAccessibilityCustomAction] = []
        if index > 0 {
            actions.append(
                UIAccessibilityCustomAction(name: "Move Left") {
                    [weak self] _ in self?.moveCommand(id: id, by: -1) == true
                }
            )
        }
        if index < order.count - 1 {
            actions.append(
                UIAccessibilityCustomAction(name: "Move Right") {
                    [weak self] _ in self?.moveCommand(id: id, by: 1) == true
                }
            )
        }
        return actions
    }

    private func moveCommand(id: String, by offset: Int) -> Bool {
        guard let index = order.firstIndex(of: id) else { return false }
        let destination = index + offset
        guard order.indices.contains(index), order.indices.contains(destination) else {
            return false
        }
        order.swapAt(index, destination)
        saveOrder()
        collectionView.reloadData()
        return true
    }

    private func refreshVisibleAccessibilityActions() {
        for visibleCell in collectionView.visibleCells {
            guard let cell = visibleCell as? MarkdownKeyboardButtonCell,
                  let indexPath = collectionView.indexPath(for: cell),
                  indexPath.item < order.count else {
                (visibleCell as? MarkdownKeyboardButtonCell)?
                    .updateAccessibilityActions([])
                continue
            }
            cell.updateAccessibilityActions(
                accessibilityMoveActions(for: order[indexPath.item])
            )
        }
    }

    private func formattingMenuElements() -> [UIMenuElement] {
        let commands: [(LocalizedStringResource, String, MarkdownEditingCommand)] = [
            ("Heading", "textformat.size.larger", .heading),
            ("Link", "link", .link),
            ("Strikethrough", "strikethrough", .strikethrough),
            ("Highlight", "highlighter", .highlight),
            (
                "Inline Code",
                "chevron.left.forwardslash.chevron.right",
                .inlineCode
            ),
            ("Code Block", "curlybraces.square", .codeBlock),
        ]
        let actions = commands.map { title, image, command in
            UIAction(
                title: String(localized: title),
                image: UIImage(systemName: image),
                identifier: UIAction.Identifier(command.accessibilityIdentifier)
            ) { [weak textView] _ in
                _ = textView?.performMarkdownCommand(command)
            }
        }
        return actions + [tableMenu()]
    }

    private func tableMenu() -> UIMenu {
        let available = textView?.availableTableCommands ?? []
        let alignment = textView?.currentTableAlignment
        let groups: [(LocalizedStringResource, [TableCommandDefinition])] = [
            ("Insert", TableCommandDefinition.groups[0]),
            ("Row", TableCommandDefinition.groups[1]),
            ("Column", TableCommandDefinition.groups[2]),
            ("Alignment", TableCommandDefinition.groups[3]),
            ("Cell", TableCommandDefinition.groups[4]),
            ("Delete", TableCommandDefinition.groups[5]),
        ]
        let children: [UIMenuElement] = groups.compactMap { title, definitions in
            let actions = definitions.filter { available.contains($0.command) }
                .map { definition in
                    tableAction(definition, alignment: alignment)
                }
            guard !actions.isEmpty else { return nil }
            if definitions.first?.command == .insertTable {
                return actions.first
            }
            return UIMenu(
                title: String(localized: title),
                children: actions
            )
        }
        return UIMenu(
            title: String(localized: "Table"),
            image: UIImage(systemName: "tablecells"),
            identifier: UIMenu.Identifier("editor-table-menu"),
            children: children
        )
    }

    private func tableAction(
        _ definition: TableCommandDefinition,
        alignment: MarkdownTableAlignment?
    ) -> UIAction {
        let isSelected = definition.alignment != nil
            && definition.alignment == alignment
        return UIAction(
            title: String(localized: definition.title),
            image: UIImage(systemName: definition.image),
            identifier: UIAction.Identifier(
                definition.command.accessibilityIdentifier
            ),
            attributes: definition.isDestructive ? .destructive : [],
            state: isSelected ? .on : .off
        ) { [weak textView] _ in
            guard let textView,
                  let action = textView.preparedMarkdownCommand(
                    definition.command
                  ) else { return }
            if definition.isDestructive {
                Self.confirmDeletion(
                    definition, action: action, textView: textView
                )
            } else {
                action()
            }
        }
    }

    private static func confirmDeletion(
        _ definition: TableCommandDefinition,
        action: @escaping () -> Void,
        textView: MarkdownTextView
    ) {
        guard let presenter = owningViewController(for: textView) else { return }
        let alert = UIAlertController(
            title: String(localized: definition.title),
            message: String(localized:
                "The selected row or column and its contents will be removed."),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: String(localized: "Cancel"), style: .cancel
        ) { [weak textView] _ in
            textView?.becomeFirstResponder()
        })
        alert.addAction(UIAlertAction(
            title: String(localized: "Delete"), style: .destructive
        ) { _ in action() })
        DispatchQueue.main.async { presenter.present(alert, animated: true) }
    }

    private func saveOrder() {
        UserDefaults.standard.set(order, forKey: Self.orderDefaultsKey)
    }

    private static func savedOrder() -> [String] {
        let saved = UserDefaults.standard.stringArray(forKey: orderDefaultsKey) ?? []
        guard saved.count == defaultOrder.count,
              Set(saved) == Set(defaultOrder) else { return defaultOrder }
        return saved
    }

    private static func owningViewController(for view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let next = responder?.next {
            if let controller = next as? UIViewController { return controller }
            responder = next
        }
        return nil
    }
}

private final class MarkdownKeyboardCollectionView: UICollectionView {
    override var canBecomeFirstResponder: Bool { false }
}

private final class MarkdownKeyboardButtonCell: UICollectionViewCell {
    static let reuseIdentifier = "MarkdownKeyboardButtonCell"

    private let button = UIButton(type: .system)
    private var primaryAction: UIAction?

    override init(frame: CGRect) {
        super.init(frame: frame)
        button.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func configure(
        title: String,
        systemImage: String,
        accessibilityIdentifier: String,
        action: UIAction?,
        menu: UIMenu?,
        accessibilityActions: [UIAccessibilityCustomAction]
    ) {
        if let primaryAction {
            button.removeAction(primaryAction, for: .primaryActionTriggered)
        }
        primaryAction = action
        if let action {
            button.addAction(action, for: .primaryActionTriggered)
        }
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: systemImage)
        configuration.baseForegroundColor = .label
        configuration.preferredSymbolConfigurationForImage =
            UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        button.configuration = configuration
        button.menu = menu
        button.showsMenuAsPrimaryAction = menu != nil
        button.accessibilityLabel = title
        button.accessibilityIdentifier = accessibilityIdentifier
        button.accessibilityCustomActions = accessibilityActions
    }

    func updateAccessibilityActions(
        _ actions: [UIAccessibilityCustomAction]
    ) {
        button.accessibilityCustomActions = actions
    }
}
#endif
