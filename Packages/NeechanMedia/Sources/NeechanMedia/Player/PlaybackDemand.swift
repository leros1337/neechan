import Foundation
import Synchronization

/// Whether the clip on screen is waiting for bytes.
///
/// One number of connections, one link, one reader waiting on it. A feed warms
/// the clip after next while the current one plays, which is what keeps a
/// swipe from landing on black, but on a slow connection that warm is taking
/// bandwidth from the picture the reader is looking at now. Warming ahead is
/// worth doing when there is room and worth abandoning when there is not.
///
/// The player says when it is waiting; the prefetcher asks before it starts
/// and gives up if the answer changes.
/// How many players are loaded at once.
///
/// There should be one: the clip on screen. More than that and they are
/// sharing a connection between them, each fetching a different file, and the
/// one being watched gets a fraction of the bandwidth. It has happened twice
/// for different reasons, so it is now counted and complained about rather
/// than left to be inferred from the shape of a log.
enum LoadedPlayers {
    private static let count = Mutex(0)

    static func loaded(_ name: String) {
        let now = count.withLock { current -> Int in
            current += 1
            return current
        }
        if now > 1 {
            MediaLog.player.warning(
                "\(name, privacy: .public) makes \(now, privacy: .public) players loaded at once"
            )
        }
    }

    static func unloaded() {
        count.withLock { $0 = max(0, $0 - 1) }
    }
}

public enum PlaybackDemand {
    private static let waiting = Mutex(false)
    private static let onBecameUrgent = Mutex<(@Sendable () -> Void)?>(nil)

    /// True while playback has run out and is waiting for more.
    public static var isWaitingForBytes: Bool {
        waiting.withLock { $0 }
    }

    /// Said by the player as it stops and starts.
    static func setWaitingForBytes(_ isWaiting: Bool) {
        let changed = waiting.withLock { current -> Bool in
            guard current != isWaiting else { return false }
            current = isWaiting
            return true
        }
        guard changed, isWaiting else { return }
        onBecameUrgent.withLock { $0 }?()
    }

    /// Registers what to do the moment playback starts waiting: give up
    /// whatever was being fetched ahead.
    public static func whenPlaybackStartsWaiting(_ body: @escaping @Sendable () -> Void) {
        onBecameUrgent.withLock { $0 = body }
    }
}
