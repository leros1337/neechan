import Foundation

/// The shared audio session, as much of it as anything above this package needs.
///
/// The engine claims the session inside a player's own initialiser and gives it
/// up when a player view goes away, which is right for a screen that builds one
/// player and tears it down. A screen that keeps one player alive across a trip
/// to the background, or across an interruption, has to say so itself: nothing
/// re-activates the session for a player that already exists, and the symptom
/// is a picture that moves in silence.
@MainActor
public enum MediaAudioSession {
    /// Takes the session for playback.
    public static func claim() {
        KSPlayerBridge.claimAudioSession()
    }

    /// Hands it back, so whatever the reader was listening to can resume.
    public static func release() {
        KSPlayerBridge.releaseAudioSession()
    }
}
