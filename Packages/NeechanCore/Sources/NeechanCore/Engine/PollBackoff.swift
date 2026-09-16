import Foundation

/// How long to wait before asking the site again, given how long it has had
/// nothing to say.
///
/// A fixed interval spends the same radio time on a thread nobody has posted in
/// for an hour as on one being written in, and the radio is the most expensive
/// thing either of these loops does. Backing off is also what a reader would
/// choose: the interval they picked is the *fastest* they want to be told, not a
/// promise to keep asking at that rate forever.
public enum PollBackoff {
    /// Quiet polls allowed at the reader's own interval before backing off.
    ///
    /// One, so that a single empty poll between two busy ones does not slow the
    /// thread down; a conversation with a gap in it stays responsive.
    private static let grace = 1

    /// Bounds the shift so a long-abandoned thread cannot overflow the multiply.
    private static let maximumDoublings = 16

    /// The wait before the next poll.
    ///
    /// - Parameters:
    ///   - base: the interval the reader asked for.
    ///   - quiet: consecutive polls that found nothing.
    ///   - cap: the longest this is ever allowed to become.
    ///   - lowPower: whether the device is in Low Power Mode, which doubles it.
    public static func interval(
        base: Duration,
        quiet: Int,
        cap: Duration,
        lowPower: Bool = false
    ) -> Duration {
        guard base > .zero else { return base }

        let doublings = min(max(0, quiet - grace), maximumDoublings)
        var wait = base * (1 << doublings)
        if lowPower { wait = wait * 2 }
        return min(wait, cap)
    }
}
