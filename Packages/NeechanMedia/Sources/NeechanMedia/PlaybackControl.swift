import Foundation

/// A one-shot instruction to the player.
///
/// Carried as a value with a generation counter so that repeating the same
/// command (pause, pause) still takes effect.
public struct PlaybackControl: Sendable, Equatable {
    public enum Command: Sendable, Equatable {
        case none
        case play
        case pause
        case seek(TimeInterval)
        case setMuted(Bool)
        case setLooping(Bool)
    }

    public private(set) var command: Command
    private var generation: Int

    public init() {
        command = .none
        generation = 0
    }

    public mutating func send(_ command: Command) {
        self.command = command
        generation += 1
    }
}
