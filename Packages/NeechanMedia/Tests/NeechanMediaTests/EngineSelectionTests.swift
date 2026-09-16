import Foundation
import Testing
@preconcurrency import KSPlayer
@testable import NeechanMedia

/// Which engine a file is opened with.
///
/// The choice is global to KSPlayer, so it has to be made for the file being
/// played and nothing else. It used to be made while building options, which a
/// gallery does for every page it holds: a WebM opened after an image or an MP4
/// was handed to AVFoundation, which cannot decode VP9, and the viewer reported
/// that the video could not be played.
@Suite("Engine selection", .serialized)
@MainActor
struct EngineSelectionTests {
    private var currentEngine: String {
        String(describing: KSOptions.firstPlayerType)
    }

    @Test("video is opened by FFmpeg, whatever the container")
    func videoUsesFFmpeg() {
        for kind in [MediaKind.webmVideo, .mp4Video] {
            KSPlayerBridge.selectEngine(for: MediaPlayerOptions(kind: kind))
            #expect(currentEngine == "KSMEPlayer", "\(kind) should be decoded by FFmpeg")
        }
    }

    @Test("building options for another page does not change the engine")
    func optionsDoNotSelectTheEngine() {
        KSPlayerBridge.selectEngine(for: MediaPlayerOptions(kind: .webmVideo))

        // What a gallery does for every page it holds, including the stills.
        _ = KSPlayerBridge.makeOptions(from: MediaPlayerOptions(kind: .stillImage))
        _ = KSPlayerBridge.makeOptions(from: MediaPlayerOptions(kind: .mp4Video))

        #expect(currentEngine == "KSMEPlayer", "another page's options changed the engine")
    }

    /// VideoToolbox has decoders for H.264 and HEVC and none for VP8 or VP9.
    /// Asking it anyway breaks the decoder rather than falling back.
    @Test("hardware decoding is asked for only where VideoToolbox can do it")
    func hardwareDecodeOnlyForMP4() {
        #expect(KSPlayerBridge.makeOptions(from: MediaPlayerOptions(kind: .mp4Video)).hardwareDecode)
        #expect(KSPlayerBridge.makeOptions(from: MediaPlayerOptions(kind: .webmVideo)).hardwareDecode == false)
    }

    @Test("the options a player is given carry the engine choice with them")
    func playerOptionsSelectTheEngine() {
        KSPlayerBridge.selectEngine(for: MediaPlayerOptions(kind: .stillImage))

        _ = KSPlayerBridge.playerOptions(for: MediaPlayerOptions(kind: .webmVideo))

        #expect(currentEngine == "KSMEPlayer")
    }
}
