import Foundation
import NeechanAPI
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// How an attempt to prove who is holding the device came out.
///
/// A value rather than the framework's error, which is neither `Sendable` nor
/// worth carrying: the reply arrives on the authentication framework's own
/// queue, and this is what crosses back.
enum AuthenticationOutcome: Sendable, Equatable {
    case unlocked
    /// The reader or the system stopped it. Nothing to say about it.
    case cancelled
    /// The device did not recognise whoever answered.
    case rejected
    /// There is nobody to ask: no passcode is set on the device.
    case unavailable
}

/// Asks the device who is holding it.
///
/// A protocol so the lock can be tested without a face, a finger or a
/// simulator, the way `AppServices` takes its transport.
protocol DeviceAuthenticator: Sendable {
    /// Whether the device can ask at all.
    func canAuthenticate() -> Bool
    func authenticate(reason: String) async -> AuthenticationOutcome
    /// Tears down a prompt that is still up, for when the app leaves the screen
    /// while one is showing.
    func cancel()
}

#if canImport(LocalAuthentication)
/// The device's own check: a face, a fingerprint, or the passcode.
///
/// The passcode is deliberately included rather than asking for biometrics
/// alone. A face that will not read, a device with no Face ID and a reader
/// wearing something over their face must all still be able to get in, and the
/// system's own prompt offers the passcode itself when the rest fails.
final class LocalDeviceAuthenticator: DeviceAuthenticator, @unchecked Sendable {
    /// The attempt in flight, kept only so it can be torn down.
    ///
    /// `LAContext` is not `Sendable` and the prompt can be cancelled from a
    /// different thread than started it, so it is guarded rather than assumed.
    private let lock = NSLock()
    private var context: LAContext?

    private static let policy: LAPolicy = .deviceOwnerAuthentication

    func canAuthenticate() -> Bool {
        LAContext().canEvaluatePolicy(Self.policy, error: nil)
    }

    func authenticate(reason: String) async -> AuthenticationOutcome {
        // A fresh context every time. One that has already succeeded can hand
        // back that success without asking anybody, which is not a lock.
        let context = LAContext()
        lock.withLock { self.context = context }
        defer { lock.withLock { self.context = nil } }

        guard context.canEvaluatePolicy(Self.policy, error: nil) else {
            return .unavailable
        }

        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(Self.policy, localizedReason: reason) { succeeded, error in
                // Flattened here, inside the framework's own callback: nothing
                // that is not `Sendable` crosses back out.
                continuation.resume(returning: Self.outcome(succeeded: succeeded, error: error))
            }
        }
    }

    func cancel() {
        let context = lock.withLock { self.context }
        context?.invalidate()
    }

    private static func outcome(succeeded: Bool, error: (any Error)?) -> AuthenticationOutcome {
        if succeeded { return .unlocked }
        guard let code = (error as? LAError)?.code else { return .cancelled }
        switch code {
        case .passcodeNotSet, .biometryNotAvailable:
            // Nobody to ask. The lock opens rather than stranding the reader.
            return .unavailable
        case .authenticationFailed, .biometryLockout:
            return .rejected
        default:
            // Cancelled by the reader, by the system, or by the app going away.
            return .cancelled
        }
    }
}
#else
/// Where there is no such check, the app does not lock.
struct LocalDeviceAuthenticator: DeviceAuthenticator {
    func canAuthenticate() -> Bool { false }
    func authenticate(reason: String) async -> AuthenticationOutcome { .unavailable }
    func cancel() {}
}
#endif
