import CoreMedia
import Testing
@testable import NeechanMedia

/// Placing runs of sound end to end, whatever the container stamped them with.
@Suite("Audio timeline")
struct AudioTimelineTests {
    private func ms(_ value: Int64) -> CMTime { CMTime(value: value, timescale: 1000) }

    private func end(of start: CMTime, samples: Int32, rate: Int32) -> CMTime {
        start + CMTime(value: CMTimeValue(samples), timescale: rate)
    }

    /// The opening of a real 2ch Vorbis clip that crackled: Vorbis switches
    /// between 128, 576 and 1024 samples a frame, and the container rounds
    /// every one of them to the millisecond.
    @Test("runs stamped to the millisecond play back to back")
    func millisecondStampsAreJoined() {
        let frames: [(pts: Int64, samples: Int32)] = [
            (3, 576), (15, 1024), (36, 576), (48, 128), (51, 128), (53, 128),
            (56, 128), (59, 128), (61, 128), (64, 128), (67, 128), (69, 128),
            (72, 128), (75, 128), (77, 128), (80, 576), (92, 1024), (113, 1024),
            (135, 1024), (156, 1024)
        ]
        var timeline = AudioTimeline(sampleRate: 48_000)

        var previousEnd: CMTime?
        for frame in frames {
            let start = timeline.place(ms(frame.pts), sampleCount: frame.samples)
            if let previousEnd {
                #expect(start == previousEnd, "a gap or overlap at \(frame.pts) ms")
            }
            previousEnd = end(of: start, samples: frame.samples, rate: 48_000)
        }
    }

    @Test("the first run starts where it was stamped")
    func firstRunAnchors() {
        var timeline = AudioTimeline(sampleRate: 48_000)
        #expect(timeline.place(ms(3), sampleCount: 576) == ms(3))
    }

    @Test("a real gap in the file is kept, not papered over")
    func realGapReanchors() {
        var timeline = AudioTimeline(sampleRate: 48_000)
        _ = timeline.place(ms(0), sampleCount: 960)
        // Half a second missing from the file.
        #expect(timeline.place(ms(520), sampleCount: 960) == ms(520))
    }

    @Test("after a reset the next run starts where it was stamped")
    func resetReanchors() {
        var timeline = AudioTimeline(sampleRate: 48_000)
        _ = timeline.place(ms(0), sampleCount: 1024)
        timeline.reset()
        // Within the tolerance of where the last run ended, which without the
        // reset would have been joined on to it.
        #expect(timeline.place(ms(22), sampleCount: 1024) == ms(22))
    }

    @Test("a run with no stamp follows on from the one before")
    func missingStampFollowsOn() {
        var timeline = AudioTimeline(sampleRate: 48_000)
        _ = timeline.place(ms(10), sampleCount: 1024)
        #expect(timeline.place(.invalid, sampleCount: 1024) == end(of: ms(10), samples: 1024, rate: 48_000))
    }

    @Test("with nothing to go on the first run starts at zero")
    func missingFirstStampStartsAtZero() {
        var timeline = AudioTimeline(sampleRate: 48_000)
        #expect(timeline.place(.invalid, sampleCount: 1024) == .zero)
    }
}
