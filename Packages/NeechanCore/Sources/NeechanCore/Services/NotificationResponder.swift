#if canImport(UserNotifications)
import Foundation
import Observation
import UserNotifications

/// Answers the notification centre: what a banner does while the app is in
/// front, and where a tapped one leads.
///
/// Without a delegate the centre drops every banner that arrives while the app
/// is open and a tap does nothing but bring the app forward, which is how the
/// watcher's banners behaved until this existed.
@MainActor
@Observable
public final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate {
    /// Where a tapped banner asked to go, waiting for the shell to take it
    /// there. The shell clears it once it has.
    public var pendingTarget: NavigationTarget?

    /// The thread the reader is looking at, if any. Supplied by the shell,
    /// which owns the navigation.
    @ObservationIgnored
    public var threadInFront: @MainActor () -> ThreadKey? = { nil }

    override public init() {
        super.init()
    }

    /// Takes the centre's calls from now on.
    ///
    /// Must happen before the app finishes launching: the tap that launched it
    /// is handed to whichever delegate is set by then, and to nobody after.
    /// Does nothing in a process with no app bundle, where the centre traps.
    public func install() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let payload = NotificationPayload(userInfo: notification.request.content.userInfo)
        return await presentation(for: payload)
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard
            response.actionIdentifier == UNNotificationDefaultActionIdentifier,
            let payload = NotificationPayload(
                userInfo: response.notification.request.content.userInfo
            )
        else { return }
        await open(payload)
    }

    private func presentation(for payload: NotificationPayload?) -> UNNotificationPresentationOptions {
        // The thread is already in front of the reader, whose own refresh says
        // what arrived; a banner over it would only say it twice. It is still
        // listed, and cleared when they leave the thread.
        if let payload, payload.key == threadInFront() {
            return [.list]
        }
        return [.banner, .list, .sound]
    }

    private func open(_ payload: NotificationPayload) {
        pendingTarget = payload.target
    }
}
#endif
