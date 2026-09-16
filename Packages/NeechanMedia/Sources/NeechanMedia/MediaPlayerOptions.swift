import Foundation

/// How a piece of media should be played.
///
/// Deliberately engine-agnostic: the app describes what it wants and
/// `KSPlayerBridge` translates it, so nothing above this module depends on
/// FFmpeg or KSPlayer.
public struct MediaPlayerOptions: Sendable, Equatable {
    /// What the file is, which decides which engine can open it.
    public var kind: MediaKind
    /// Sent so the site does not refuse the request as a hotlink.
    public var referer: URL?
    /// Matched to the app's own requests; media hosts filter on it.
    public var userAgent: String?
    /// Cookies for the media host, as `name=value` pairs.
    public var cookies: [String: String]
    /// Repeat when the clip ends. Off unless the reader asks for it.
    public var loops: Bool
    public var autoplays: Bool
    public var startsMuted: Bool

    public init(
        kind: MediaKind,
        referer: URL? = nil,
        userAgent: String? = nil,
        cookies: [String: String] = [:],
        loops: Bool = false,
        autoplays: Bool = true,
        startsMuted: Bool = false
    ) {
        self.kind = kind
        self.referer = referer
        self.userAgent = userAgent
        self.cookies = cookies
        self.loops = loops
        self.autoplays = autoplays
        self.startsMuted = startsMuted
    }

    /// True when the file must be decoded by FFmpeg rather than AVFoundation.
    ///
    /// WebM is the whole reason this app carries an FFmpeg build: AVFoundation
    /// cannot open VP8 or VP9 at all. MP4 goes to AVFoundation, which decodes
    /// H.264 and HEVC in hardware and costs far less battery.
    public var requiresSoftwareDecoding: Bool {
        kind.requiresFFmpeg
    }

    /// The cookie header value, or nil when there are no cookies to send.
    public var cookieHeader: String? {
        guard !cookies.isEmpty else { return nil }
        return cookies
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
    }

    /// HTTP headers the player must send with its own requests.
    public var httpHeaders: [String: String] {
        var headers: [String: String] = [:]
        if let userAgent { headers["User-Agent"] = userAgent }
        if let referer { headers["Referer"] = referer.absoluteString }
        if let cookieHeader { headers["Cookie"] = cookieHeader }
        return headers
    }
}
