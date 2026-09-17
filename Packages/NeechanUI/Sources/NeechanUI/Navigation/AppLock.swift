import Foundation
import NeechanAPI
import NeechanSettings
import Observation
import SwiftUI

/// Keeps the app's contents to the person who can answer for the device.
///
/// Holds the rule (`AppLockPolicy`), the thing that asks (`DeviceAuthenticator`)
/// and the attempt in flight. Built with the app rather than by a view, because
/// a launch has to be locked before the first frame is drawn, and that means
/// reading the setting before there is a view to read it from.
@MainActor
@Observable
public final class AppLock {
    private var policy: AppLockPolicy
    private let authenticator: any DeviceAuthenticator
    /// The attempt in flight, so a second one cannot start beside it.
    private var attempt: Task<Void, Never>?
    /// Set when the device turns out to have no way of asking, so the switch in
    /// settings can be put back where it belongs.
    public private(set) var didGiveUp = false

    /// Whether the app's contents are hidden.
    public var isLocked: Bool { policy.isLocked }

    /// Whether the device's own prompt is up.
    public var isAsking: Bool { policy.isAsking }

    /// Whether the app is covered, either locked or merely off screen.
    ///
    /// The cover follows the screen and the lock follows the reader: they are
    /// separate on purpose, because the app is made inactive by things that are
    /// not the reader leaving, such as pulling down Control Centre.
    public private(set) var isCovered = false

    init(isEnabled: Bool, authenticator: any DeviceAuthenticator, grace: Duration = .seconds(60)) {
        self.policy = AppLockPolicy(isEnabled: isEnabled, grace: grace)
        self.authenticator = authenticator
    }

    public convenience init(isEnabled: Bool) {
        self.init(isEnabled: isEnabled, authenticator: LocalDeviceAuthenticator())
    }

    /// Follows the switch in settings.
    public func setEnabled(_ enabled: Bool) {
        policy.setEnabled(enabled)
        if !enabled { isCovered = false }
        didGiveUp = false
    }

    /// Whether the device can ask anybody anything.
    ///
    /// False on a device with no passcode, where the switch is no use.
    public func canLock() -> Bool {
        authenticator.canAuthenticate()
    }

    // MARK: The screen coming and going

    public func sceneBecameActive() {
        isCovered = policy.isLocked
        guard policy.didBecomeActive(at: .now) == .authenticate else { return }
        isCovered = true
        authenticate()
    }

    /// The app is no longer the thing on screen.
    ///
    /// Covers, but never locks: this is also what a permission alert, the share
    /// sheet and the device's own prompt do.
    public func sceneBecameInactive() {
        guard policy.isEnabled else { return }
        isCovered = true
    }

    /// The app left the screen. The only thing that starts the clock.
    public func sceneEnteredBackground() {
        guard policy.isEnabled else { return }
        isCovered = true
        policy.didEnterBackground(at: .now)
        // A prompt left up over an app nobody is looking at would come back as
        // a prompt over a lock screen.
        if policy.isAsking {
            authenticator.cancel()
        }
    }

    // MARK: Asking

    /// Asks the device who is holding it, unless it is already asking.
    public func authenticate() {
        guard policy.isLocked, !policy.isAsking else { return }
        policy.authenticationBegan()

        attempt = Task { [weak self, authenticator] in
            let reason = String(
                localized: "Unlock Neechan",
                bundle: .module,
                locale: AppLocale.current
            )
            let outcome = await authenticator.authenticate(reason: reason)
            guard let self else { return }
            self.finish(outcome)
        }
    }

    private func finish(_ outcome: AuthenticationOutcome) {
        attempt = nil
        switch outcome {
        case .unlocked:
            policy.authenticationSucceeded()
            isCovered = false
        case .cancelled, .rejected:
            policy.authenticationFailed()
        case .unavailable:
            // Nothing on this device can answer, so the app opens rather than
            // stranding whoever owns it.
            policy.cannotAuthenticate()
            isCovered = false
            didGiveUp = true
        }
    }
}
