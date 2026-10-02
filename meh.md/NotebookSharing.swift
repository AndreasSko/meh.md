import SwiftUI

#if os(iOS)
import UIKit

struct NotebookShareSheet: UIViewControllerRepresentable {
    let file: NotebookSharedFile

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#else
import AppKit

/// Anchored in the note toolbar, so sharing belongs to the originating window.
struct NotebookSharePicker: NSViewRepresentable {
    @Binding var file: NotebookSharedFile?

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard let file, context.coordinator.presentedID != file.id else { return }
        context.coordinator.presentedID = file.id
        let picker = NSSharingServicePicker(items: [file.url])
        context.coordinator.picker = picker
        // Allow the menu to dismiss before presenting its sharing picker.
        DispatchQueue.main.async {
            guard view.window != nil else { return }
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }

    final class Coordinator {
        var presentedID: UUID?
        var picker: NSSharingServicePicker?
    }
}
#endif
