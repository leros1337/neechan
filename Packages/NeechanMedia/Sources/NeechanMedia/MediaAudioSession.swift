import Foundation

/// The shared audio session, as much of it as anything above this package needs.
///
/// A screen needs none of this to play a clip. The players take the sound
/// from other apps while they are heard and give it back when they stop being
/// heard: paused, muted, finished, closed, or sent to the background. These
/// are for a screen that has to step in all the same.
@MainActor
public enum MediaAudioSession {
    /// Takes the sound again, if a player is being heard.
    public static func claim() {
        PlaybackEnvironment.claimAudioSession()
    }

    /// Hands it back at once, so whatever the reader was listening to can resume.
    public static func release() {
        PlaybackEnvironment.releaseAudioSession()
    }
}
