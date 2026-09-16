import Foundation
import QuartzCore

/// How often an animation actually needs the screen.
///
/// A display link with no rate asked for wakes on every vsync: 60 or 120 times
/// a second. Almost every GIF on a board runs at 10 to 20 frames a second, so
/// most of those wakeups found the current frame still current and did nothing
/// but cost a main-thread callback. Telling the system the real rate lets it
/// coalesce the rest.
public enum AnimationFrameRate {
    /// The slowest rate worth asking for. Below this the link is woken so rarely
    /// that a frame lands visibly late.
    static let minimumHertz: Float = 10
    /// The fastest. Past this the eye gains nothing from a drawing that is being
    /// scaled into a page anyway.
    static let maximumHertz: Float = 60

    /// The frame rate an animation whose shortest frame lasts `delay` needs.
    public static func hertz(forMinimumDelay delay: TimeInterval) -> Float {
        guard delay > 0 else { return maximumHertz }
        let wanted = Float(1 / delay)
        return min(max(wanted, minimumHertz), maximumHertz)
    }

    /// The range to give a display link for such an animation.
    ///
    /// The maximum is left above the preferred rate so a frame whose delay does
    /// not divide evenly into the refresh rate is still shown close to on time.
    public static func range(forMinimumDelay delay: TimeInterval) -> CAFrameRateRange {
        let preferred = hertz(forMinimumDelay: delay)
        return CAFrameRateRange(
            minimum: preferred,
            maximum: min(preferred * 2, maximumHertz),
            preferred: preferred
        )
    }
}
