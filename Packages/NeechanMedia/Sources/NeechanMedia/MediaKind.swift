import Foundation

/// How a piece of media must be presented.
///
/// This is the only thing the rest of the app needs to know about playback: it
/// never sees the underlying engine. WebM cannot be decoded by AVFoundation, so
/// it is routed to the FFmpeg-backed player (wired up in milestone M2).
public enum MediaKind: Sendable, Equatable {
    /// A single still frame: JPEG, PNG, BMP, static WebP.
    case stillImage
    /// A frame sequence decoded by ImageIO: GIF, APNG, animated WebP.
    case animatedImage
    /// VP8/VP9 in a Matroska container. Requires the FFmpeg player.
    case webmVideo
    /// H.264 or HEVC in MP4.
    case mp4Video

    public var isVideo: Bool {
        self == .webmVideo || self == .mp4Video
    }

    /// True when the file must be played by FFmpeg rather than AVFoundation.
    ///
    /// Every video, not only WebM. AVFoundation plays HEVC in an MP4 only when
    /// the track is tagged `hvc1`, and the board serves `hev1` — the same
    /// stream with its parameter sets carried in-band — which it refuses to
    /// open at all, silently. It is equally unhappy with the MP3 audio these
    /// files sometimes carry under an `mp4a` tag. FFmpeg plays both without
    /// complaint, and still decodes H.264 and HEVC through VideoToolbox, so
    /// this costs the hardware path nothing.
    public var requiresFFmpeg: Bool {
        isVideo
    }
}
