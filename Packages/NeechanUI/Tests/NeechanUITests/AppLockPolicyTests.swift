import Foundation
import Testing
@testable import NeechanUI

/// When the app asks who is holding the device.
@Suite("App lock policy")
struct AppLockPolicyTests {
    private let start = ContinuousClock.now

    private func at(_ seconds: Int) -> ContinuousClock.Instant {
        start.advanced(by: .seconds(seconds))
    }

    @Test("with the lock on, the app starts hidden and asks once")
    func coldLaunchAsks() {
        var policy = AppLockPolicy(isEnabled: true)

        #expect(policy.isLocked, "a launch must not show anything before it has asked")
        #expect(policy.didBecomeActive(at: at(0)) == .authenticate)
    }

    @Test("with the lock off, nothing is hidden and nothing is asked")
    func disabledNeverAsks() {
        var policy = AppLockPolicy(isEnabled: false)

        #expect(policy.isLocked == false)
        #expect(policy.didBecomeActive(at: at(0)) == .doNothing)

        policy.didEnterBackground(at: at(1))

        #expect(policy.didBecomeActive(at: at(9999)) == .doNothing)
        #expect(policy.isLocked == false)
    }

    @Test("a short trip away comes straight back")
    func insideTheGrace() {
        var policy = unlocked()
        policy.didEnterBackground(at: at(0))

        #expect(policy.didBecomeActive(at: at(59)) == .doNothing)
        #expect(policy.isLocked == false)
    }

    @Test("a long trip away asks again")
    func pastTheGrace() {
        var policy = unlocked()
        policy.didEnterBackground(at: at(0))

        #expect(policy.didBecomeActive(at: at(61)) == .authenticate)
        #expect(policy.isLocked)
    }

    /// The minute itself belongs to the lock: away for exactly the grace is
    /// away long enough.
    @Test("the boundary counts as long enough")
    func exactlyTheGrace() {
        var policy = unlocked()
        policy.didEnterBackground(at: at(0))

        #expect(policy.didBecomeActive(at: at(60)) == .authenticate)
    }

    /// Control Centre, a permission alert and the share sheet all make the app
    /// inactive without backgrounding it.
    @Test("becoming active with nothing armed asks nothing")
    func inactiveWithoutBackground() {
        var policy = unlocked()

        #expect(policy.didBecomeActive(at: at(600)) == .doNothing)
        #expect(policy.isLocked == false)
    }

    @Test("turning the lock on does not hide the app from the reader who turned it on")
    func enabledMidSession() {
        var policy = AppLockPolicy(isEnabled: false)
        _ = policy.didBecomeActive(at: at(0))

        policy.setEnabled(true)

        #expect(policy.isLocked == false)

        policy.didEnterBackground(at: at(10))

        #expect(policy.didBecomeActive(at: at(200)) == .authenticate)
    }

    @Test("turning the lock off opens it")
    func disabledWhileLocked() {
        var policy = AppLockPolicy(isEnabled: true)
        _ = policy.didBecomeActive(at: at(0))
        #expect(policy.isLocked)

        policy.setEnabled(false)

        #expect(policy.isLocked == false)
        #expect(policy.didBecomeActive(at: at(1)) == .doNothing)
    }

    /// Setting the clock back is how somebody would try to walk past the grace.
    @Test("a clock that went backwards asks")
    func backwardsClock() {
        var policy = unlocked()
        policy.didEnterBackground(at: at(100))

        #expect(policy.didBecomeActive(at: at(40)) == .authenticate)
    }

    @Test("a prompt already up is not asked for twice")
    func noSecondPromptWhileAsking() {
        var policy = AppLockPolicy(isEnabled: true)
        _ = policy.didBecomeActive(at: at(0))
        policy.authenticationBegan()

        // The device's own prompt takes the app inactive and hands it back.
        #expect(policy.didBecomeActive(at: at(1)) == .doNothing)
        #expect(policy.isAsking)
    }

    /// An attempt that starts itself again is a prompt with no way out.
    @Test("a cancelled attempt stays locked and waits to be asked again")
    func cancelledStaysLocked() {
        var policy = AppLockPolicy(isEnabled: true)
        _ = policy.didBecomeActive(at: at(0))
        policy.authenticationBegan()
        policy.authenticationFailed()

        #expect(policy.isLocked)
        #expect(policy.isAsking == false)
        #expect(policy.didBecomeActive(at: at(2)) == .doNothing, "the bounce must not re-ask")
    }

    @Test("unlocking holds through a short trip away")
    func unlockingHolds() {
        var policy = AppLockPolicy(isEnabled: true)
        _ = policy.didBecomeActive(at: at(0))
        policy.authenticationBegan()
        policy.authenticationSucceeded()

        #expect(policy.isLocked == false)

        policy.didEnterBackground(at: at(10))

        #expect(policy.didBecomeActive(at: at(20)) == .doNothing)
    }

    /// A device with no passcode cannot ask anyone anything, and an app that
    /// cannot be opened is worse than one that is not locked.
    @Test("a device that cannot ask opens instead")
    func cannotAuthenticateOpens() {
        var policy = AppLockPolicy(isEnabled: true)

        policy.cannotAuthenticate()

        #expect(policy.isLocked == false)
        #expect(policy.isEnabled == false)
    }

    /// Answering for the launch, then leaving briefly, must not ask twice.
    private func unlocked() -> AppLockPolicy {
        var policy = AppLockPolicy(isEnabled: true)
        _ = policy.didBecomeActive(at: start)
        policy.authenticationBegan()
        policy.authenticationSucceeded()
        return policy
    }
}
