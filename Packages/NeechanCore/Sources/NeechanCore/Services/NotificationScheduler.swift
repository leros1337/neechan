#if canImport(UserNotifications)
import Foundation
import NeechanSettings
import UserNotifications

/// Tells the reader about new posts in watched threads.
public actor NotificationScheduler {
    /// Grouping identifier, so several threads collapse into one stack.
    private static let threadCategory = "neechan.watcher"

    /// Resolved on first use, not at construction.
    ///
    /// `UNUserNotificationCenter.current()` traps in a process with no app
    /// bundle, which is exactly how the package tests run, and building the
    /// app's services must not depend on being inside an app.
    private var resolvedCenter: UNUserNotificationCenter?
    private var hasResolved = false

    public init() {}

    private func center() -> UNUserNotificationCenter? {
        if hasResolved { return resolvedCenter }
        hasResolved = true
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        resolvedCenter = UNUserNotificationCenter.current()
        return resolvedCenter
    }

    /// Asks once, when the reader first turns notifications on.
    @discardableResult
    public func requestAuthorization() async -> Bool {
        guard let center = center() else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    public func isAuthorized() async -> Bool {
        guard let center = center() else { return false }
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
    }

    /// Posts a notification for each thread that gained posts.
    ///
    /// Nothing is scheduled when the setting is off, and nothing is scheduled
    /// for a thread with no news, so a quiet poll stays quiet.
    public func notify(
        about results: [ThreadWatcher.Result],
        titles: [ThreadKey: String],
        setting: WatcherNotificationSetting
    ) async {
        guard setting != .off else { return }
        guard let center = center(), await isAuthorized() else { return }

        for result in results where result.hasNews {
            let content = UNMutableNotificationContent()
            content.title = titles[result.key] ?? "/\(result.key.board)/\(result.key.threadNum)"
            content.body = String(
                localized: "\(result.newPostCount) new posts",
                bundle: .module
            )
            content.sound = .default
            content.threadIdentifier = Self.threadCategory
            // Carried so tapping the notification can open the right thread.
            content.userInfo = [
                "site": result.key.site.rawValue,
                "board": result.key.board,
                "threadNum": result.key.threadNum,
            ]

            let request = UNNotificationRequest(
                // Qualified by the site: two imageboards' /b/12345 are two
                // threads, and one banner must not replace the other's.
                identifier: result.key.identifier,
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }

    /// Clears a thread's notification once it has been opened.
    public func clearNotification(for key: ThreadKey) {
        center()?.removeDeliveredNotifications(
            withIdentifiers: [
                key.identifier,
                // The unqualified name banners were delivered under before
                // there were two sites. Without this a notification from an
                // older build would sit in Notification Centre for good.
                "\(key.board)-\(key.threadNum)",
            ]
        )
    }

    public func clearAll() {
        center()?.removeAllDeliveredNotifications()
    }
}
#endif
