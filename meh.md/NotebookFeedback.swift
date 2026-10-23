import NoteCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import MessageUI
#endif

enum NotebookFeedback {
    static let address = "meh@andreas-sk.de"
    static let aboutURL = URL(string: "https://github.com/AndreasSko/meh.md#readme")!
    static let privacyURL = URL(
        string: "https://github.com/AndreasSko/meh.md/blob/main/PRIVACY.md"
    )!
    static let subject = "meh.md Feedback"

    /// The app version, build and OS, as shown in Settings and sent with logs.
    static var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        #if os(macOS)
        let platform = "macOS"
        #else
        let platform = "iOS"
        #endif
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "meh.md \(version) (\(build)); "
            + "\(platform) \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }

    static func logText(_ log: NotebookSyncEventLog) -> String {
        versionLine + "\n" + log.exportText
    }

    static var body: String { "\n\n\n" + versionLine }

    /// Opens the default mail app. Links can't carry attachments, so the log
    /// is left out.
    static var mailtoURL: URL {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url!
    }

    static func logFile(_ log: NotebookSyncEventLog) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "meh.md Sync Log.txt")
        try Data(logText(log).utf8).write(to: url, options: .atomic)
        return url
    }
}

/// Feedback and links at the end of Settings.
struct NotebookFeedbackSection: View {
    let log: NotebookSyncEventLog
    @Environment(\.openURL) private var openURL
    #if os(iOS)
    @State private var composingMail = false
    #endif

    var body: some View {
        Section {
            Button("Send Feedback") { sendFeedback() }
                .accessibilityIdentifier("notebook-send-feedback")
            Link("About meh.md", destination: NotebookFeedback.aboutURL)
            Link("Privacy Policy", destination: NotebookFeedback.privacyURL)
        } footer: {
            Text("If your mail app allows it, feedback includes the sync event log. It contains no note contents or names.")
        }
        #if os(iOS)
        .sheet(isPresented: $composingMail) {
            NotebookMailComposer(log: log).ignoresSafeArea()
        }
        #endif
    }

    private func sendFeedback() {
        #if os(macOS)
        if let service = NSSharingService(named: .composeEmail),
           let file = try? NotebookFeedback.logFile(log) {
            service.recipients = [NotebookFeedback.address]
            service.subject = NotebookFeedback.subject
            let items: [Any] = [NotebookFeedback.body, file]
            if service.canPerform(withItems: items) {
                service.perform(withItems: items)
                return
            }
        }
        #else
        if MFMailComposeViewController.canSendMail() {
            composingMail = true
            return
        }
        #endif
        openURL(NotebookFeedback.mailtoURL)
    }
}

#if os(iOS)
private struct NotebookMailComposer: UIViewControllerRepresentable {
    let log: NotebookSyncEventLog
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients([NotebookFeedback.address])
        controller.setSubject(NotebookFeedback.subject)
        controller.setMessageBody(NotebookFeedback.body, isHTML: false)
        controller.addAttachmentData(
            Data(NotebookFeedback.logText(log).utf8),
            mimeType: "text/plain", fileName: "meh.md Sync Log.txt"
        )
        return controller
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let dismiss: DismissAction

        init(dismiss: DismissAction) { self.dismiss = dismiss }

        nonisolated func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult, error: (any Error)?
        ) {
            Task { @MainActor in self.dismiss() }
        }
    }
}
#endif
