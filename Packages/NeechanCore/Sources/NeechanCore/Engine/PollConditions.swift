import Foundation

/// The state of the device and the reader's preferences, as far as a poll that
/// nobody asked for is concerned.
///
/// A value rather than a set of checks spread through the watcher, so the rule
/// can be stated once and tested without a network. Mirrors `MediaLoadDecision`,
/// which answers the same shape of question for thumbnails.
public struct PollConditions: Sendable, Equatable {
    /// Whether the device has a usable network at all.
    public var isConnected: Bool
    /// True on cellular and on personal hotspots.
    public var isExpensive: Bool
    /// The reader asked for the watcher to stay off cellular.
    public var wifiOnly: Bool
    public var isLowPower: Bool

    public init(
        isConnected: Bool = true,
        isExpensive: Bool = false,
        wifiOnly: Bool = false,
        isLowPower: Bool = false
    ) {
        self.isConnected = isConnected
        self.isExpensive = isExpensive
        self.wifiOnly = wifiOnly
        self.isLowPower = isLowPower
    }

    /// Whether a poll may go out now.
    ///
    /// Offline counts as no: a request with nowhere to go still wakes the radio
    /// looking for one, and `waitsForConnectivity` would leave it queued.
    public var allowsPolling: Bool {
        guard isConnected else { return false }
        return !(wifiOnly && isExpensive)
    }

    /// What to assume when nothing has been wired up, such as in a test.
    public static let unrestricted = PollConditions()
}
