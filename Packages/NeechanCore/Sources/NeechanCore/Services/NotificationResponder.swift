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

    /// The completion-handler form on purpose, not the async one.
    ///
    /// UIKit's handler for a tap must be called on the main thread. The async
    /// form calls it from wherever its task finishes, which after the hop to
    /// the main actor and back is the cooperative pool, and the app crashed
    /// every time a banner was tapped.
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let payload = response.actionIdentifier == UNNotificationDefaultActionIdentifier
            ? NotificationPayload(userInfo: response.notification.request.content.userInfo)
            : nil
        handleResponse(payload, completion: completionHandler)
    }

    /// Takes a tapped banner where it leads, then answers the centre, both on
    /// the main thread whatever thread this is called from.
    ///
    /// - Parameter payload: what the banner carried, or nil when it was
    ///   dismissed, or was a tap that names no thread.
    nonisolated func handleResponse(
        _ payload: NotificationPayload?,
        completion: @escaping () -> Void
    ) {
        // Not Sendable as imported, but only ever called once, on main.
        nonisolated(unsafe) let completion = completion
        Task { @MainActor in
            if let payload { open(payload) }
            completion()
        }
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
