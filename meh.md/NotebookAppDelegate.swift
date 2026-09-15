import Foundation
import NoteCore

#if os(iOS)
import UIKit

@MainActor
final class NotebookAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [
            UIApplication.LaunchOptionsKey: Any
        ]? = nil
    ) -> Bool {
        guard RemoteNotificationLaunch.isEnabled else { return true }
        NotebookWorkspace.shared.sceneActivityChanged(
            isActive: application.applicationState != .background
        )
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

        #if ICLOUD_DEV
        return true
        #elseif DEBUG
        return environment["MEH_SYNC_CLOUDKIT"] == "1"
        #else
        return false
        #endif
    }
}
