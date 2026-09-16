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

        if let userAgent = options.userAgent {
            ksOptions.userAgent = userAgent
        }
        if let referer = options.referer {
            ksOptions.referer = referer.absoluteString
        }
        if let cookieHeader = options.cookieHeader {
            ksOptions.appendHeader(["Cookie": cookieHeader])
        }

        // WebM must go through the FFmpeg engine; MP4 is left to AVFoundation,
        // which decodes H.264 and HEVC in hardware.
        if options.requiresSoftwareDecoding {
            KSOptions.firstPlayerType = KSMEPlayer.self
            KSOptions.secondPlayerType = nil
        } else {
            KSOptions.firstPlayerType = KSAVPlayer.self
            KSOptions.secondPlayerType = KSMEPlayer.self
        }
        return ksOptions
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
