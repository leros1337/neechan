import Foundation
import Synchronization
import Testing
@testable import NeechanUI

/// The lock as the app drives it: scene changes in, prompts out.
@MainActor
@Suite("App lock")
struct AppLockTests {
    /// Stands in for the device, answering however a test wants.
    private final class StubAuthenticator: DeviceAuthenticator, @unchecked Sendable {
        private let lock = NSLock()
        private var outcome: AuthenticationOutcome
        private var asked = 0
        private var cancels = 0
        var canAnswer = true

        init(_ outcome: AuthenticationOutcome) {
            self.outcome = outcome
        }

        var timesAsked: Int { lock.withLock { asked } }
        var timesCancelled: Int { lock.withLock { cancels } }

        func answer(with outcome: AuthenticationOutcome) {
            lock.withLock { self.outcome = outcome }
        }

        func canAuthenticate() -> Bool { canAnswer }

        func authenticate(reason: String) async -> AuthenticationOutcome {
            lock.withLock {
                asked += 1
                return outcome
            }
        }

        func cancel() {
            lock.withLock { cancels += 1 }
        }
    }

    private func make(
        enabled: Bool = true,
        answering outcome: AuthenticationOutcome = .unlocked
    ) -> (AppLock, StubAuthenticator) {
        let authenticator = StubAuthenticator(outcome)
        return (AppLock(isEnabled: enabled, authenticator: authenticator), authenticator)
    }

    /// Lets the attempt, which runs in a task of its own, finish.
    private func settle() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
    }

    @Test("a launch with the lock on hides the app and asks once")
    func launchAsks() async {
        let (lock, device) = make()

        #expect(lock.isLocked)
        lock.sceneBecameActive()
        await settle()

        #expect(device.timesAsked == 1)
        #expect(lock.isLocked == false)
        #expect(lock.isCovered == false)
    }

    @Test("with the lock off nothing is hidden and nobody is asked")
    func disabledAsksNobody() async {
        let (lock, device) = make(enabled: false)

        lock.sceneBecameActive()
        lock.sceneEnteredBackground()
        lock.sceneBecameActive()
        await settle()

        #expect(device.timesAsked == 0)
        #expect(lock.isLocked == false)
        #expect(lock.isCovered == false)
    }

    /// The prompt itself makes the app inactive and hands it back.
    @Test("one prompt at a time")
    func oneAttemptAtATime() async {
        let (lock, device) = make()

        lock.sceneBecameActive()
        lock.authenticate()
        lock.sceneBecameActive()
        await settle()

        #expect(device.timesAsked == 1)
    }

    @Test("a refused answer leaves the app locked, waiting to be asked again")
    func refusedStaysLocked() async {
        let (lock, device) = make(answering: .rejected)

        lock.sceneBecameActive()
        await settle()

        #expect(lock.isLocked)
        #expect(lock.isCovered)
        #expect(device.timesAsked == 1)

        device.answer(with: .unlocked)
        lock.authenticate()
        await settle()

        #expect(lock.isLocked == false)
        #expect(device.timesAsked == 2)
    }

    /// A lock that cannot be opened is worse than no lock at all.
    @Test("a device with nothing to ask opens the app and gives up")
    func unavailableGivesUp() async {
        let (lock, _) = make(answering: .unavailable)

        lock.sceneBecameActive()
        await settle()

        #expect(lock.isLocked == false)
        #expect(lock.didGiveUp)
    }

    /// Control Centre and permission alerts do this, and neither is the reader
    /// leaving.
    @Test("going inactive covers the app without locking it")
    func inactiveCoversOnly() async {
        let (lock, device) = make()
        lock.sceneBecameActive()
        await settle()

        lock.sceneBecameInactive()

        #expect(lock.isCovered, "the switcher must not show what was on screen")
        #expect(lock.isLocked == false)

        lock.sceneBecameActive()
        await settle()

        #expect(lock.isCovered == false)
        #expect(device.timesAsked == 1, "a glance at Control Centre is not a way out")
    }

    @Test("a prompt left up when the app goes away is taken down")
    func leavingCancelsThePrompt() async {
        let (lock, device) = make(answering: .cancelled)

        lock.sceneBecameActive()
        lock.sceneEnteredBackground()

        #expect(device.timesCancelled == 1)
    }
}
