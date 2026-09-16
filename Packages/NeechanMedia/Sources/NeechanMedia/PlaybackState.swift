import Foundation

/// What the player is doing, in terms the UI cares about.
///
/// Mirrors the engine's own states but does not expose them, so the controls
/// above this module never import KSPlayer.
public enum PlaybackState: Sendable, Equatable {
    case idle
    case preparing
    case buffering
    case playing
    case paused
    case finished
    case failed(String)

    public var isBusy: Bool {
        self == .preparing || self == .buffering
    }

    public var isPlaying: Bool {
        self == .playing
    }
}

/// Where playback has reached.
public struct PlaybackProgress: Sendable, Equatable {
    public var current: TimeInterval
    public var total: TimeInterval

    public init(current: TimeInterval = 0, total: TimeInterval = 0) {
        self.current = current
        self.total = total
    }

    /// 0 to 1, or 0 when the duration is unknown. Live streams and some WebM
    /// files report no duration at all.
    public var fraction: Double {
        guard total > 0, current.isFinite, total.isFinite else { return 0 }
        return min(1, max(0, current / total))
    }

    public var isSeekable: Bool { total > 0 }
}

/// When a clip should be started again.
///
/// The engine's own loop flag is read when a clip is opened, so turning looping
/// on part-way through one had no effect. The view restarts the clip itself,
/// and this is the rule it follows.
public enum LoopPolicy {
    /// - Parameters:
    ///   - state: the state the player just reported.
    ///   - isLooping: whether the reader has looping switched on.
    public static func shouldRestart(state: PlaybackState, isLooping: Bool) -> Bool {
        isLooping && state == .finished
    }
}
