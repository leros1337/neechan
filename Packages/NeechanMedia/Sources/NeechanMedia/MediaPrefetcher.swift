import Foundation
import NeechanAPI

/// Fetches the opening seconds of a clip before anyone asks to watch it.
///
/// A feed that pages one video at a time stalls on every swipe otherwise: the
/// demuxer has to fetch a header and a first frame before there is a picture,
/// and that is a round trip the reader spends looking at black. Warming the
/// head of the *next* clip while the current one plays hides that entirely.
///
/// Only the head. Whole-file downloads belong to saving, and a feed would be
/// pulling clips the reader swipes past in two seconds.
///
/// The mechanism is the one playback and `MediaFileCompletion` already use:
/// reading a single byte inside a block makes `MediaRangeReader` fetch and keep
/// the whole 1 MB of it. Nothing needs to know afterwards — when the reader
/// arrives, the player is handed the same remote URL and its reader serves
/// those blocks from disk.
public actor MediaPrefetcher {
    public static let shared = MediaPrefetcher()

    /// How much of a clip counts as its head.
    ///
    /// Two blocks: one is often not enough to get past a WebM's header and
    /// first keyframe, and more is a gamble on a clip the reader may never
    /// reach.
    public static let defaultWarmBytes = 2 << 20

    private let store: MediaBlockStore
    private let cache: MediaCache
    private let session: URLSession

    /// The one warm allowed to be in flight, and what it is for.
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
    /// Not the streaming session: its two connections per host belong to the
    /// clip on screen, and `MediaRangeReader` blocks its thread waiting for
    /// one, so a warm could hold a socket while the picture waits. Not the
    /// downloader's either — that one serves saves the reader is watching a
    /// progress bar for.
    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = .shared
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }

    /// Fetches the first `bytes` of this clip, cancelling any other warm.
    ///
    /// Returns as soon as the work is scheduled; the caller is not meant to
    /// wait. Doing nothing is always an acceptable outcome — a warm that fails
    /// costs the reader a wait they would have had anyway.
    public func warm(
        _ url: URL,
        referer: URL?,
        bytes: Int = MediaPrefetcher.defaultWarmBytes
    ) async {
        if inFlight?.url == url { return }
        cancelAll()

        // Already whole on disk; there is nothing to warm.
        if await cache.cachedFile(for: url) != nil { return }

        var headers = ["User-Agent": UserAgent.current]
        if let referer { headers["Referer"] = referer.absoluteString }

        let store = store
        let session = session
        let task = Task.detached(priority: .utility) {
            // Off any actor: the reader blocks by design.
            let reader = MediaRangeReader(
                url: url, headers: headers, session: session, store: store
            )
            guard !Task.isCancelled, let total = reader.length(), total > 0 else { return }

            let wanted = min(store.blockCount(forTotal: total), Self.blockCount(of: bytes, in: store))
            let missing = Set(store.missingBlocks(for: url, total: total))
            for index in 0..<wanted where missing.contains(index) {
                // Checked per block rather than per byte, so a cancellation
                // lands within one fetch rather than after the whole head.
                if Task.isCancelled { return }

                // The *last* byte of the block, not the first. Asking the
                // length already fetched byte zero, and the reader keeps that
                // one byte as its window — a read at the start of block zero is
                // then served from it and the block is never fetched at all.
                // Any offset the window cannot already hold forces the real
                // read, and the end of the block is the one that always works.
                let start = Int64(index) * Int64(store.blockSize)
                let offset = min(start + Int64(store.blockSize) - 1, total - 1)
                var byte: UInt8 = 0
                let read = withUnsafeMutablePointer(to: &byte) {
                    reader.read(into: $0, at: offset, count: 1)
                }
                // A server that ignores `Range` answers with the whole body,
                // which the reader refuses to keep as a block. Warming is a
                // courtesy; give up rather than pulling the file twice.
                guard read > 0 else { return }
            }
        }
        inFlight = (url, task)
    }

    /// Stops warming this clip, if it is the one being warmed.
    public func cancel(_ url: URL) {
        guard inFlight?.url == url else { return }
        cancelAll()
    }

    public func cancelAll() {
        inFlight?.task.cancel()
        inFlight = nil
    }

    /// Waits for the warm in flight. For tests; nothing in the app waits.
    public func waitForCurrentWarm() async {
        await inFlight?.task.value
    }

    private static func blockCount(of bytes: Int, in store: MediaBlockStore) -> Int {
        max(1, (bytes + store.blockSize - 1) / store.blockSize)
    }
}
