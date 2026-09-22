import Foundation

/// The shared audio session, as much of it as anything above this package needs.
///
/// A screen that builds a player and tears it down needs none of this. A
/// screen that keeps one alive across a trip to the background, or across an
/// interruption, has to say so itself: nothing re-activates the session for a
/// player that already exists, and the symptom is a picture that moves in
/// silence.
@MainActor
public enum MediaAudioSession {
    /// Takes the session for playback.
    public static func claim() {
        PlaybackEnvironment.claimAudioSession()
    }

    /// Hands it back, so whatever the reader was listening to can resume.
    public static func release() {
        PlaybackEnvironment.releaseAudioSession()
    }
}
