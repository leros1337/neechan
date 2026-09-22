import Foundation
#if canImport(AVFAudio)
import AVFAudio
#endif
#if canImport(UIKit)
import UIKit
#endif

/// The things playing a video does to the rest of the device.
///
/// Moved here from the old engine bridge unchanged: the engine turned the idle
/// timer off when it started and back on when it was paused or stopped, but
/// not when a clip simply reached its end, and it claimed the audio session
/// inside a player's initialiser and never gave it back.
@MainActor
enum PlaybackEnvironment {
    /// Keeps the screen on, or lets it sleep again.
    static func keepScreenAwake(_ keepAwake: Bool) {
        #if canImport(UIKit) && !os(watchOS)
        UIApplication.shared.isIdleTimerDisabled = keepAwake
        #endif
    }

    /// Takes the audio session for playback.
    ///
    /// Needed on every resume, not only at the start: a player paused for an
    /// interruption, or kept alive across a trip to the background, comes back
    /// to a session nothing has re-activated, and the symptom is a picture
    /// that moves in silence.
    static func claimAudioSession() {
        #if canImport(AVFAudio) && os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
        try? session.setActive(true)
        #endif
    }

    /// Hands it back, so whatever the reader was listening to can resume.
    static func releaseAudioSession() {
        #if canImport(AVFAudio) && os(iOS)
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
        #endif
    }
}
