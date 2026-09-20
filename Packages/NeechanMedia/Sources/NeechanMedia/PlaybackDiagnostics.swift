import CoreGraphics
import Foundation

/// Opens a file the way the viewer does and reports what happened, in words.
///
/// The player reduces every failure to one sentence, which is right for a
/// reader and useless for finding out why. This is for the tests and for
/// chasing a report: it runs headlessly, needs no view, and says which path
/// the file took as well as whether it played.
@MainActor
public enum PlaybackDiagnostics {
    public struct Report: Sendable {
        /// What went wrong, in the player's own words, or nil if nothing did.
        public var error: String?
        /// True once the file has been opened and its streams are known.
        public var isReady = false
        /// True once a picture has actually been decoded. Being ready is not
        /// that: a file whose decoder is broken still opens, and then never
        /// produces a frame.
        public var isPlayable = false
        /// Every state the player reported, in order.
        public var events: [String] = []
        public var naturalSize: CGSize = .zero
        public var duration: TimeInterval = 0
        /// Whether the picture came back from the graphics hardware.
        public var usedHardwareDecode = false
    }

    /// Opens `url` and waits for it to become playable or to fail.
    public static func open(
        _ url: URL,
        options: MediaPlayerOptions,
        timeout: Duration = .seconds(20)
    ) async -> Report {
        var report = Report()
        let player = MediaPlayer()
        defer { player.shutdown() }

        var settled = false
        player.onState = { state in
            report.events.append("\(state)")
            switch state {
            case .playing, .paused:
                report.isPlayable = true
                settled = true
            case .failed(let message):
                report.error = message
                settled = true
            default:
                break
            }
        }
        player.onProgress = { report.duration = max(report.duration, $0.total) }

        // Nothing should start playing out loud just because someone asked
        // what a file is.
        var quiet = options
        quiet.startsMuted = true
        player.load(url: url, options: quiet)

        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline, !settled {
            try? await Task.sleep(for: .milliseconds(20))
        }

        report.naturalSize = player.naturalSize
        report.isReady = player.naturalSize != .zero
        report.usedHardwareDecode = player.isDecodingInHardware
        if let failure = player.lastFailure {
            report.events.append("detail: \(failure)")
        }
        if !report.isPlayable, report.error == nil {
            report.error = report.isReady
                ? "Opened but never produced a picture within \(timeout)."
                : "Timed out after \(timeout) without opening."
        }
        return report
    }
}
