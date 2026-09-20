import CoreMedia
import Foundation

/// Decides what to do about a clip that has stopped and has not started itself
/// again.
///
/// Playback stopping is ordinary: the network falls behind, the clock is
/// stopped, and it starts again when enough has arrived. What is not ordinary
/// is a stop that nothing can end, and the player has two of those.
///
/// The first is a renderer holding pictures it will not show. While the clock
/// is stopped the display layer never dequeues, so it goes on reporting that it
/// has no room; nothing more can be handed to it, so the amount of media ahead
/// of the clock never grows, so the clock is never started, so the renderer
/// never drains. Everything needed to carry on is in hand and the clip waits
/// for ever. Worse, the decode thread fills the frame queue and then blocks on
/// it, and pushing is what asks the renderers to take more — so the last thing
/// that could have noticed stops running too.
///
/// The second is a file that ended while the clip was waiting. The demuxer
/// reaches the end, the decoders drain, and the queues go empty with the clock
/// stopped short of the last picture. Nothing arrives to trigger another look,
/// and the end is never reported.
///
/// A value rather than a method, because none of this can be arranged on the
/// real Core Media objects from a test: it needs a stopped clock, a renderer
/// refusing data and a blocked decode thread, all at once.
enum StallRecovery {
    /// How long a stop has to last before it counts as one going nowhere.
    ///
    /// Long enough that an ordinary wait for the network is never cut short by
    /// it — starting again on a clip that really is just slow would show one
    /// picture and stop again.
    static let patience = Duration.seconds(5)

    /// How far past a waiting picture the clock has to be before going back to
    /// it counts as a rescue rather than a stutter.
    static let overrun = 0.5

    /// Everything the decision is made from, read in one go so the answer
    /// cannot be assembled out of a clock that moved half way through.
    struct Situation: Sendable {
        /// Playback stopped because it ran out, rather than because it was
        /// paused.
        var isStarved: Bool
        /// The clock has been sent somewhere nothing has been shown yet, so
        /// nothing it says means anything.
        var isAwaitingNewPosition: Bool
        /// The end has already been reported once.
        var hasEnded: Bool
        /// How long playback has been stopped, or nil when it is not.
        var stoppedFor: Duration?
        var clock: CMTime
        /// The end of the last thing handed to a renderer.
        var lastHandedOver: CMTime
        /// When the next decoded picture is for, or nil when none is waiting.
        var nextPicture: CMTime?
        var isRendererReady: Bool
        var isVideoDrained: Bool
        var isAudioDrained: Bool
        var isClockRunning: Bool
        /// Whether the clip has a picture at all. Defaulted, because it is the
        /// ordinary case and every caller but an audio-only clip wants it.
        var hasVideo: Bool = true
    }

    enum Action: Equatable, Sendable {
        /// Nothing to do: either playback is fine or it is waiting for bytes,
        /// which is not this to fix.
        case waitLonger
        /// Throw away what the renderers hold and start again from here.
        case startAgain(from: CMTime)
        /// There is nothing left and there never will be.
        case reachedTheEnd
    }

    static func decide(_ now: Situation) -> Action {
        guard !now.hasEnded, !now.isAwaitingNewPosition else { return .waitLonger }

        // Nothing more will ever arrive, and the clock has caught up with the
        // last of what did. A running clock is given a second's grace, because
        // it reaches the end of the last picture a moment before that picture
        // has finished being shown; a stopped one is not, because it is not
        // going to move again on its own.
        //
        // A clip with a picture is over when the picture is. The sound gets no
        // vote: an audio queue that never gets round to saying it has finished,
        // which a seek landing on the end of the file leaves behind, otherwise
        // keeps the clip alive for ever over a frozen last frame.
        let nothingMoreComing = now.hasVideo ? now.isVideoDrained : now.isAudioDrained
        if nothingMoreComing, now.lastHandedOver.isValid, now.lastHandedOver > .zero {
            let past = CMTimeGetSeconds(now.clock - now.lastHandedOver)
            if now.isClockRunning ? past > 1 : (now.isStarved && past >= 0) {
                return .reachedTheEnd
            }
        }

        // Everything below is about a stop that has lasted long enough to be
        // worth doubting.
        guard now.isStarved, let stoppedFor = now.stoppedFor, stoppedFor > Self.patience else {
            return .waitLonger
        }
        // Waiting with nothing decoded is waiting for the network.
        guard let next = now.nextPicture, next.isValid else { return .waitLonger }

        // Either the clock has gone past the picture that is waiting, so it
        // will never be shown and nothing will ask for another; or the renderer
        // is refusing what it already holds, so no amount of waiting will let
        // anything else be handed over. Both are only ever escaped by throwing
        // away what the renderers hold and starting again from the picture that
        // is actually next.
        let clockHasOverrun = CMTimeGetSeconds(now.clock - next) > Self.overrun
        guard clockHasOverrun || !now.isRendererReady else { return .waitLonger }
        return .startAgain(from: next)
    }
}
