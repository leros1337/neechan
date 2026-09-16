@preconcurrency import KSPlayer
import FFmpegKit
import Foundation

/// Feeds the decoder from the network, a piece at a time.
///
/// The decoder normally opens a URL with FFmpeg's own HTTP client, which 2ch
/// refuses. Handing it one of these instead means FFmpeg reads through
/// `MediaRangeReader`, so the bytes arrive on `URLSession` carrying the app's
/// cookies and Apple's TLS, while playback still begins as soon as the header
/// and the first frames have landed rather than after the whole file.
///
/// Every method here is called from the decoder's demuxing thread and is
/// expected to block, exactly as reading a file would.
final class StreamingAVIOContext: AbstractAVIOContext {
    private let reader: MediaRangeReader
    private let lock = NSLock()
    private var offset: Int64 = 0

    init(reader: MediaRangeReader) {
        self.reader = reader
        // Larger than the 32 KB default. Each read crosses into our own
        // networking, and the demuxer asks constantly while it works out what
        // the file is.
        super.init(bufferSize: 256 << 10, writable: false)
    }

    override func read(buffer: UnsafePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return swift_AVERROR_EOF }

        let start = lock.withLock { offset }
        let copied = reader.read(
            into: UnsafeMutablePointer(mutating: buffer), at: start, count: Int(size)
        )
        guard copied > 0 else {
            // Nothing left, or nothing reachable. Both end the read as far as
            // the demuxer is concerned; a failure it could retry would only
            // have it spin against a server that is refusing us.
            return swift_AVERROR_EOF
        }
        lock.withLock { offset += Int64(copied) }
        return Int32(copied)
    }

    override func seek(offset newOffset: Int64, whence: Int32) -> Int64 {
        let resolved: Int64
        switch whence {
        case Int32(SEEK_SET):
            resolved = newOffset
        case Int32(SEEK_CUR):
            resolved = lock.withLock { offset } + newOffset
        case Int32(SEEK_END):
            guard let total = reader.length() else { return -1 }
            resolved = total + newOffset
        default:
            return -1
        }
        guard resolved >= 0 else { return -1 }
        lock.withLock { offset = resolved }
        return resolved
    }

    /// The decoder asks for this before it will let anyone scrub.
    override func fileSize() -> Int64 {
        reader.length() ?? -1
    }
}

/// The engine's options, with remote reading routed through the app.
///
/// `process(url:)` is the decoder asking whether someone else would rather do
/// the reading. A local file is left alone, so a clip already in the media cache
/// plays exactly as it did before.
final class StreamingPlayerOptions: KSOptions {
    private let headers: [String: String]
    private let session: URLSession

    init(headers: [String: String], session: URLSession = StreamingPlayerOptions.sharedSession) {
        self.headers = headers
        self.session = session
        super.init()
    }

    override func process(url: URL) -> AbstractAVIOContext? {
        guard !url.isFileURL else { return nil }
        return StreamingAVIOContext(
            reader: MediaRangeReader(
                url: url, headers: headers, session: session, store: .shared
            )
        )
    }

    /// One session for playback reads.
    ///
    /// Its own, rather than the downloader's: these reads are short, ordered and
    /// latency-bound, and they must not queue behind a save of the same clip.
    static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = .shared
        configuration.httpMaximumConnectionsPerHost = 2
        // A stalled read holds up the picture, so it is worth giving up on one
        // and letting the demuxer ask again.
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()
}
