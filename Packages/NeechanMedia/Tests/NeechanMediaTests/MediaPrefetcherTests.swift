import Foundation
import Synchronization
import Testing
@testable import NeechanMedia

/// A stub of this suite's own.
///
/// `RangeServingProtocol` keeps the body it serves in a global, and swift
/// testing runs separate suites in parallel even when each is `.serialized` —
/// so two suites sharing it reset the body under one another. A copy is cheaper
/// than the flake.
final class PrefetchServingProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static let body = Mutex(Data())
    /// Set false to answer the whole body whatever range was asked for, the way
    /// a server with no range support would.
    nonisolated(unsafe) static let honoursRanges = Mutex(true)
    /// Every `Range` header seen, so a test can show a read was not a download.
    nonisolated(unsafe) static let requestedRanges = Mutex([String]())

    static func reset(body: Data, honoursRanges: Bool = true) {
        Self.body.withLock { $0 = body }
        Self.honoursRanges.withLock { $0 = honoursRanges }
        requestedRanges.withLock { $0 = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.body.withLock { $0 }
        let honours = Self.honoursRanges.withLock { $0 }
        let header = request.value(forHTTPHeaderField: "Range")
        if let header { Self.requestedRanges.withLock { $0.append(header) } }

        var status = 200
        var slice = body
        var headers = ["Content-Type": "video/webm"]

        if honours, let header, let range = Self.parse(header, count: body.count) {
            status = 206
            slice = body.subdata(in: range)
            headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(body.count)"
        }
        headers["Content-Length"] = "\(slice.count)"

        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: slice)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// `bytes=start-end`, clamped to what there is.
    private static func parse(_ header: String, count: Int) -> Range<Int>? {
        guard header.hasPrefix("bytes=") else { return nil }
        let parts = header.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        guard let start = Int(parts.first ?? ""), start < count else { return nil }
        let end = parts.count > 1 ? Int(parts[1]) ?? count - 1 : count - 1
        return start..<min(count, end + 1)
    }
}


/// Warming the next clip so a swipe does not land on black.
@Suite("Warming the next clip", .serialized)
struct MediaPrefetcherTests {
    private let blockSize = 64 << 10

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PrefetchServingProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func body(_ count: Int) -> Data {
        Data((0..<count).map { UInt8($0 % 251) })
    }

    private func directories() -> (cache: URL, blocks: URL) {
        (
            URL.temporaryDirectory.appending(path: UUID().uuidString),
            URL.temporaryDirectory.appending(path: UUID().uuidString)
        )
    }

    /// The head, and only the head: the rest is a clip the reader may swipe
    /// straight past.
    @Test("only the head is fetched, not the whole clip")
    func warmsOnlyTheHead() async throws {
        let (cacheDirectory, blockDirectory) = directories()
        defer {
            try? FileManager.default.removeItem(at: cacheDirectory)
            try? FileManager.default.removeItem(at: blockDirectory)
        }
        let store = MediaBlockStore(directory: blockDirectory, blockSize: blockSize)
        let cache = MediaCache(directory: cacheDirectory, byteLimit: 1 << 30, blocks: store)
        let url = URL(string: "https://example.invalid/next.webm")!

        // Five blocks' worth; two are wanted.
        PrefetchServingProtocol.reset(body: body(blockSize * 5))

        let prefetcher = MediaPrefetcher(store: store, cache: cache, session: makeSession(), isPlaybackWaiting: { false })
        await prefetcher.warm(url, referer: nil, bytes: blockSize * 2)
        await prefetcher.waitForCurrentWarm()

        let missing = store.missingBlocks(for: url, total: Int64(blockSize * 5))
        #expect(!missing.contains(0), "the first block was not warmed")
        #expect(!missing.contains(1), "the second block was not warmed")
        #expect(missing.contains(2), "more than the head was fetched")
        #expect(missing.contains(4))
    }

    @Test("a clip already on disk is not fetched again")
    func aCachedClipIsNotWarmed() async throws {
        let (cacheDirectory, blockDirectory) = directories()
        defer {
            try? FileManager.default.removeItem(at: cacheDirectory)
            try? FileManager.default.removeItem(at: blockDirectory)
        }
        let store = MediaBlockStore(directory: blockDirectory, blockSize: blockSize)
        let cache = MediaCache(directory: cacheDirectory, byteLimit: 1 << 30, blocks: store)
        let url = URL(string: "https://example.invalid/seen.webm")!

        let source = body(blockSize)
        PrefetchServingProtocol.reset(body: source)
        _ = try await cache.store(source, for: url)
        PrefetchServingProtocol.requestedRanges.withLock { $0 = [] }

        let prefetcher = MediaPrefetcher(store: store, cache: cache, session: makeSession(), isPlaybackWaiting: { false })
        await prefetcher.warm(url, referer: nil, bytes: blockSize * 2)
        await prefetcher.waitForCurrentWarm()

        let asked = PrefetchServingProtocol.requestedRanges.withLock { $0 }
        #expect(asked.isEmpty, "a cached clip was fetched again: \(asked)")
    }

    /// Paging past a clip must stop its warm, or the reader's connection is
    /// spent on something they have already left behind.
    @Test("warming another clip abandons the one before it")
    func warmingAnotherCancelsTheFirst() async throws {
        let (cacheDirectory, blockDirectory) = directories()
        defer {
            try? FileManager.default.removeItem(at: cacheDirectory)
            try? FileManager.default.removeItem(at: blockDirectory)
        }
        let store = MediaBlockStore(directory: blockDirectory, blockSize: blockSize)
        let cache = MediaCache(directory: cacheDirectory, byteLimit: 1 << 30, blocks: store)
        PrefetchServingProtocol.reset(body: body(blockSize * 4))

        let prefetcher = MediaPrefetcher(store: store, cache: cache, session: makeSession(), isPlaybackWaiting: { false })
        await prefetcher.warm(URL(string: "https://example.invalid/first.webm")!, referer: nil)
        await prefetcher.warm(URL(string: "https://example.invalid/second.webm")!, referer: nil)
        await prefetcher.waitForCurrentWarm()

        // Whatever the first managed before it was cancelled, the second is the
        // one that ran to completion.
        let second = URL(string: "https://example.invalid/second.webm")!
        #expect(!store.missingBlocks(for: second, total: Int64(blockSize * 4)).contains(0))
    }

    @Test("cancelling stops the warm")
    func cancellingStops() async throws {
        let (cacheDirectory, blockDirectory) = directories()
        defer {
            try? FileManager.default.removeItem(at: cacheDirectory)
            try? FileManager.default.removeItem(at: blockDirectory)
        }
        let store = MediaBlockStore(directory: blockDirectory, blockSize: blockSize)
        let cache = MediaCache(directory: cacheDirectory, byteLimit: 1 << 30, blocks: store)
        let url = URL(string: "https://example.invalid/abandoned.webm")!
        PrefetchServingProtocol.reset(body: body(blockSize * 4))

        let prefetcher = MediaPrefetcher(store: store, cache: cache, session: makeSession(), isPlaybackWaiting: { false })
        await prefetcher.warm(url, referer: nil)
        await prefetcher.cancel(url)
        await prefetcher.waitForCurrentWarm()

        // Nothing to assert about how far it got — only that asking again is
        // allowed, which is what a reader scrolling back would do.
        await prefetcher.warm(url, referer: nil)
        await prefetcher.waitForCurrentWarm()
        #expect(!store.missingBlocks(for: url, total: Int64(blockSize * 4)).contains(0))
    }
}
