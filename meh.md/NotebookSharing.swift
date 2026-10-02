import SwiftUI

#if os(iOS)
import UIKit

struct NotebookShareSheet: UIViewControllerRepresentable {
    let file: NotebookSharedFile
    let onFinish: @MainActor () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [file.url], applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, _, _, _ in
            Task { @MainActor in onFinish() }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#else
import AppKit

/// Anchored in the note toolbar, so sharing belongs to the originating window.
struct NotebookSharePicker: NSViewRepresentable {
    @Binding var file: NotebookSharedFile?
    let onFinish: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(file: $file, onFinish: onFinish)
    }
    func makeNSView(context: Context) -> NSView { NSView() }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        // History or navigation can remove the toolbar while a non-modal
        // service is active. Release its presentation state in that case.
        coordinator.picker?.delegate = nil
        coordinator.picker?.close()
        coordinator.service?.delegate = nil
        coordinator.finish()
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.file = $file
        context.coordinator.onFinish = onFinish
        guard let file, context.coordinator.presentedID != file.id else { return }
        context.coordinator.presentedID = file.id
        let picker = NSSharingServicePicker(items: [file.url])
        picker.delegate = context.coordinator
        context.coordinator.picker = picker
        // Allow the menu to dismiss before presenting its sharing picker.
        DispatchQueue.main.async {
            guard view.window != nil else {
                context.coordinator.finish()
                return
            }
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }

    final class Coordinator: NSObject, NSSharingServicePickerDelegate,
                             NSSharingServiceDelegate {
        var file: Binding<NotebookSharedFile?>
        var onFinish: @MainActor () -> Void
        var presentedID: UUID?
        var picker: NSSharingServicePicker?
        var service: NSSharingService?

        init(file: Binding<NotebookSharedFile?>,
             onFinish: @escaping @MainActor () -> Void) {
            self.file = file
            self.onFinish = onFinish
        }

        func sharingServicePicker(_ picker: NSSharingServicePicker,
                                  didChoose service: NSSharingService?) {
            guard picker === self.picker else { return }
            if service == nil { finish() }
        }

        func sharingServicePicker(_ picker: NSSharingServicePicker,
                                  delegateFor service: NSSharingService)
            -> (any NSSharingServiceDelegate)? {
            guard picker === self.picker else { return nil }
            self.service = service
            return self
        }

        func sharingService(_ service: NSSharingService, didShareItems items: [Any]) {
            guard service === self.service else { return }
            finish()
        }

        func sharingService(_ service: NSSharingService,
                            didFailToShareItems items: [Any], error: any Error) {
            guard service === self.service else { return }
            finish()
        }

        func finish() {
            guard let id = presentedID else { return }
            // Native callbacks can run during dismissal. Resume queued imports
            // after they return, without clearing a newer sharing request.
            DispatchQueue.main.async {
                guard self.presentedID == id else { return }
                self.presentedID = nil
                self.picker = nil
                self.service = nil
                if self.file.wrappedValue?.id == id {
                    self.file.wrappedValue = nil
                }
                self.onFinish()
            }
        }
    }
}
#endif
