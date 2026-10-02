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
            commandButton(
                "Task List", systemImage: "checklist", command: .taskList
            )
            commandButton(
                "Toggle Task", systemImage: "checkmark.square",
                command: .toggleTask
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
        case .taskList: "editor-command-task-list"
        case .toggleTask: "editor-command-toggle-task"
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
        guard isEditable, !hasMarkedText(),
              !markdownCellController.hasMarkedText else { return [] }
#else
        guard isEditable, markedTextRange == nil,
              !markdownCellController.hasMarkedText else { return [] }
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
            .init(title: "Add Column Left", image: "arrow.left", command: .tableColumnBefore),
            .init(title: "Add Column Right", image: "arrow.right", command: .tableColumnAfter),
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
            .init(title: "Delete Row…", image: "trash", command: .tableDeleteRow),
            .init(title: "Delete Column…", image: "trash", command: .tableDeleteColumn),
        ],
    ]
}

private struct PendingTableDeletion {
    let command: MarkdownEditingCommand
    let action: () -> Void

    var title: LocalizedStringResource {
        command == .tableDeleteColumn ? "Delete column?" : "Delete row?"
    }

    var buttonTitle: LocalizedStringResource {
        command == .tableDeleteColumn ? "Delete Column" : "Delete Row"
    }

    var message: LocalizedStringResource {
        command == .tableDeleteColumn
            ? "The selected column and its contents will be removed."
            : "The selected row and its contents will be removed."
    }
}

private struct TableDeletionConfirmation: ViewModifier {
    @Binding var pending: PendingTableDeletion?

    func body(content: Content) -> some View {
        let deletion = pending
        content.confirmationDialog(
            String(localized: deletion?.title ?? "Delete row?"),
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                deletion?.action()
                pending = nil
            } label: {
                Text(deletion?.buttonTitle ?? "Delete Row")
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text(deletion?.message ?? "")
        }
    }
}

private struct EditorTableMenu: View {
    let navigation: MarkdownEditorNavigation
    @State private var pendingDeletion: PendingTableDeletion?

    var body: some View {
        Menu {
            // Group identity is its first, stable command.
            ForEach(TableCommandDefinition.groups, id: \.first!.id) { group in
                Section {
                    ForEach(group) { item in
                        Button(role: item.isDestructive ? .destructive : nil) {
                            if item.isDestructive {
                                if let action = navigation.prepareCommand?(item.command) {
                                    pendingDeletion = PendingTableDeletion(
                                        command: item.command, action: action
                                    )
                                }
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
        .modifier(TableDeletionConfirmation(pending: $pendingDeletion))
    }
}

#if os(iOS)
private struct KeyboardCommandDefinition: Identifiable {
    let id: String
    let title: LocalizedStringResource
    let image: String
    let command: MarkdownEditingCommand

    static let all: [Self] = [
        .init(id: "bold", title: "Bold", image: "bold", command: .bold),
        .init(id: "italic", title: "Italic", image: "italic", command: .italic),
        .init(id: "taskList", title: "Task List", image: "checklist",
              command: .taskList),
        .init(id: "insertTable", title: "Insert Table", image: "tablecells",
              command: .insertTable),
        .init(id: "indent", title: "Indent", image: "increase.indent",
              command: .indent),
        .init(id: "outdent", title: "Outdent", image: "decrease.indent",
              command: .outdent),
        .init(id: "heading", title: "Heading", image: "textformat.size.larger",
              command: .heading),
        .init(id: "link", title: "Link", image: "link", command: .link),
        .init(id: "strikethrough", title: "Strikethrough",
              image: "strikethrough", command: .strikethrough),
        .init(id: "highlight", title: "Highlight", image: "highlighter",
              command: .highlight),
        .init(id: "inlineCode", title: "Inline Code",
              image: "chevron.left.forwardslash.chevron.right",
              command: .inlineCode),
        .init(id: "codeBlock", title: "Code Block",
              image: "curlybraces.square", command: .codeBlock),
        .init(id: "toggleTask", title: "Toggle Task",
              image: "checkmark.square", command: .toggleTask),
    ]
}

private nonisolated struct SymbolDragPreviewShape: Shape {
    let systemName: String

    func path(in rect: CGRect) -> Path {
        let scale = 3
        let width = max(1, Int(rect.width.rounded(.up)))
        let height = max(1, Int(rect.height.rounded(.up)))
        let pixelWidth = width * scale
        let pixelHeight = height * scale
        let format = UIGraphicsImageRendererFormat()
        format.scale = CGFloat(scale)
        format.opaque = false
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height), format: format
        ).image { _ in
            let configuration = UIImage.SymbolConfiguration(
                pointSize: 18, weight: .regular
            )
            guard let symbol = UIImage(
                systemName: systemName, withConfiguration: configuration
            ) else { return }
            symbol.withTintColor(.black, renderingMode: .alwaysOriginal).draw(
                at: CGPoint(x: (CGFloat(width) - symbol.size.width) / 2,
                            y: (CGFloat(height) - symbol.size.height) / 2)
            )
        }
        guard let cgImage = image.cgImage else { return Path() }
        var pixels = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        let didDraw = pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress, width: pixelWidth,
                height: pixelHeight, bitsPerComponent: 8,
                bytesPerRow: pixelWidth * 4,
                space: colorSpace, bitmapInfo: bitmapInfo
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0,
                                            width: pixelWidth,
                                            height: pixelHeight))
            return true
        }
        guard didDraw else { return Path() }

        var path = Path()
        for row in 0..<pixelHeight {
            var runStart: Int?
            for column in 0...pixelWidth {
                let opaque = column < pixelWidth
                    && pixels[(row * pixelWidth + column) * 4 + 3] > 1
                if opaque && runStart == nil { runStart = column }
                if !opaque, let start = runStart {
                    path.addRect(CGRect(
                        x: rect.minX + CGFloat(start) / CGFloat(scale),
                        y: rect.minY + CGFloat(row) / CGFloat(scale),
                        width: CGFloat(column - start) / CGFloat(scale),
                        height: 1 / CGFloat(scale)
                    ))
                    runStart = nil
                }
            }
        }
        return path
    }
}

struct EditorKeyboardToolbar: View {
    let navigation: MarkdownEditorNavigation
    @State private var pendingDeletion: PendingTableDeletion?

    var body: some View {
        KeyboardToolbarCollection(
            navigation: navigation,
            availableTableCommands: navigation.tableCommands.available,
            currentAlignment: navigation.tableCommands.currentAlignment
        ) { definition in
            guard let action = navigation.prepareCommand?(definition.command) else {
                return
            }
            if definition.isDestructive {
                pendingDeletion = PendingTableDeletion(
                    command: definition.command, action: action
                )
            } else {
                action()
            }
        }
        .frame(maxWidth: 520)
        .frame(height: 50)
        .background {
            Capsule().fill(.clear).glassEffect(.regular, in: .capsule)
        }
        .padding(.horizontal, 8)
        .modifier(TableDeletionConfirmation(pending: $pendingDeletion))
    }
}

private struct KeyboardToolbarCollection: UIViewRepresentable {
    let navigation: MarkdownEditorNavigation
    let availableTableCommands: Set<MarkdownEditingCommand>
    let currentAlignment: MarkdownTableAlignment?
    let performTableCommand: (TableCommandDefinition) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(navigation: navigation, performTableCommand: performTableCommand)
    }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: 44, height: 44)
        layout.minimumLineSpacing = 12
        layout.minimumInteritemSpacing = 12
        layout.sectionInset = UIEdgeInsets(top: 3, left: 12, bottom: 3, right: 12)

        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.showsHorizontalScrollIndicator = false
        view.contentInsetAdjustmentBehavior = .never
        view.decelerationRate = .fast
        view.dragInteractionEnabled = true
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        view.dragDelegate = context.coordinator
        view.dropDelegate = context.coordinator
        view.register(KeyboardToolbarCell.self, forCellWithReuseIdentifier: "command")
        view.accessibilityIdentifier = "editor-keyboard-toolbar"
        context.coordinator.collectionView = view
        context.coordinator.update(
            navigation: navigation,
            availableTableCommands: availableTableCommands,
            currentAlignment: currentAlignment,
            performTableCommand: performTableCommand
        )
        return view
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        context.coordinator.update(
            navigation: navigation,
            availableTableCommands: availableTableCommands,
            currentAlignment: currentAlignment,
            performTableCommand: performTableCommand
        )
    }

    final class Coordinator: NSObject, UICollectionViewDataSource,
                             UICollectionViewDelegateFlowLayout, UICollectionViewDragDelegate,
                             UICollectionViewDropDelegate {
        private static let orderDefaultsKey = "editor.keyboardToolbar.commands"
        weak var collectionView: UICollectionView?
        private var navigation: MarkdownEditorNavigation
        private var performTableCommand: (TableCommandDefinition) -> Void
        private var availableTableCommands: Set<MarkdownEditingCommand> = []
        private var currentAlignment: MarkdownTableAlignment?
        private var commands: [KeyboardCommandDefinition]
        private var needsReloadAfterDrag = false
        private var dragItemFrames: [(index: Int, frame: CGRect)] = []

        init(
            navigation: MarkdownEditorNavigation,
            performTableCommand: @escaping (TableCommandDefinition) -> Void
        ) {
            self.navigation = navigation
            self.performTableCommand = performTableCommand
            self.commands = Self.savedCommands()
        }

        func update(
            navigation: MarkdownEditorNavigation,
            availableTableCommands: Set<MarkdownEditingCommand>,
            currentAlignment: MarkdownTableAlignment?,
            performTableCommand: @escaping (TableCommandDefinition) -> Void
        ) {
            self.navigation = navigation
            self.performTableCommand = performTableCommand
            let changed = self.availableTableCommands != availableTableCommands
                || self.currentAlignment != currentAlignment
            self.availableTableCommands = availableTableCommands
            self.currentAlignment = currentAlignment
            guard changed else { return }
            if collectionView?.hasActiveDrag == true {
                needsReloadAfterDrag = true
            } else {
                collectionView?.reloadData()
            }
        }

        func collectionView(
            _ collectionView: UICollectionView, numberOfItemsInSection section: Int
        ) -> Int {
            commands.count
        }

        func collectionView(
            _ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath
        ) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: "command", for: indexPath
            ) as! KeyboardToolbarCell
            let definition = commands[indexPath.item]
            cell.configure(
                image: definition.image,
                title: String(localized: definition.title),
                identifier: definition.command == .insertTable
                    ? "editor-table-menu" : definition.command.accessibilityIdentifier,
                color: .label,
                selected: false,
                enabled: definition.command != .insertTable
                    || availableTableCommands.contains(.insertTable)
                    || availableTableCommands.contains(.tableNextCell),
                action: { [weak self] in
                    self?.navigation.performCommand?(definition.command)
                },
                moveLeft: { [weak self] in
                    self?.move(definition.id, by: -1) ?? false
                },
                moveRight: { [weak self] in
                    self?.move(definition.id, by: 1) ?? false
                }
            )
            if definition.command == .insertTable,
               availableTableCommands.contains(.tableNextCell) {
                cell.configureTableMenu(makeTableMenu())
            }
            return cell
        }

        func collectionView(
            _ collectionView: UICollectionView,
            layout collectionViewLayout: UICollectionViewLayout,
            sizeForItemAt indexPath: IndexPath
        ) -> CGSize {
            CGSize(width: 44, height: 44)
        }

        private func makeTableMenu() -> UIMenu {
            let groups = TableCommandDefinition.groups
            // Short submenus keep every operation reachable above the keyboard,
            // including at accessibility text sizes.
            return UIMenu(children: [
                UIMenu(
                    title: String(localized: "Row"),
                    image: UIImage(systemName: "rectangle.split.1x2"),
                    children: [
                        UIMenu(options: .displayInline, children: groups[1].map(makeTableAction)),
                        makeTableAction(groups[5][0]),
                    ]
                ),
                UIMenu(
                    title: String(localized: "Column"),
                    image: UIImage(systemName: "rectangle.split.2x1"),
                    children: [
                        UIMenu(options: .displayInline, children: groups[2].map(makeTableAction)),
                        makeTableAction(groups[5][1]),
                    ]
                ),
                UIMenu(
                    title: String(localized: "Column Alignment"),
                    image: UIImage(systemName: "text.alignleft"),
                    children: groups[3].map(makeTableAction)
                ),
                UIMenu(options: .displayInline, children: groups[4].map(makeTableAction)),
            ])
        }

        private func makeTableAction(_ definition: TableCommandDefinition) -> UIAction {
            var attributes: UIMenuElement.Attributes = []
            if !availableTableCommands.contains(definition.command) {
                attributes.insert(.disabled)
            }
            if definition.isDestructive { attributes.insert(.destructive) }
            return UIAction(
                title: String(localized: definition.title),
                image: UIImage(systemName: definition.image),
                identifier: UIAction.Identifier(definition.command.accessibilityIdentifier),
                attributes: attributes,
                state: definition.alignment != nil
                    && definition.alignment == currentAlignment ? .on : .off
            ) { [weak self] _ in
                self?.performTableCommand(definition)
            }
        }

        func collectionView(
            _ collectionView: UICollectionView,
            itemsForBeginning session: UIDragSession, at indexPath: IndexPath
        ) -> [UIDragItem] {
            let definition = commands[indexPath.item]
            // Native insertion previews temporarily shift cells during a drag.
            // Retain their original geometry for a stable drop decision.
            let content = CGRect(origin: .zero, size: collectionView.contentSize)
            dragItemFrames = collectionView.collectionViewLayout
                .layoutAttributesForElements(in: content)?
                .filter { $0.representedElementCategory == .cell }
                .map { (index: $0.indexPath.item, frame: $0.frame) } ?? []
            let item = UIDragItem(itemProvider: NSItemProvider(object: definition.id as NSString))
            item.localObject = definition.id
            return [item]
        }

        func collectionView(
            _ collectionView: UICollectionView,
            dragPreviewParametersForItemAt indexPath: IndexPath
        ) -> UIDragPreviewParameters? {
            previewParameters(at: indexPath)
        }

        func collectionView(
            _ collectionView: UICollectionView,
            dropPreviewParametersForItemAt indexPath: IndexPath
        ) -> UIDragPreviewParameters? {
            previewParameters(at: indexPath)
        }

        private func previewParameters(at indexPath: IndexPath) -> UIDragPreviewParameters? {
            guard commands.indices.contains(indexPath.item)
            else { return nil }
            let definition = commands[indexPath.item]
            let parameters = UIDragPreviewParameters()
            parameters.backgroundColor = .clear
            if definition.command == .insertTable {
                guard let cell = collectionView?.cellForItem(at: indexPath) else { return nil }
                parameters.visiblePath = UIBezierPath(roundedRect: cell.bounds, cornerRadius: 8)
                return parameters
            }
            parameters.visiblePath = UIBezierPath(cgPath: SymbolDragPreviewShape(
                systemName: definition.image
            ).path(in: CGRect(x: 0, y: 0, width: 44, height: 44)).cgPath)
            return parameters
        }

        func collectionView(
            _ collectionView: UICollectionView,
            dropSessionDidUpdate session: UIDropSession,
            withDestinationIndexPath destinationIndexPath: IndexPath?
        ) -> UICollectionViewDropProposal {
            guard let id = session.localDragSession?.items.first?.localObject as? String,
                  commands.contains(where: { $0.id == id }) else {
                return UICollectionViewDropProposal(operation: .forbidden)
            }
            return UICollectionViewDropProposal(
                operation: .move, intent: .insertAtDestinationIndexPath
            )
        }

        func collectionView(
            _ collectionView: UICollectionView,
            performDropWith coordinator: UICollectionViewDropCoordinator
        ) {
            guard let item = coordinator.items.first,
                  let id = item.dragItem.localObject as? String,
                  let source = commands.firstIndex(where: { $0.id == id })
            else { return }
            let location = coordinator.session.location(in: collectionView)
            let nearest = dragItemFrames.filter { $0.index != source }.min {
                abs($0.frame.midX - location.x) < abs($1.frame.midX - location.x)
            }
            let insertion = nearest.map {
                $0.index + (location.x > $0.frame.midX ? 1 : 0)
            } ?? source
            // A wider label can leave UIKit's proposed index at the source,
            // and item gaps can have no proposed index. Commit the insertion
            // position under the finger using the actual visible cell geometry.
            let targetPosition = insertion > source ? insertion - 1 : insertion
            let destination = min(max(targetPosition, 0), commands.count - 1)
            let target = destination
            if source != target {
                let command = commands.remove(at: source)
                commands.insert(command, at: target)
                collectionView.performBatchUpdates {
                    collectionView.moveItem(
                        at: IndexPath(item: source, section: 0),
                        to: IndexPath(item: destination, section: 0)
                    )
                }
                saveOrder()
            }
            coordinator.drop(
                item.dragItem, toItemAt: IndexPath(item: destination, section: 0)
            )
        }

        func collectionView(
            _ collectionView: UICollectionView, dragSessionDidEnd session: UIDragSession
        ) {
            dragItemFrames = []
            guard needsReloadAfterDrag else { return }
            needsReloadAfterDrag = false
            collectionView.reloadData()
        }

        private func move(_ id: String, by offset: Int) -> Bool {
            guard let source = commands.firstIndex(where: { $0.id == id }),
                  commands.indices.contains(source + offset),
                  let collectionView else { return false }
            let target = source + offset
            let command = commands.remove(at: source)
            commands.insert(command, at: target)
            collectionView.performBatchUpdates {
                collectionView.moveItem(
                    at: IndexPath(item: source, section: 0),
                    to: IndexPath(item: target, section: 0)
                )
            }
            saveOrder()
            return true
        }

        private func saveOrder() {
            UserDefaults.standard.set(commands.map(\.id), forKey: Self.orderDefaultsKey)
        }

        private static func savedCommands() -> [KeyboardCommandDefinition] {
            let ids = KeyboardCommandDefinition.all.map(\.id)
            let saved = UserDefaults.standard.stringArray(forKey: orderDefaultsKey) ?? []
            var retained: [String] = []
            for id in saved where ids.contains(id) && !retained.contains(id) {
                retained.append(id)
            }
            let order = retained + ids.filter { !retained.contains($0) }
            return order.compactMap { id in
                KeyboardCommandDefinition.all.first { $0.id == id }
            }
        }
    }
}

private final class KeyboardToolbarCell: UICollectionViewCell {
    private let button = KeyboardToolbarButton(type: .custom)
    private var action: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        button.translatesAutoresizingMaskIntoConstraints = false
        button.backgroundColor = .clear
        button.addTarget(self, action: #selector(activate), for: .touchUpInside)
        contentView.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(
        image: String, title: String, identifier: String, color: UIColor,
        selected: Bool, enabled: Bool = true, action: @escaping () -> Void,
        moveLeft: (() -> Bool)? = nil, moveRight: (() -> Bool)? = nil
    ) {
        self.action = action
        button.isEnabled = enabled
        button.configuration = nil
        button.menu = nil
        button.isContextMenuInteractionEnabled = false
        button.showsMenuAsPrimaryAction = false
        button.setTitle(nil, for: .normal)
        button.setImage(UIImage(systemName: image)?.withConfiguration(
            UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        ), for: .normal)
        button.tintColor = color
        button.accessibilityLabel = title
        button.accessibilityIdentifier = identifier
        button.accessibilityTraits = selected ? [.button, .selected] : .button
        var actions: [UIAccessibilityCustomAction] = []
        if let moveLeft {
            actions.append(UIAccessibilityCustomAction(
                name: String(localized: "Move Left")
            ) { _ in
                moveLeft()
            })
        }
        if let moveRight {
            actions.append(UIAccessibilityCustomAction(
                name: String(localized: "Move Right")
            ) { _ in
                moveRight()
            })
        }
        button.accessibilityCustomActions = actions
    }

    func configureTableMenu(_ menu: UIMenu) {
        action = nil
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "tablecells")
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: 18, weight: .regular
        )
        configuration.contentInsets = .zero
        configuration.baseForegroundColor = .label
        button.setImage(nil, for: .normal)
        button.configuration = configuration
        button.menu = menu
        button.isContextMenuInteractionEnabled = false
        button.accessibilityLabel = String(localized: "Table")
        button.accessibilityIdentifier = "editor-table-menu"
    }

    @objc private func activate() {
        if button.menu != nil {
            button.openMenu()
        } else {
            action?()
        }
    }
}

private final class KeyboardToolbarButton: UIButton {
    func openMenu() {
        guard !showsMenuAsPrimaryAction else { return }
        // A primary menu normally opens on touch-down, consuming the long
        // press used to reorder toolbar items. Open after touch-up instead.
        isContextMenuInteractionEnabled = true
        showsMenuAsPrimaryAction = true
        performPrimaryAction()
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willEndFor configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
        showsMenuAsPrimaryAction = false
        isContextMenuInteractionEnabled = false
    }
}

extension MarkdownTextView {
    func installMarkdownKeyboardToolbar(navigation: MarkdownEditorNavigation?) {
        let commands = navigation ?? MarkdownEditorNavigation()
        if navigation == nil {
            commands.performCommand = { [weak self] command in
                _ = self?.performMarkdownCommand(command)
            }
            commands.prepareCommand = { [weak self] command in
                self?.preparedMarkdownCommand(command)
            }
        }
        inputAccessoryView = MarkdownKeyboardAccessoryView(
            navigation: commands, width: bounds.width
        )
    }
}

private final class MarkdownKeyboardAccessoryView: UIView {
    init(navigation: MarkdownEditorNavigation, width: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: 58))
        autoresizingMask = [.flexibleWidth]
        backgroundColor = .clear
        let hosted = UIHostingConfiguration {
            EditorKeyboardToolbar(navigation: navigation)
        }
        .margins(.all, 0)
        .background(.clear)
        .makeContentView()
        hosted.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosted)
        NSLayoutConstraint.activate([
            hosted.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosted.topAnchor.constraint(equalTo: topAnchor),
            hosted.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }
}

#endif
