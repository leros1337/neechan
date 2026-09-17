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

    /// The reader's autoplay preference is global to the engine and read when a
    /// player is built, so it has to be set alongside the engine choice. It was
    /// offered in settings and hardcoded on.
    @Test("autoplay follows the reader's choice")
    func autoplayFollowsTheOptions() {
        KSPlayerBridge.selectEngine(
            for: MediaPlayerOptions(kind: .mp4Video, autoplays: false)
        )
        #expect(KSOptions.isAutoPlay == false)

        KSPlayerBridge.selectEngine(
            for: MediaPlayerOptions(kind: .mp4Video, autoplays: true)
        )
        #expect(KSOptions.isAutoPlay)
    }

    @Test("a short clip is not handed to the lock screen")
    func remoteControlIsOff() {
        let options = KSPlayerBridge.makeOptions(
            from: MediaPlayerOptions(kind: .webmVideo)
        )
        #expect(options.registerRemoteControll == false)
    }
}

/// The options one player view holds, when the media it shows changes.
///
/// A viewer that mounts a player per clip never meets this. A feed that keeps
/// one player and swaps its URL meets it on the first clip after an MP4.
@Suite("Engine options for a reused player", .serialized)
@MainActor
struct EngineOptionsBoxTests {
    @Test("the same media is not rebuilt")
    func sameOptionsAreKept() {
        let box = EngineOptionsBox()
        let options = MediaPlayerOptions(kind: .webmVideo)

        let first = box.options(for: options)
        let second = box.options(for: options)

        #expect(first === second, "identical options were built twice")
    }

    /// The regression this exists for: VideoToolbox has no VP9 decoder, so
    /// carrying an MP4's `hardwareDecode` onto a WebM breaks it.
    @Test("changing the media rebuilds, so hardware decoding is not carried over")
    func changedOptionsAreRebuilt() {
        let box = EngineOptionsBox()

        let mp4 = box.options(for: MediaPlayerOptions(kind: .mp4Video))
        #expect(mp4.hardwareDecode, "an MP4 should be decoded in hardware")

        let webm = box.options(for: MediaPlayerOptions(kind: .webmVideo))
        #expect(webm !== mp4, "the options were reused for different media")
        #expect(!webm.hardwareDecode, "VP9 was handed to VideoToolbox, which cannot decode it")
    }

    /// Anything the options carry, not only the kind — headers change between
    /// sites, and a stale Referer is refused as a hotlink.
    @Test("a change other than the kind rebuilds too")
    func headersAreNotCarriedOver() {
        let box = EngineOptionsBox()
        let first = box.options(for: MediaPlayerOptions(kind: .webmVideo, referer: URL(string: "https://2ch.org")))
        let second = box.options(for: MediaPlayerOptions(kind: .webmVideo, referer: URL(string: "https://boards.4chan.org")))

        #expect(first !== second, "the referer change was ignored")
    }
}
