import Foundation
import NoteCore

#if os(iOS)
import UIKit

@MainActor
final class NotebookAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil, sessionRole: connectingSceneSession.role
        )
        if connectingSceneSession.role == .windowApplication {
            configuration.delegateClass = NotebookShortcutSceneDelegate.self
        }
        return configuration
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [
            UIApplication.LaunchOptionsKey: Any
        ]? = nil
    ) -> Bool {
        NotebookBackupBackgroundScheduler.register()
        NotebookBackupBackgroundScheduler.scheduleNext()
        guard RemoteNotificationLaunch.isEnabled else { return true }
        Task { await NotebookWorkspace.shared.start() }
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        NotebookWorkspace.shared.remoteNotificationRegistrationDidSucceed()
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NotebookWorkspace.shared.remoteNotificationRegistrationDidFail(error)
    }

}

@MainActor
final class NotebookShortcutSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let shortcutItem = connectionOptions.shortcutItem {
            NotebookQuickActionRequests.shared.receive(shortcutItem)
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(NotebookQuickActionRequests.shared.receive(shortcutItem))
    }
}
#elseif os(macOS)
import AppKit

@MainActor
final class NotebookAppDelegate: NSObject, NSApplicationDelegate {
    private var isFlushingForTermination = false

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard !isFlushingForTermination else { return .terminateLater }
        isFlushingForTermination = true
        Task { @MainActor in
            do {
                try await NotebookWorkspace.shared.replica?.flushOpenNotes()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                isFlushingForTermination = false
                sender.reply(toApplicationShouldTerminate: false)
                sender.presentError(error)
            }
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard RemoteNotificationLaunch.isEnabled else { return }
        Task { await NotebookWorkspace.shared.start() }
        NSApplication.shared.registerForRemoteNotifications()
    }

    func application(
        _ application: NSApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        NotebookWorkspace.shared.remoteNotificationRegistrationDidSucceed()
    }

    func application(
        _ application: NSApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NotebookWorkspace.shared.remoteNotificationRegistrationDidFail(error)
    }

}
#endif

private enum RemoteNotificationLaunch {
    static var isEnabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MEH_SYNC_AUTOMATIC"] != "0" else { return false }

        #if ICLOUD_ENABLED
        return true
        #elseif DEBUG
        return environment["MEH_SYNC_CLOUDKIT"] == "1"
        #else
        return false
        #endif
    }
}
