import Foundation

/// When the app should ask who is holding the device.
///
/// A value on its own so the rule can be reasoned about and tested without a
/// device, a face or a scene: everything here is arithmetic on instants.
///
/// Measured on a `ContinuousClock` rather than in dates. A date moves when the
/// network corrects the clock, when the timezone changes and when somebody sets
/// it by hand, which is also the easy way to walk past a grace period. Instants
/// are never written down: their epoch resets when the device reboots, and a
/// launch asks anyway.
struct AppLockPolicy: Equatable {
    enum Phase: Equatable {
        case unlocked
        /// Hidden. `isAsking` while the device's own prompt is up.
        case locked(isAsking: Bool)
    }

    /// What coming back to the front should do.
    enum Activation: Equatable {
        case doNothing
        case authenticate
    }

    private(set) var isEnabled: Bool
    private(set) var phase: Phase
    /// How long the app may be away before it asks again.
    let grace: Duration
    /// When the app went away, if it has since the last unlock.
    private var armedAt: ContinuousClock.Instant?
    /// A launch is answered for once, before anything has been armed.
    private var owesColdLaunch: Bool

    init(isEnabled: Bool, grace: Duration = .seconds(60)) {
        self.isEnabled = isEnabled
        self.grace = grace
        // Locked before the first frame when it is on, which is what makes a
        // cold launch show nothing until somebody has answered for it.
        self.phase = isEnabled ? .locked(isAsking: false) : .unlocked
        self.owesColdLaunch = isEnabled
    }

    var isLocked: Bool { phase != .unlocked }

    var isAsking: Bool { phase == .locked(isAsking: true) }

    /// Follows the switch in settings.
    ///
    /// Turning it on does not hide the app from the reader who just turned it
    /// on: they are holding the device and looking at it. It takes effect the
    /// next time they leave for long enough.
    mutating func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        phase = .unlocked
        armedAt = nil
        owesColdLaunch = false
    }

    /// The app left the screen.
    ///
    /// The only thing that arms the lock, which is what keeps Control Centre, a
    /// permission alert and the device's own prompt from locking the app behind
    /// themselves: those make the app inactive without ever backgrounding it.
    mutating func didEnterBackground(at instant: ContinuousClock.Instant) {
        guard isEnabled, phase == .unlocked else { return }
        armedAt = instant
    }

    /// The app came back to the front.
    mutating func didBecomeActive(at instant: ContinuousClock.Instant) -> Activation {
        guard isEnabled else {
            phase = .unlocked
            return .doNothing
        }
        // The prompt itself bounces the app through inactive and back. Asking
        // again here is how a prompt becomes two prompts.
        guard !isAsking else { return .doNothing }

        if owesColdLaunch {
            owesColdLaunch = false
            phase = .locked(isAsking: false)
            return .authenticate
        }

        guard let armedAt else { return .doNothing }
        let away = armedAt.duration(to: instant)
        self.armedAt = nil

        // A clock that went backwards is a clock that has been played with, so
        // this fails closed.
        guard away < .zero || away >= grace else { return .doNothing }
        phase = .locked(isAsking: false)
        return .authenticate
    }

    mutating func authenticationBegan() {
        phase = .locked(isAsking: true)
    }

    mutating func authenticationSucceeded() {
        phase = .unlocked
        armedAt = nil
    }

    /// The attempt ended without unlocking: cancelled, failed, or torn down.
    ///
    /// Stays locked and does not ask again by itself. The lock screen offers
    /// the way back, because an attempt that restarts itself is a prompt the
    /// reader cannot get out of.
    mutating func authenticationFailed() {
        phase = .locked(isAsking: false)
    }

    /// The device cannot ask anyone anything: no passcode is set.
    ///
    /// Fails open. A lock that cannot be opened is not a locked app, it is a
    /// lost one.
    mutating func cannotAuthenticate() {
        setEnabled(false)
    }
}
