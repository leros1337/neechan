import Foundation
import Testing
@testable import NeechanMedia

/// The rules behind what the viewer shows.
///
/// Worth having apart from the player: a spinner that never goes away, or a
/// clip that reports it finished while it is still looping, is a rule being
/// wrong rather than a decoder being wrong.
@Suite("Playback state")
struct PlaybackStateMachineTests {
    @Test("a clip that plays by itself starts on its first frame")
    func autoplayStartsOnTheFirstFrame() {
        var machine = PlaybackStateMachine(autoplays: true)
        #expect(machine.state == .idle)
        #expect(machine.handle(.opened) == .preparing)
        #expect(machine.handle(.firstFrame) == .playing)
    }

    @Test("a clip that does not autoplay waits on its first frame")
    func withoutAutoplayItWaits() {
        var machine = PlaybackStateMachine(autoplays: false)
        machine.handle(.opened)
        #expect(machine.handle(.firstFrame) == .paused)
    }

    /// The spinner the viewer shows comes from this, so a clip that is merely
    /// slow must not look like one that failed.
    @Test("running out mid-clip is buffering, and refilling resumes")
    func starvationBuffers() {
        var machine = PlaybackStateMachine()
        machine.handle(.opened)
        machine.handle(.firstFrame)
        #expect(machine.handle(.starved) == .buffering)
        #expect(machine.handle(.refilled) == .playing)
    }

    @Test("running out while paused does not start a spinner")
    func starvationWhilePausedIsIgnored() {
        var machine = PlaybackStateMachine()
        machine.handle(.opened)
        machine.handle(.firstFrame)
        machine.handle(.pause)
        #expect(machine.handle(.starved) == .paused)
    }

    @Test("the end of a clip is the end")
    func endOfStreamFinishes() {
        var machine = PlaybackStateMachine()
        machine.handle(.opened)
        machine.handle(.firstFrame)
        #expect(machine.handle(.endOfStream) == .finished)
    }

    /// A looping clip never stops, so it never reports that it did. Saying
    /// otherwise would flash the viewer's finished state between every repeat.
    @Test("a looping clip keeps playing at the end")
    func loopingNeverFinishes() {
        var machine = PlaybackStateMachine(isLooping: true)
        machine.handle(.opened)
        machine.handle(.firstFrame)
        #expect(machine.handle(.endOfStream) == .playing)
    }

    /// The regression this guards: a frame arriving after a seek must not
    /// restart a clip the reader deliberately paused.
    @Test("a later frame does not un-pause the clip")
    func aLaterFrameDoesNotResume() {
        var machine = PlaybackStateMachine()
        machine.handle(.opened)
        machine.handle(.firstFrame)
        machine.handle(.pause)
        #expect(machine.handle(.firstFrame) == .paused)
    }

    @Test("a failure stands until another file is opened")
    func failureIsFinalForThisFile() {
        var machine = PlaybackStateMachine()
        machine.handle(.opened)
        #expect(machine.handle(.failed("no")) == .failed("no"))

        // Everything the machinery reports while it winds down is ignored.
        #expect(machine.handle(.firstFrame) == .failed("no"))
        #expect(machine.handle(.play) == .failed("no"))
        #expect(machine.handle(.endOfStream) == .failed("no"))

        // The next file starts clean.
        #expect(machine.handle(.opened) == .preparing)
    }

    @Test("pausing a finished clip leaves it finished")
    func pauseDoesNotUndoTheEnd() {
        var machine = PlaybackStateMachine()
        machine.handle(.opened)
        machine.handle(.firstFrame)
        machine.handle(.endOfStream)
        #expect(machine.handle(.pause) == .finished)
    }
}
