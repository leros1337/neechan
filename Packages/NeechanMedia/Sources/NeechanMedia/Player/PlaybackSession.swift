import Foundation

/// The networking playback reads through.
///
/// Its own session, rather than the downloader's: these reads are short,
/// ordered and latency-bound, and they must not queue behind a save of the
/// same clip.
enum PlaybackSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = .shared
        // One for the read the demuxer is waiting on, the rest for fetching
        // ahead of it. With only two, reading ahead queued behind itself and
        // arrived no sooner than the demuxer would have asked anyway.
        configuration.httpMaximumConnectionsPerHost = 4
        // A stalled read holds up the picture, so it is worth giving up on one
        // quickly and asking again. Twenty seconds, which is what this was,
        // is twenty seconds of a frozen picture before anything is even
        // retried; a request that has not answered in eight is not going to
        // save the clip.
        configuration.timeoutIntervalForRequest = 8
        // Fail rather than wait for the network to come back. Waiting is this
        // reader's job, and it can do it while retrying instead of holding one
        // request open for the whole outage.
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}
