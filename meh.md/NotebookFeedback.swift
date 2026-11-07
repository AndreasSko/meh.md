import NoteCore
import StoreKit
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
    static var versionLine: String { appVersion + "; " + osVersion }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        return "meh.md \(version) (\(build))"
    }

    static var osVersion: String {
        #if os(macOS)
        let platform = "macOS"
        #else
        let platform = "iOS"
        #endif
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(platform) \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }

    /// The hardware model, such as "iPhone13,4".
    static var deviceModel: String {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "Simulator"
        #else
        #if os(macOS)
        let key = "hw.model"
        #else
        let key = "hw.machine"
        #endif
        var size = 0
        sysctlbyname(key, nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname(key, &model, &size, nil, 0)
        return String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #endif
    }

    /// Where this copy of the app came from, or nil when StoreKit can't tell.
    static func installSource() async -> String? {
        #if DEBUG
        return "Development"
        #else
        guard let result = try? await AppTransaction.shared else { return nil }
        let transaction: AppTransaction
        switch result {
        case .verified(let value), .unverified(let value, _): transaction = value
        }
        switch transaction.environment {
        case .production: return "App Store"
        case .sandbox: return "TestFlight"
        default: return nil
        }
        #endif
    }

    static func logText(_ log: NotebookSyncEventLog) -> String {
        versionLine + "\n" + log.exportText
    }

    /// Kept readable in the mail body, so people see what they send.
    static func body(storage: NotebookSyncStorage, source: String?) -> String {
        "\n\n\n" + [
            ([appVersion] + [source].compactMap { $0 }).joined(separator: " · "),
            osVersion + " · " + deviceModel,
            "Sync: " + storage.title,
        ].joined(separator: "\n")
    }

    /// Opens the default mail app. Links can't carry attachments, so the log
    /// is left out.
    static func mailtoURL(body: String) -> URL {
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
    let storage: NotebookSyncStorage
    @Environment(\.openURL) private var openURL
    @State private var source: String?
    #if os(iOS)
    @State private var anchor = NotebookMailAnchor()
    #endif

    var body: some View {
        Section {
            Button("Send Feedback") { sendFeedback() }
                .accessibilityIdentifier("notebook-send-feedback")
                #if os(iOS)
                .background(NotebookMailAnchorView(anchor: anchor))
                #endif
            Link("About meh.md", destination: NotebookFeedback.aboutURL)
            Link("Privacy Policy", destination: NotebookFeedback.privacyURL)
            NavigationLink("Open Source Licenses") { NotebookLicensesView() }
                .accessibilityIdentifier("notebook-licenses-settings")
        } footer: {
            Text("If your mail app allows it, feedback includes the sync event log. It contains no note contents or names.")
        }
        .task { source = await NotebookFeedback.installSource() }
    }

    private func sendFeedback() {
        let body = NotebookFeedback.body(storage: storage, source: source)
        #if os(macOS)
        if let service = NSSharingService(named: .composeEmail),
           let file = try? NotebookFeedback.logFile(log) {
            service.recipients = [NotebookFeedback.address]
            service.subject = NotebookFeedback.subject
            let items: [Any] = [body, file]
            if service.canPerform(withItems: items) {
                service.perform(withItems: items)
                return
            }
        }
        #else
        if NotebookMailComposer.present(log: log, body: body, from: anchor.view) { return }
        #endif
        openURL(NotebookFeedback.mailtoURL(body: body))
    }
}

#if os(iOS)
/// Remembers a view in the Settings window, so the mail sheet opens in that
/// window when an iPad shows several.
@MainActor
private final class NotebookMailAnchor {
    weak var view: UIView?
}

private struct NotebookMailAnchorView: UIViewRepresentable {
    let anchor: NotebookMailAnchor

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        anchor.view = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        anchor.view = view
    }
}

/// Presents Apple's mail sheet from UIKit instead of a SwiftUI sheet inside
/// the Settings form, where it closed again right away on an iPhone.
@MainActor
private final class NotebookMailComposer: NSObject, MFMailComposeViewControllerDelegate {
    // The controller holds its delegate weakly, so each open composer's
    // delegate is kept here until it finishes.
    private static var open: [NotebookMailComposer] = []
    private weak var composer: MFMailComposeViewController?

    static func present(log: NotebookSyncEventLog, body: String, from view: UIView?) -> Bool {
        guard MFMailComposeViewController.canSendMail(),
              var presenter = view?.window?.rootViewController else { return false }
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        // Mid-transition, such as a double tap: ignore the tap rather than
        // also opening the mailto fallback.
        guard !presenter.isBeingDismissed, !presenter.isBeingPresented else { return true }
        let controller = MFMailComposeViewController()
        let delegate = NotebookMailComposer()
        delegate.composer = controller
        open.append(delegate)
        controller.mailComposeDelegate = delegate
        controller.setToRecipients([NotebookFeedback.address])
        controller.setSubject(NotebookFeedback.subject)
        controller.setMessageBody(body, isHTML: false)
        controller.addAttachmentData(
            Data(NotebookFeedback.logText(log).utf8),
            mimeType: "text/plain", fileName: "meh.md Sync Log.txt"
        )
        presenter.present(controller, animated: true)
        return true
    }

    nonisolated func mailComposeController(
        _ controller: MFMailComposeViewController,
        didFinishWith result: MFMailComposeResult, error: (any Error)?
    ) {
        Task { @MainActor in
            self.composer?.dismiss(animated: true)
            Self.open.removeAll { $0 === self }
        }
    }
}
#endif
