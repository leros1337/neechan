import CoreMedia

/// Where each run of sound goes, counted in samples rather than taken from
/// the container.
///
/// The audio renderer plays a run at exactly the time it is given, so a run
/// that starts a fraction of a millisecond before the last one ended cuts
/// into it, and one that starts after leaves a hole. Either is a click.
/// Matroska stamps every frame to the millisecond, and a Vorbis frame of 128,
/// 576 or 1024 samples never lasts a whole number of them: a WebM with Vorbis
/// clicked on nearly every frame, which is heard as crackling. Opus is spared
/// only because its frames last exactly 20 ms, and even it was off by half a
/// millisecond after the first frame, which the decoder trims.
///
/// So the first run is put where the container says, and every run after it
/// starts where the one before ended. The container is believed again only
/// when it disagrees by more than rounding could explain, which is a real gap
/// in the file.
struct AudioTimeline {
    let sampleRate: Int32

    /// How far the container may disagree before it is taken to mean it.
    ///
    /// Far above the half a tick a millisecond time base rounds by, and below
    /// anything anyone notices as sound out of step with the picture.
    static let tolerance = CMTime(value: 20, timescale: 1000)

    /// Where the next run starts if nothing says otherwise.
    private var next: CMTime = .invalid

    init(sampleRate: Int32) {
        self.sampleRate = sampleRate
    }

    /// Where a run stamped `stamped` and `sampleCount` samples long should be
    /// played.
    mutating func place(_ stamped: CMTime, sampleCount: Int32) -> CMTime {
        let start: CMTime
        if next.isValid, !stamped.isValid || CMTimeAbsoluteValue(stamped - next) <= Self.tolerance {
            start = next
        } else if stamped.isValid {
            start = CMTimeConvertScale(stamped, timescale: sampleRate, method: .roundHalfAwayFromZero)
        } else {
            start = CMTime(value: 0, timescale: sampleRate)
        }
        next = start + CMTime(value: CMTimeValue(sampleCount), timescale: sampleRate)
        return start
    }

    /// Forgets where the last run ended, so the next one is put where the
    /// container says. What a seek needs.
    mutating func reset() {
        next = .invalid
    }
}
