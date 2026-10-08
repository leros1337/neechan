import Foundation
import Testing
@testable import NeechanMedia

/// When the app takes the sound from whatever else was playing, and when it
/// gives it back.
///
/// Worth having apart from the session itself: Spotify stopping for a muted
/// clip, or staying stopped after the gallery has closed, is a rule being
/// wrong, and nothing on the simulator plays music to show it.
@Suite("Sharing the sound with other apps")
struct AudioSessionPolicyTests {
    typealias Policy = AudioSessionPolicy<String>

    @Test("a muted clip leaves the other app playing")
    func mutedNeverTakes() {
        var policy = Policy()
        #expect(policy.report("feed", .silent) == [])
        #expect(!policy.isHeld)
    }

    @Test("a clip about to play takes nothing until it is heard")
    func holdingNeverTakes() {
        var policy = Policy()
        #expect(policy.report("gallery", .holding) == [])
        #expect(!policy.isHeld)
    }

    @Test("a clip playing out loud takes the sound")
    func audibleTakes() {
        var policy = Policy()
        #expect(policy.report("gallery", .audible) == [.take])
        #expect(policy.isHeld)
    }

    @Test("pausing gives the sound back after a moment, not at once")
    func pausingSchedulesTheHandBack() {
        var policy = Policy()
        policy.report("gallery", .audible)
        #expect(policy.report("gallery", .silent) == [.scheduleHandBack(1)])
        #expect(policy.isHeld)
        #expect(policy.graceElapsed(1) == [.handBack])
        #expect(!policy.isHeld)
    }

    /// The feed pauses as a drag begins and plays as it settles. Handing the
    /// sound back in between made the other app start and stop on every swipe.
    @Test("playing again within the moment keeps the sound")
    func playingAgainCancelsTheHandBack() {
        var policy = Policy()
        policy.report("feed", .audible)
        policy.report("feed", .silent)
        #expect(policy.report("feed", .audible) == [.cancelHandBack, .take])
        #expect(policy.graceElapsed(1) == [])
        #expect(policy.isHeld)
    }

    @Test("muting gives the sound back, and unmuting takes it again")
    func mutingAndUnmuting() {
        var policy = Policy()
        policy.report("gallery", .audible)
        #expect(policy.report("gallery", .silent) == [.scheduleHandBack(1)])
        #expect(policy.graceElapsed(1) == [.handBack])
        #expect(policy.report("gallery", .audible) == [.take])
        #expect(policy.isHeld)
    }

    /// Paging from one clip with sound to the next goes through a clip still
    /// being opened, which may or may not turn out to have any.
    @Test("one clip with sound to the next keeps the sound throughout")
    func videoToVideoKeepsTheSound() {
        var policy = Policy()
        policy.report("gallery", .audible)
        #expect(policy.report("gallery", .holding) == [])
        #expect(policy.report("gallery", .audible) == [.take])
        #expect(policy.isHeld)
    }

    @Test("a clip that turns out to be silent gives the sound back")
    func holdingThenSilentHandsBack() {
        var policy = Policy()
        policy.report("gallery", .audible)
        policy.report("gallery", .holding)
        #expect(policy.report("gallery", .silent) == [.scheduleHandBack(1)])
        #expect(policy.graceElapsed(1) == [.handBack])
    }

    @Test("a moment that has been and gone is not acted on twice")
    func staleGraceIsIgnored() {
        var policy = Policy()
        policy.report("feed", .audible)
        policy.report("feed", .silent)
        policy.report("feed", .audible)
        #expect(policy.report("feed", .silent) == [.scheduleHandBack(2)])
        #expect(policy.graceElapsed(1) == [])
        #expect(policy.graceElapsed(2) == [.handBack])
    }

    @Test("the app going to the background gives the sound back at once")
    func backgroundHandsBackAtOnce() {
        var policy = Policy()
        policy.report("gallery", .audible)
        policy.report("gallery", .silent)
        #expect(policy.handBackNow() == [.cancelHandBack, .handBack])
        #expect(!policy.isHeld)
        #expect(policy.graceElapsed(1) == [])
    }

    @Test("giving back what was never taken does nothing")
    func handBackNowWhenNotHeld() {
        var policy = Policy()
        policy.report("feed", .silent)
        #expect(policy.handBackNow() == [])
    }

    @Test("closing the gallery gives the sound back at once")
    func lastPlayerGoneHandsBackAtOnce() {
        var policy = Policy()
        policy.report("gallery", .audible)
        #expect(policy.playerGone("gallery") == [.handBack])
        #expect(!policy.isHeld)
    }

    /// The diagnostics open a muted player of their own and shut it down when
    /// they are done, which used to hand the gallery's sound back from under it.
    @Test("a silent player going away leaves another one's sound alone")
    func anotherPlayerGoneKeepsTheSound() {
        var policy = Policy()
        policy.report("gallery", .audible)
        policy.report("diagnostics", .silent)
        #expect(policy.playerGone("diagnostics") == [])
        #expect(policy.isHeld)
    }

    @Test("the sound is kept while any player is still heard")
    func twoPlayers() {
        var policy = Policy()
        policy.report("gallery", .audible)
        policy.report("feed", .audible)
        #expect(policy.report("gallery", .silent) == [])
        #expect(policy.report("feed", .silent) == [.scheduleHandBack(1)])
    }

    @Test("another app taking the sound pauses the clips that were using it")
    func interruptionPausesTheAudiblePlayers() {
        var policy = Policy()
        policy.report("gallery", .audible)
        policy.report("feed", .silent)
        #expect(policy.interruptionBegan(becauseAppWasSuspended: false) == [.pause(["gallery"])])
        #expect(!policy.isHeld)
        // The pause is reported back as silence. Nothing is handed back:
        // the other app already has it.
        #expect(policy.report("gallery", .silent) == [])
    }

    /// One about to start would otherwise take the sound straight back from
    /// the app the reader has just turned on.
    @Test("an interruption pauses a clip about to play too")
    func interruptionPausesHoldingPlayers() {
        var policy = Policy()
        policy.report("gallery", .audible)
        policy.report("gallery", .holding)
        #expect(policy.interruptionBegan(becauseAppWasSuspended: false) == [.pause(["gallery"])])
    }

    @Test("an interruption cancels a hand-back that was waiting")
    func interruptionCancelsThePendingHandBack() {
        var policy = Policy()
        policy.report("gallery", .audible)
        policy.report("gallery", .silent)
        #expect(policy.interruptionBegan(becauseAppWasSuspended: false) == [.cancelHandBack])
        #expect(policy.graceElapsed(1) == [])
    }

    /// Delivered late, as the app comes back, about a time it was not running.
    @Test("an interruption that only says the app was suspended is ignored")
    func suspendedInterruptionIsIgnored() {
        var policy = Policy()
        policy.report("gallery", .audible)
        #expect(policy.interruptionBegan(becauseAppWasSuspended: true) == [])
        #expect(policy.isHeld)
    }

    @Test("asking for the sound again takes it only for a clip being heard")
    func reclaim() {
        var policy = Policy()
        policy.report("gallery", .silent)
        #expect(policy.reclaim() == [])
        policy.report("gallery", .audible)
        policy.interruptionBegan(becauseAppWasSuspended: true)
        #expect(policy.reclaim() == [.take])
    }
}

/// What one player's sound amounts to, from what it is doing.
@Suite("Whether a clip is heard")
struct SoundStatusTests {
    private func status(
        _ state: PlaybackState,
        muted: Bool = false,
        hasAudio: Bool? = true,
        autoplays: Bool = true,
        loaded: Bool = true
    ) -> SoundStatus {
        SoundStatus(state: state, isMuted: muted, hasAudio: hasAudio, autoplays: autoplays, isLoaded: loaded)
    }

    @Test("playing with sound is heard")
    func playingIsAudible() {
        #expect(status(.playing) == .audible)
    }

    @Test("muted, or with no sound in the file, is not")
    func mutedOrSoundlessIsSilent() {
        #expect(status(.playing, muted: true) == .silent)
        #expect(status(.playing, hasAudio: false) == .silent)
        #expect(status(.preparing, hasAudio: false) == .silent)
    }

    @Test("stopped in any way is not heard")
    func stoppedIsSilent() {
        #expect(status(.paused) == .silent)
        #expect(status(.finished) == .silent)
        #expect(status(.failed("x")) == .silent)
        #expect(status(.idle) == .silent)
    }

    @Test("a clip unloaded is not heard, whatever its state last said")
    func unloadedIsSilent() {
        #expect(status(.playing, loaded: false) == .silent)
    }

    @Test("waiting for bytes, or opening a clip that will play, holds on")
    func waitingHolds() {
        #expect(status(.buffering) == .holding)
        #expect(status(.preparing, hasAudio: nil) == .holding)
        #expect(status(.preparing, hasAudio: true) == .holding)
    }

    @Test("opening a clip that will wait for a tap does not")
    func preparingWithoutAutoplayIsSilent() {
        #expect(status(.preparing, hasAudio: nil, autoplays: false) == .silent)
    }

    @Test("playing before the file has said what it holds holds on")
    func playingUnknownHolds() {
        #expect(status(.playing, hasAudio: nil) == .holding)
    }
}
