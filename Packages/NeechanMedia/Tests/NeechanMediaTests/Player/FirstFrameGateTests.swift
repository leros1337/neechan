import Foundation
import Testing
@testable import NeechanMedia

/// Who gets to say "there is now a picture to show".
///
/// The fault this guards against, seen on a phone over a slow connection: a
/// scrub started the clock at the new position fourteen milliseconds after
/// the seek, when the first picture for it was still seven seconds away in a
/// download. The clock ran on with nothing to show and every picture then
/// arrived already in the past. The announcement had come from a picture of
/// the old position, pushed just as the seek began: the seek reset the "said
/// it already" flag, and the push that had started before the reset finished
/// after it. Setting the target and resetting the flag are now one decision,
/// and a plain picture cannot be announced while a seek is waiting.
@Suite("Which picture may be announced as the first")
struct FirstFrameGateTests {
    @Test("the first picture of a fresh clip is announced once")
    func freshClip() {
        var gate = FirstFrameGate()
        let first = gate.claimPlainReport()
        let second = gate.claimPlainReport()
        #expect(first)
        #expect(!second, "a second picture is not the first")
    }

    @Test("a picture from before a seek is not announced for the seek")
    func plainPictureDuringSeek() {
        var gate = FirstFrameGate()
        _ = gate.claimPlainReport()
        gate.beginSeek(to: 10.8)
        let claimed = gate.claimPlainReport()
        #expect(!claimed, "the seek has not been satisfied by this")
        #expect(gate.seekTarget == 10.8, "and it is still waiting")
    }

    @Test("the picture that satisfies a seek is announced, with the seek's target")
    func seekSatisfied() {
        var gate = FirstFrameGate()
        _ = gate.claimPlainReport()
        gate.beginSeek(to: 10.8)
        let answered = gate.claimSeekReport()
        let plainAfterwards = gate.claimPlainReport()
        #expect(answered == 10.8)
        #expect(gate.seekTarget == nil, "the seek is over")
        #expect(!plainAfterwards, "and nothing is announced again until the next seek")
    }

    @Test("a second seek replaces the first")
    func secondSeek() {
        var gate = FirstFrameGate()
        _ = gate.claimPlainReport()
        gate.beginSeek(to: 4)
        gate.beginSeek(to: 9)
        #expect(gate.seekTarget == 9)
        let answered = gate.claimSeekReport()
        #expect(answered == 9)
    }

    @Test("nothing to claim for a seek that is not there")
    func noSeek() {
        var gate = FirstFrameGate()
        let answered = gate.claimSeekReport()
        #expect(answered == nil)
    }
}

/// How many pictures may fail to decode before the clip is given up on.
///
/// One packet that will not decode is not a clip that will not decode. Seen
/// in the wild: a packet cut short when a seek abandoned the download it was
/// in the middle of, which the decoder reported seven seconds later, in the
/// same breath as the first good picture of the new position. Failing the
/// clip on that turned a scrub into "Playback failed".
@Suite("How many decode failures are tolerated")
struct DecodeFailureTallyTests {
    @Test("one failure is not the end")
    func oneFailure() {
        var tally = DecodeFailureTally()
        let gaveUp = tally.failed()
        #expect(!gaveUp)
    }

    @Test("a picture in between starts the count again")
    func successResets() {
        var tally = DecodeFailureTally()
        var gaveUp = false
        for _ in 0..<(DecodeFailureTally.limit - 1) { gaveUp = gaveUp || tally.failed() }
        #expect(!gaveUp, "one short of the limit is not the limit")
        tally.succeeded()
        gaveUp = tally.failed()
        #expect(!gaveUp, "the run was broken by a picture")
    }

    @Test("a long unbroken run of failures is the end")
    func sustainedFailure() {
        var tally = DecodeFailureTally()
        var gaveUp = false
        for _ in 0..<DecodeFailureTally.limit { gaveUp = tally.failed() }
        #expect(gaveUp)
    }

    @Test("the limit is about a second of pictures, not a handful")
    func limitIsGenerous() {
        // A truncated packet costs one failure; a scrub landing in a stretch
        // of undecodable pictures costs a few dozen. Neither should fail the
        // clip. A stream that never decodes fails within a second or two.
        #expect(DecodeFailureTally.limit >= 30)
        #expect(DecodeFailureTally.limit <= 120)
    }
}
