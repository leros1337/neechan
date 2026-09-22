import CoreMedia
import Foundation

/// FFmpeg's timestamps, in Core Media's terms.
///
/// FFmpeg counts in units of a stream's own time base, which is a fraction of
/// a second and differs between containers: Matroska usually counts
/// milliseconds, MP4 whatever the track was written with. Core Media wants a
/// value and a timescale, so the fraction has to be folded in without losing
/// the exactness that keeps audio and video together over a long clip.
enum TimeMath {
    /// A timestamp counted in `numerator/denominator` seconds.
    ///
    /// The common case is a numerator of one, where the time base is already a
    /// timescale and nothing has to be multiplied. Anything else is folded
    /// into the value, which keeps the result exact rather than rounding it
    /// into a fixed timescale.
    static func time(_ value: Int64, numerator: Int32, denominator: Int32) -> CMTime {
        guard value != FFmpegStatus.noTimestamp, numerator > 0, denominator > 0 else {
            return .invalid
        }
        guard numerator == 1 else {
            let (scaled, overflowed) = value.multipliedReportingOverflow(by: Int64(numerator))
            guard !overflowed else { return .invalid }
            return CMTime(value: scaled, timescale: denominator)
        }
        return CMTime(value: value, timescale: denominator)
    }

    /// When to present a packet: its own timestamp, or the decode timestamp
    /// when it has none.
    ///
    /// A stream with B-frames carries both, and some Matroska files carry only
    /// the decode one. Presenting in decode order is wrong for a reordered
    /// stream, but it is a picture rather than nothing, and the decoder
    /// reorders anything it can.
    static func presentation(
        pts: Int64, dts: Int64, numerator: Int32, denominator: Int32
    ) -> CMTime {
        let chosen = pts != FFmpegStatus.noTimestamp ? pts : dts
        return time(chosen, numerator: numerator, denominator: denominator)
    }

    /// How long a frame stays on screen.
    ///
    /// The packet says so when it can. A WebM whose frame rate varies often
    /// cannot, and then the stream's average is the best guess available;
    /// with neither, the renderer is told nothing and shows the frame until
    /// the next one arrives.
    static func duration(
        packetDuration: Int64,
        numerator: Int32,
        denominator: Int32,
        frameRateNumerator: Int32,
        frameRateDenominator: Int32
    ) -> CMTime {
        if packetDuration > 0 {
            return time(packetDuration, numerator: numerator, denominator: denominator)
        }
        guard frameRateNumerator > 0, frameRateDenominator > 0 else { return .invalid }
        return CMTime(value: Int64(frameRateDenominator), timescale: frameRateNumerator)
    }

    /// Seconds, for the progress the app reports.
    static func seconds(_ time: CMTime) -> TimeInterval {
        guard time.isValid, !time.isIndefinite, time.timescale != 0 else { return 0 }
        return CMTimeGetSeconds(time)
    }
}
