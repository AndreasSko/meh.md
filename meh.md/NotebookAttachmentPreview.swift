import SwiftUI

#if os(macOS)
import Quartz

/// Quick Look owns rendering, including its fallback for unsupported formats.
struct NotebookAttachmentPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard (view.previewItem?.previewItemURL ?? nil) != url else { return }
        view.previewItem = url as NSURL
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}
#else
import QuickLook

/// Embeds Quick Look in the detail pane without presenting another sheet.
struct NotebookAttachmentPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        controller.view.accessibilityIdentifier = "notebook-attachment-content"
        return controller
    }

    func updateUIViewController(
        _ controller: QLPreviewController, context: Context
    ) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        controller.reloadData()
    }

    static func dismantleUIViewController(
        _ controller: QLPreviewController, coordinator: Coordinator
    ) {
        controller.delegate = nil
        controller.dataSource = nil
    }

    final class Coordinator: NSObject,
                             QLPreviewControllerDataSource,
                             QLPreviewControllerDelegate {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(
            _ controller: QLPreviewController, previewItemAt index: Int
        ) -> any QLPreviewItem {
            url as NSURL
        }

        func previewController(
            _ controller: QLPreviewController,
            editingModeFor previewItem: any QLPreviewItem
        ) -> QLPreviewItemEditingMode {
            .disabled
        }
    }
}
#endif
