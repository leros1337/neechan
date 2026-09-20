import Foundation
import NeechanAPI

/// Fetches the rest of the clip on screen while it plays.
///
/// A clip stalls when its bitrate is higher than the connection can carry, and
/// reading a little way ahead cannot fix that: a 5800 kbps clip needs 722 KB/s
/// sustained, and a connection that manages 400 runs out however far ahead the
/// reader looks. The only thing that does fix it is having the whole file, and
/// having it while the reader is still watching the part that arrived first.
///
/// So this is not the prefetcher's job with a bigger number. `MediaPrefetcher`
/// warms the head of the clip *next* along and gives way the moment the clip on
/// screen wants bytes, which is right for something nobody has asked for. This
/// is the clip on screen; it is waiting precisely because these bytes are
/// missing, so it does not give way.
///
/// The mechanism is the one playback, the prefetcher and `MediaFileCompletion`
/// all share: blocks land in `MediaBlockStore`, and the player's own reader
/// serves its next read from disk without being told anything. Nothing here
/// touches the player.
public actor MediaCompleter {
    public static let shared = MediaCompleter()

    private let store: MediaBlockStore
    private let cache: MediaCache
    private let session: URLSession

    /// The one clip being fetched, and what it is for.
    private var inFlight: (url: URL, task: Task<Void, Never>)?

    public init(
        store: MediaBlockStore = .shared,
        cache: MediaCache = .shared,
        session: URLSession? = nil
    ) {
        self.store = store
        self.cache = cache
        self.session = session ?? Self.makeSession()
    }

    /// A session of its own, deliberately.
    ///
    /// Not the streaming session: its four connections belong to the player,
    /// and `MediaRangeReader` blocks a thread waiting for one, so a fill could
    /// hold the socket the picture is waiting on. Not the prefetcher's either —
    /// that one is a courtesy with an eight-second fuse, and this is not.
    ///
    /// One connection, because the point is to be steadily ahead of the
    /// playhead rather than to race it, and a fill that opens four sockets is
    /// competing with the reader for the same bandwidth it is trying to save.
    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = .shared
        configuration.httpMaximumConnectionsPerHost = 1
        // Generous, unlike the prefetcher's. A block that takes half a minute
        // on a bad connection is still a block the clip needs.
        configuration.timeoutIntervalForRequest = 60
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    /// Fetches whatever of this clip is not on disk, cancelling any other fill.
    ///
    /// Returns as soon as the work is scheduled; the caller is not meant to
    /// wait. Failing is an acceptable outcome — playback carries on streaming
    /// exactly as it would have.
    ///
    /// - Parameter onProgress: how much of the file is on disk, from 0 to 1,
    ///   for the buffer bar on the scrubber.
    public func complete(
        _ url: URL,
        referer: URL?,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async {
        if inFlight?.url == url { return }
        cancelAll()

        // Already whole on disk; there is nothing to fetch.
        if await cache.cachedFile(for: url) != nil {
            onProgress?(1)
            return
        }

        var headers = ["User-Agent": UserAgent.current]
        if let referer { headers["Referer"] = referer.absoluteString }

        let store = store
        let session = session
        // Blocks out of the fill, a fraction into the bar. Asked of the store
        // rather than counted here, because the bar shows the unbroken run from
        // the start and the fill knows only how many blocks it has fetched:
        // after a seek those are not the same number. Hoisted out of the call
        // below because the compiler will not infer it in place.
        var report: (@Sendable (Int, Int) -> Void)?
        if let onProgress {
            report = { _, blocks in
                guard blocks > 0, let total = store.length(for: url) else { return }
                onProgress(Double(store.contiguousBlocks(for: url, total: total)) / Double(blocks))
            }
        }

        let task = Task.detached(priority: .utility) {
            _ = await MediaFileCompletion.fillBlocks(
                for: url, referer: referer, store: store, session: session, onProgress: report
            )
        }
        inFlight = (url, task)
    }

    /// Stops fetching this clip, if it is the one being fetched.
    public func cancel(_ url: URL) {
        guard inFlight?.url == url else { return }
        cancelAll()
    }

    public func cancelAll() {
        inFlight?.task.cancel()
        inFlight = nil
    }

    /// Waits for the fill in flight. For tests; nothing in the app waits.
    public func waitForCurrentFill() async {
        await inFlight?.task.value
    }
}
