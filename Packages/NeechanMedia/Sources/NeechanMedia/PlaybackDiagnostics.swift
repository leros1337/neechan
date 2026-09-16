@preconcurrency import KSPlayer
import Foundation

/// Opens a file through the same engine and options the player view uses, and
/// reports what the engine said, in words.
///
/// The player view reduces every failure to "Playback failed", which is right
/// for a reader and useless for finding out why. This is for the tests and for
/// chasing a report: it runs headlessly, needs no view, and returns the
/// engine's own error.
@MainActor
public enum PlaybackDiagnostics {
    public struct Report: Sendable {
        /// The engine's error, or nil when the file reached ready-to-play.
        public var error: String?
        public var isReady = false
        /// True once the engine has decoded frames and can actually show
        /// them. Ready-to-play alone is not that: a stream whose decoder is
        /// broken still reports ready, and then never becomes playable.
        public var isPlayable = false
        /// Every state change, in order, for reading back what happened.
        public var events: [String] = []
        public var naturalSize: CGSize = .zero
        public var duration: TimeInterval = 0
    }

    /// Opens `url` and waits for it to become playable or to fail.
    public static func open(
        _ url: URL,
        options: MediaPlayerOptions,
        timeout: Duration = .seconds(20)
    ) async -> Report {
        let watcher = Watcher()
        let player = KSMEPlayer(url: url, options: KSPlayerBridge.playerOptions(for: options))
        player.delegate = watcher
        player.prepareToPlay()

        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline, !watcher.report.isPlayable, watcher.report.error == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if !watcher.report.isPlayable, watcher.report.error == nil {
            watcher.report.error = watcher.report.isReady
                ? "Ready after \(timeout) but never playable: no frames were decoded."
                : "Timed out after \(timeout) without becoming playable."
        }
        player.shutdown()
        return watcher.report
    }

    private final class Watcher: MediaPlayerDelegate {
        var report = Report()

        func readyToPlay(player: some MediaPlayerProtocol) {
            report.isReady = true
            report.naturalSize = player.naturalSize
            report.duration = player.duration
            report.events.append("readyToPlay \(player.naturalSize) \(player.duration)s")
        }

        func changeLoadState(player: some MediaPlayerProtocol) {
            report.events.append("loadState \(player.loadState)")
            if player.loadState == .playable { report.isPlayable = true }
        }

        func changeBuffering(player: some MediaPlayerProtocol, progress: Int) {}

        func playBack(player: some MediaPlayerProtocol, loopCount: Int) {}

        func finish(player: some MediaPlayerProtocol, error: Error?) {
            if let error {
                report.error = "\(error)"
                report.events.append("finish error: \(error)")
            } else {
                report.events.append("finish")
            }
        }
    }
}
