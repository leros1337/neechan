import Foundation

/// Decides which decoded picture is announced as "the first one to show".
///
/// The player starts its clock on that announcement, so a wrong one starts
/// the clock against an empty renderer: it runs on, and every picture that
/// then arrives is already in the past. That happened when a seek and a
/// picture of the old position crossed: the seek reset the "already said it"
/// flag, the picture's push had begun before the reset and finished after it,
/// and its announcement was taken for the seek's. Here the seek's target and
/// the flag are one value, changed together under one lock, so a picture that
/// is not for the seek can never be announced while a seek is waiting.
///
/// A plain value; the pipeline keeps it behind a `Mutex`.
struct FirstFrameGate: Sendable {
    /// Where the seek being waited on is heading, if there is one.
    private(set) var seekTarget: TimeInterval?
    private var hasReported = false

    /// A seek has begun: what is announced next must be for it.
    mutating func beginSeek(to target: TimeInterval) {
        seekTarget = target
        hasReported = false
    }

    /// Whether a picture pushed outside any seek may be announced.
    ///
    /// True exactly once for a fresh clip. False while a seek is waiting,
    /// whatever the flag says, because a picture that did not pass the seek's
    /// own filter is from the old position.
    mutating func claimPlainReport() -> Bool {
        guard seekTarget == nil, !hasReported else { return false }
        hasReported = true
        return true
    }

    /// The seek that the picture just pushed has satisfied, ending it.
    ///
    /// Nil when no seek was waiting.
    mutating func claimSeekReport() -> TimeInterval? {
        guard let target = seekTarget else { return nil }
        seekTarget = nil
        hasReported = true
        return target
    }
}

/// Counts pictures that failed to decode, and says when enough is enough.
///
/// A packet that will not decode is ordinary: a download cut short by a
/// seek, a damaged stretch of a file, a scrub landing between keyframes. The
/// decoder recovers at the next keyframe, so the clip carries on and the
/// reader sees at most a flicker. What is not ordinary is a stream where
/// nothing decodes, which is what the limit is for.
struct DecodeFailureTally: Sendable {
    /// How many failures in a row are tolerated before the clip is failed.
    ///
    /// About a second of pictures at the frame rate a phone shoots.
    static let limit = 60

    private var consecutive = 0

    /// A picture came out; whatever failed before is behind us.
    mutating func succeeded() {
        consecutive = 0
    }

    /// A packet failed. True when it is time to give the clip up.
    mutating func failed() -> Bool {
        consecutive += 1
        return consecutive >= Self.limit
    }
}
