import CoreMedia
import Foundation
import Testing
@testable import NeechanMedia

/// Turning a stream's own counting into Core Media's.
///
/// Sync between picture and sound is decided here: a rounding error repeated
/// every frame is what makes a long clip drift.
@Suite("Timestamps")
struct TimeMathTests {
    @Test("a millisecond time base needs no arithmetic at all")
    func matroskaTimeBase() {
        // What Matroska almost always uses, so it is worth being exact.
        let time = TimeMath.time(1_500, numerator: 1, denominator: 1_000)
        #expect(TimeMath.seconds(time) == 1.5)
        #expect(time.timescale == 1_000)
    }

    @Test("a ninety-kilohertz time base is kept exact")
    func mp4TimeBase() {
        let time = TimeMath.time(90_000, numerator: 1, denominator: 90_000)
        #expect(TimeMath.seconds(time) == 1)
    }

    @Test("a time base that is not a plain timescale folds into the value")
    func fractionalTimeBase() {
        // 1001/30000 is 29.97 fps, where rounding to a fixed timescale drifts.
        let time = TimeMath.time(30, numerator: 1_001, denominator: 30_000)
        #expect(TimeMath.seconds(time) == 30.0 * 1_001.0 / 30_000.0)
        #expect(time.value == 30 * 1_001)
        #expect(time.timescale == 30_000)
    }

    @Test("an absent timestamp is not a time")
    func absentTimestamps() {
        #expect(!TimeMath.time(FFmpegStatus.noTimestamp, numerator: 1, denominator: 1_000).isValid)
        #expect(!TimeMath.time(0, numerator: 1, denominator: 0).isValid)
        #expect(!TimeMath.time(0, numerator: 0, denominator: 1_000).isValid)
    }

    @Test("a packet with no presentation time falls back to its decode time")
    func decodeTimeIsTheFallback() {
        let both = TimeMath.presentation(pts: 100, dts: 50, numerator: 1, denominator: 1_000)
        #expect(TimeMath.seconds(both) == 0.1)

        let onlyDecode = TimeMath.presentation(
            pts: FFmpegStatus.noTimestamp, dts: 50, numerator: 1, denominator: 1_000
        )
        #expect(TimeMath.seconds(onlyDecode) == 0.05)

        let neither = TimeMath.presentation(
            pts: FFmpegStatus.noTimestamp, dts: FFmpegStatus.noTimestamp,
            numerator: 1, denominator: 1_000
        )
        #expect(!neither.isValid)
    }

    @Test("a frame lasts what the packet says")
    func packetDurationWins() {
        let duration = TimeMath.duration(
            packetDuration: 33, numerator: 1, denominator: 1_000,
            frameRateNumerator: 15, frameRateDenominator: 1
        )
        #expect(TimeMath.seconds(duration) == 0.033)
    }

    /// A WebM whose frame rate varies often carries no packet duration.
    @Test("with no packet duration the stream's frame rate is used")
    func frameRateIsTheFallback() {
        let duration = TimeMath.duration(
            packetDuration: 0, numerator: 1, denominator: 1_000,
            frameRateNumerator: 15, frameRateDenominator: 1
        )
        #expect(TimeMath.seconds(duration) == 1.0 / 15)
    }

    @Test("with neither, the renderer is told nothing rather than something wrong")
    func noDurationAtAll() {
        let duration = TimeMath.duration(
            packetDuration: 0, numerator: 1, denominator: 1_000,
            frameRateNumerator: 0, frameRateDenominator: 0
        )
        #expect(!duration.isValid)
    }

    @Test("seconds of a time that is not one is zero, not a crash")
    func secondsOfNonsense() {
        #expect(TimeMath.seconds(.invalid) == 0)
        #expect(TimeMath.seconds(.indefinite) == 0)
    }
}
