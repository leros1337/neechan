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

    @ObservationIgnored private let monitor = NWPathMonitor()

    public init() {}

    /// Begins watching. Safe to call more than once.
    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive || path.isConstrained
            Task { @MainActor [weak self] in
                self?.isExpensive = expensive
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.lain.neechan.reachability"))
    }

    /// Whether media may be fetched right now under this policy.
    public func allowsMedia(under policy: MediaLoadPolicy) -> Bool {
        MediaLoadDecision.shouldLoad(policy: policy, isExpensive: isExpensive)
    }
}
