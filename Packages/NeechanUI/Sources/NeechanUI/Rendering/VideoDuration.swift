import NeechanAPI

/// A clip's length as minutes and seconds: `0:42`, `1:23`, `62:05`.
///
/// One formatter for the corner of a thumbnail and the end of the player's
/// scrubber, so the two never disagree about the same clip.
enum VideoDuration {
    static func label(seconds: Int) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }
}

extension Attachment {
    /// The length to print on a video's thumbnail, or nil when there is none
    /// to print: not a video, or a site that did not say.
    var durationLabel: String? {
        guard isVideo, let seconds = durationSeconds, seconds > 0 else { return nil }
        return VideoDuration.label(seconds: seconds)
    }
}
