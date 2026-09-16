import Foundation
import Network
import NeechanSettings
import Observation

/// Whether a request should be made now, given what the reader asked for and
/// what kind of connection is available.
public enum MediaLoadDecision {
    /// - Parameter isExpensive: true on cellular and on personal hotspots,
    ///   which is what "Wi-Fi only" is really trying to avoid.
    public static func shouldLoad(policy: MediaLoadPolicy, isExpensive: Bool) -> Bool {
        switch policy {
        case .always: true
        case .wifiOnly: !isExpensive
        case .never: false
        }
    }
}

/// Watches the kind of connection the device has.
///
/// Only the expensive-or-not answer is exposed, because that is the only part
/// any preference here depends on.
@MainActor
@Observable
public final class NetworkReachability {
    /// True on cellular and hotspot connections.
    public private(set) var isExpensive = false

    /// Whether the device has a usable network at all.
    ///
    /// Starts true: the monitor reports the first path asynchronously, and
    /// assuming the device is offline until it does would hold back the first
    /// poll after launch for no reason.
    public private(set) var isConnected = true

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private let queue = DispatchQueue(label: "com.lain.neechan.reachability")
    @ObservationIgnored private var hasStarted = false

    public init() {}

    /// Begins watching. Safe to call more than once.
    ///
    /// `NWPathMonitor.start` is not: calling it twice traps. The guard is what
    /// makes the sentence above true, rather than merely intended.
    public func start() {
        guard !hasStarted else { return }
        hasStarted = true

        monitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive || path.isConstrained
            let connected = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Guarded because this fires on every path change, including
                // ones that change neither answer, and both are observed by
                // every thumbnail on screen.
                if isExpensive != expensive { isExpensive = expensive }
                if isConnected != connected { isConnected = connected }
            }
        }
        monitor.start(queue: queue)
    }

    /// Stops watching. The monitor cannot be restarted afterwards.
    public func stop() {
        guard hasStarted else { return }
        monitor.cancel()
    }

    /// Whether media may be fetched right now under this policy.
    public func allowsMedia(under policy: MediaLoadPolicy) -> Bool {
        MediaLoadDecision.shouldLoad(policy: policy, isExpensive: isExpensive)
    }
}
