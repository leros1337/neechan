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
        /// What FFmpeg found the file to be from its bytes, which is not always
        /// what its name says.
        public var container: String?
        public var videoCodec: String?
        public var audioCodec: String?
        /// Nil when the file has no sound. False when it has and none came out
        /// of the decoder: a clip that plays in silence and otherwise looks
        /// perfectly well.
        public var soundDecoded: Bool?
        /// The furthest the clock got while the clip was left to play.
        public var furthest: TimeInterval = 0
        /// Whether a seek, when one was asked for, got there and carried on
        /// playing. Nil when none was asked for.
        public var seekLanded: Bool?
        /// Whether the clip ended where the seek sent it instead, which is
        /// right only for a file that holds less than it says: one cut off
        /// partway has nothing there to carry on with.
        public var seekEnded = false
    }

    /// Opens `url` and waits for it to become playable or to fail.
    ///
    /// - Parameters:
    ///   - playFor: once there is a picture, how many seconds to let it play
    ///     before reporting. A first frame says the file opens; this says it
    ///     keeps going.
    ///   - fraction: then seek this far into the clip, 0.5 being halfway, and
    ///     wait for it to carry on from there.
    public static func open(
        _ url: URL,
        options: MediaPlayerOptions,
        timeout: Duration = .seconds(20),
        playFor: TimeInterval? = nil,
        seekTo fraction: Double? = nil
    ) async -> Report {
        var report = Report()
        let player = MediaPlayer()
        defer { player.shutdown() }

        var settled = false
        var failed = false
        var current: TimeInterval = 0
        player.onState = { state in
            report.events.append("\(state)")
            switch state {
            case .playing, .paused:
                report.isPlayable = true
                settled = true
            case .failed(let message):
                report.error = message
                settled = true
                failed = true
            default:
                break
            }
        }
        player.onProgress = { progress in
            report.duration = max(report.duration, progress.total)
            current = progress.current
            report.furthest = max(report.furthest, progress.current)
        }

        // Nothing should start playing out loud just because someone asked
        // what a file is.
        var quiet = options
        quiet.startsMuted = true
        player.load(url: url, options: quiet)

        await wait(timeout) { settled }

        report.naturalSize = player.naturalSize
        report.isReady = player.naturalSize != .zero

        if report.isPlayable, !failed, let playFor {
            if player.state == .paused { player.play() }
            // A clip shorter than that is let run to its end instead.
            let goal = report.duration > 0 ? min(playFor, report.duration * 0.9) : playFor
            await wait(timeout) { report.furthest >= goal || failed || player.state == .finished }
        }

        if report.isPlayable, !failed, let fraction, report.duration > 0 {
            let target = report.duration * fraction
            // The clock is moved to the target the moment the seek is asked
            // for, so being there proves nothing. Moving on from it does.
            let goal = min(target + 0.5, report.duration * 0.98)
            report.events.append("seek to \(String(format: "%.1f", target))s")
            player.seek(to: target)
            var landed = false
            await wait(timeout) {
                if current >= goal { landed = true }
                return landed || failed || player.state == .finished
            }
            report.seekLanded = landed && !failed
            report.seekEnded = !landed && !failed && player.state == .finished
        }

        // Sound comes out a little after the first picture, so a clip that
        // was only opened is given a moment for it before being called silent.
        if player.hasDecodedSound == false, !failed {
            await wait(.seconds(3)) { player.hasDecodedSound == true || failed }
        }

        report.usedHardwareDecode = player.isDecodingInHardware
        report.container = player.containerName
        report.videoCodec = player.videoCodecName
        report.audioCodec = player.audioCodecName
        report.soundDecoded = player.hasDecodedSound
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

    private static func wait(_ timeout: Duration, until condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline, !condition() {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
