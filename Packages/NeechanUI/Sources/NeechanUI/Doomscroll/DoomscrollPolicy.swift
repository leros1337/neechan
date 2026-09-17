import Foundation

/// When the feed warms the next clip, and which one.
///
/// Pulled out of the view model as plain functions so the rules can be asked
/// directly. They are the part most easily got wrong and least easily seen: a
/// feed that warms too eagerly competes with the picture, and one that warms
/// the wrong clip is a download nobody wanted.
enum DoomscrollPolicy {
    /// The clip to fetch the head of, given where the reader has settled.
    ///
    /// Forward only, and one ahead. The clip behind was just played, so its
    /// blocks are already on disk; two ahead is a guess about a reader who is
    /// about to swipe twice, paid for with their data.
    static func clipToWarm<ID: Equatable>(after current: ID, in items: [ID]) -> ID? {
        guard let index = items.firstIndex(of: current), index + 1 < items.count else { return nil }
        return items[index + 1]
    }

    /// Whether warming may start at all.
    ///
    /// Two conditions, for two different reasons.
    ///
    /// `isPlaying` is about contention: until the clip on screen has its header
    /// and first frames, its own reads are the only ones that matter, and a
    /// warm sharing the connection makes the picture the reader is waiting for
    /// arrive later.
    ///
    /// `allowsMediaLoading` is about consent. Opening this mode says the reader
    /// wants to watch, so playback goes ahead whatever the setting says — but
    /// fetching a clip they have not asked for is exactly the speculative
    /// traffic that setting exists to refuse.
    static func mayWarm(isPlaying: Bool, allowsMediaLoading: Bool) -> Bool {
        isPlaying && allowsMediaLoading
    }
}
