import CoreMedia
import Foundation
import Testing
@testable import NeechanMedia

/// What to do about a clip that has stopped and has not started itself again.
///
/// Every case here was a clip that sat on a spinner for ever. The player
/// cannot be asked about them directly: the states involve a stopped clock, a
/// renderer refusing data and a decode thread blocked on a full queue, none of
/// which a test can arrange on the real Core Media objects. The decision is a
/// value instead, and this is where it is pinned down.
@Suite("Recovering from a stall")
struct StallRecoveryTests {
    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// The shape of the bug this was written for: buffering, the renderer
    /// holding pictures it will not show while the clock is stopped, and
    /// decoded frames waiting behind it.
    private func wedged(
        clock: Double = 1.0,
        next: Double? = 1.0,
        rendererReady: Bool = false,
        stoppedFor: Duration? = .seconds(6)
    ) -> StallRecovery.Situation {
        StallRecovery.Situation(
            isStarved: true,
            isAwaitingNewPosition: false,
            hasEnded: false,
            stoppedFor: stoppedFor,
            clock: time(clock),
            lastHandedOver: time(clock),
            nextPicture: next.map(time),
            isRendererReady: rendererReady,
            isVideoDrained: false,
            isAudioDrained: true,
            isClockRunning: false
        )
    }

    @Test("a renderer that refuses what it holds is started again")
    func rendererRefusingIsRescued() {
        #expect(StallRecovery.decide(wedged()) == .startAgain(from: time(1.0)))
    }

    @Test("a clock that has run past the picture is sent back to it")
    func clockPastThePictureIsRescued() {
        let situation = wedged(clock: 3, next: 1, rendererReady: true)
        #expect(StallRecovery.decide(situation) == .startAgain(from: time(1)))
    }

    @Test("a stop that has not lasted long enough is left alone")
    func shortStopsAreLeftAlone() {
        #expect(StallRecovery.decide(wedged(stoppedFor: .seconds(2))) == .waitLonger)
    }

    @Test("waiting with nothing decoded is waiting for the network")
    func nothingToShowIsNotRescued() {
        #expect(StallRecovery.decide(wedged(next: nil)) == .waitLonger)
    }

    @Test("a renderer with room and a picture still ahead is simply waiting")
    func roomAndPictureAheadIsNotRescued() {
        let situation = wedged(clock: 1, next: 1.2, rendererReady: true)
        #expect(StallRecovery.decide(situation) == .waitLonger)
    }

    @Test("a clip stopped with nothing left to come has ended")
    func drainedWhileStoppedIsTheEnd() {
        var situation = wedged(clock: 2, next: nil)
        situation.isVideoDrained = true
        situation.lastHandedOver = time(2)
        #expect(StallRecovery.decide(situation) == .reachedTheEnd)
    }

    @Test("a clip stopped with pictures still to show is started again, not ended")
    func drainedButStillAheadIsResumed() {
        var situation = wedged(clock: 1, next: 1.5)
        situation.isVideoDrained = true
        situation.lastHandedOver = time(3)
        #expect(StallRecovery.decide(situation) == .startAgain(from: time(1.5)))
    }

    @Test("a running clock past the end still reports the end")
    func runningPastTheEndIsTheEnd() {
        var situation = wedged(clock: 5, next: nil)
        situation.isStarved = false
        situation.isClockRunning = true
        situation.isVideoDrained = true
        situation.lastHandedOver = time(3)
        #expect(StallRecovery.decide(situation) == .reachedTheEnd)
    }

    @Test("a clip already reported as ended is not ended twice")
    func endedOnceOnly() {
        var situation = wedged(clock: 2, next: nil)
        situation.isVideoDrained = true
        situation.lastHandedOver = time(2)
        situation.hasEnded = true
        #expect(StallRecovery.decide(situation) == .waitLonger)
    }

    @Test("a clip waiting for a seek to land is left to land")
    func awaitingNewPositionIsLeftAlone() {
        var situation = wedged()
        situation.isAwaitingNewPosition = true
        #expect(StallRecovery.decide(situation) == .waitLonger)
    }
}
