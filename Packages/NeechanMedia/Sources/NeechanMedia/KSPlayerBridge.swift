@preconcurrency import KSPlayer
import Foundation
import NeechanAPI
import SwiftUI

/// The only place in the app that touches KSPlayer.
///
/// KSPlayer is written for Swift 5 and its types are not `Sendable`, so
/// everything here stays on the main actor and only value types cross out of
/// this file.
@MainActor
enum KSPlayerBridge {
    /// Applies the app-wide engine defaults. Safe to call more than once.
    static func configureEngineOnce() {
        guard !hasConfigured else { return }
        hasConfigured = true

        // AVFoundation cannot open VP8 or VP9 at all, so anything this app
        // hands to the first player would fail and fall through, costing an
        // extra open. Per-item options pick the engine instead.
        KSOptions.isAutoPlay = true
        KSOptions.isLoopPlay = false
        KSOptions.hardwareDecode = true
        // Short clips, so a small buffer starts playback sooner.
        KSOptions.preferredForwardBufferDuration = 2
        KSOptions.maxBufferDuration = 20
        KSOptions.isSecondOpen = true
        KSOptions.isAccurateSeek = true
    }

    private static var hasConfigured = false

    /// Translates the app's options into the engine's.
    static func makeOptions(from options: MediaPlayerOptions) -> KSOptions {
        configureEngineOnce()

        let ksOptions = KSOptions()
        // The engine's own loop flag is deliberately left off, whatever the
        // reader chose.
        //
        // Both engines only arrange looping while opening a file, and both stop
        // reporting that a clip ended once the flag is set. Turning it on
        // part-way through therefore left the clip stopped on its last frame
        // with nothing to tell the app it had finished. The app restarts the
        // clip itself instead, which works the same for WebM and MP4 and at any
        // point during playback.
        ksOptions.isLoopPlay = false
        ksOptions.isAccurateSeek = true

        // Hardware decoding only where VideoToolbox has a decoder: H.264 and
        // HEVC in MP4. With it on, the engine asks VideoToolbox to take every
        // video stream, and for VP8/VP9 there is nothing to take it — the
        // hwaccel setup fails, the decoder never produces a frame, and the
        // viewer reports that playback failed. The simulator has no VP9
        // decoder at all, and real devices only sometimes; software VP9 is
        // what actually plays, and these clips are short enough for it.
        ksOptions.hardwareDecode = options.kind == .mp4Video
        ksOptions.asynchronousDecompression = false

        if let userAgent = options.userAgent {
            ksOptions.userAgent = userAgent
        }
        if let referer = options.referer {
            ksOptions.referer = referer.absoluteString
        }
        if let cookieHeader = options.cookieHeader {
            ksOptions.appendHeader(["Cookie": cookieHeader])
        }

        return ksOptions
    }

    /// Picks the engine, immediately before a player is built.
    ///
    /// Deliberately not part of `makeOptions`: which engine KSPlayer uses is
    /// **global** state, while options are built for every page in a gallery,
    /// including the stills. Setting it there meant the last page SwiftUI
    /// happened to evaluate decided the engine for the page actually playing —
    /// so a WebM opened after an image or an MP4 was handed to AVFoundation,
    /// which cannot decode VP9, and the viewer said the video could not be
    /// played. It is called where the player is created, from that player's
    /// own options.
    /// The engine's options for a player about to be created, with the engine
    /// itself selected for this file.
    static func playerOptions(for options: MediaPlayerOptions) -> KSOptions {
        selectEngine(for: options)
        return makeOptions(from: options)
    }

    static func selectEngine(for options: MediaPlayerOptions) {
        configureEngineOnce()

        // Video goes through FFmpeg, MP4 included: the board serves HEVC tagged
        // `hev1`, which AVFoundation will not open, and a file it cannot open
        // shows nothing rather than reporting a failure the second engine could
        // pick up.
        if options.requiresSoftwareDecoding {
            KSOptions.firstPlayerType = KSMEPlayer.self
            KSOptions.secondPlayerType = nil
        } else {
            KSOptions.firstPlayerType = KSAVPlayer.self
            KSOptions.secondPlayerType = KSMEPlayer.self
        }
    }

    /// Maps the engine's state onto the app's.
    static func playbackState(from state: KSPlayerState) -> PlaybackState {
        switch state {
        case .initialized: .idle
        case .preparing: .preparing
        case .readyToPlay, .bufferFinished: .playing
        case .buffering: .buffering
        case .paused: .paused
        case .playedToTheEnd: .finished
        case .error: .failed(String(localized: "Playback failed.", bundle: .module, locale: AppLocale.current))
        }
    }
}
