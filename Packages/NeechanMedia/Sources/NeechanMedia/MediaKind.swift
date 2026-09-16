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
    /// H.264/HEVC in MP4. AVFoundation can decode this in hardware.
    case mp4Video

    public var isVideo: Bool {
        self == .webmVideo || self == .mp4Video
    }

    /// True when AVFoundation cannot open the file and FFmpeg must be used.
    public var requiresFFmpeg: Bool {
        self == .webmVideo
    }
}
