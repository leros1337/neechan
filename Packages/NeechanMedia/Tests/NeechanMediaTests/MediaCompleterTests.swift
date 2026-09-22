import Foundation
import Synchronization
import Testing
@testable import NeechanMedia

/// A stub of this suite's own.
///
/// The body a stub serves lives in a global, and swift-testing runs separate
/// suites in parallel even when each is `.serialized`, so two suites sharing
/// one reset it under each other. A copy is cheaper than that flake.
final class CompleterServingProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static let body = Mutex(Data())
    nonisolated(unsafe) static let honoursRanges = Mutex(true)
    nonisolated(unsafe) static let requestedRanges = Mutex([String]())
    /// Held shut to keep a fetch in flight while a test cancels it.
    nonisolated(unsafe) static let gate = Mutex<DispatchSemaphore?>(nil)

    static func reset(body: Data, honoursRanges: Bool = true) {
        Self.body.withLock { $0 = body }
        Self.honoursRanges.withLock { $0 = honoursRanges }
        requestedRanges.withLock { $0 = [] }
        gate.withLock { $0 = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.body.withLock { $0 }
        let honours = Self.honoursRanges.withLock { $0 }
        let header = request.value(forHTTPHeaderField: "Range")
        if let header { Self.requestedRanges.withLock { $0.append(header) } }
        if let gate = Self.gate.withLock({ $0 }) { gate.wait() }

        var status = 200
        var slice = body
        var headers = ["Content-Type": "video/mp4"]

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

    private static func parse(_ header: String, count: Int) -> Range<Int>? {
        guard header.hasPrefix("bytes=") else { return nil }
        let parts = header.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        guard let start = Int(parts.first ?? ""), start < count else { return nil }
        let end = parts.count > 1 ? Int(parts[1]) ?? count - 1 : count - 1
        return start..<min(count, end + 1)
    }
}


/// Fetching the rest of the clip on screen while it plays.
///
/// The clip that stalls is the one whose bitrate is higher than the connection
/// can carry, and no amount of reading a little way ahead fixes that: the
/// player needs the whole file, and it needs it while the reader is watching
/// the part that has already arrived.
@Suite("Fetching the rest of the clip", .serialized)
struct MediaCompleterTests {
    private let blockSize = 64 << 10

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompleterServingProtocol.self]
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

    @Test("the whole clip ends up on disk, not just its head")
    func fetchesTheWholeClip() async throws {
        let (cacheDirectory, blockDirectory) = directories()
        defer {
            try? FileManager.default.removeItem(at: cacheDirectory)
            try? FileManager.default.removeItem(at: blockDirectory)
        }
        let store = MediaBlockStore(directory: blockDirectory, blockSize: blockSize)
        let cache = MediaCache(directory: cacheDirectory, byteLimit: 1 << 30, blocks: store)
        let url = URL(string: "https://example.invalid/whole.mp4")!

        let source = body(blockSize * 5)
        CompleterServingProtocol.reset(body: source)

        let completer = MediaCompleter(store: store, cache: cache, session: makeSession())
        await completer.complete(url, referer: nil)
        await completer.waitForCurrentFill()

        #expect(store.isComplete(for: url, total: Int64(source.count)))
        #expect(try Data(contentsOf: store.assemble(for: url)) == source)
    }

    @Test("blocks already watched are not fetched twice")
    func doesNotRefetchWhatIsHeld() async throws {
        let (cacheDirectory, blockDirectory) = directories()
        defer {
            try? FileManager.default.removeItem(at: cacheDirectory)
            try? FileManager.default.removeItem(at: blockDirectory)
        }
        let store = MediaBlockStore(directory: blockDirectory, blockSize: blockSize)
        let cache = MediaCache(directory: cacheDirectory, byteLimit: 1 << 30, blocks: store)
        let url = URL(string: "https://example.invalid/part-watched.mp4")!

        let source = body(blockSize * 4)
        CompleterServingProtocol.reset(body: source)
        // The first two blocks, as watching the opening would have left them.
        store.setLength(Int64(source.count), for: url)
        for index in 0..<2 {
            let start = index * blockSize
            store.store(source.subdata(in: start..<(start + blockSize)), block: index, for: url)
        }
        CompleterServingProtocol.requestedRanges.withLock { $0 = [] }

        let completer = MediaCompleter(store: store, cache: cache, session: makeSession())
        await completer.complete(url, referer: nil)
        await completer.waitForCurrentFill()

        let asked = CompleterServingProtocol.requestedRanges.withLock { $0 }
        #expect(
            asked == ["bytes=131072-196607", "bytes=196608-262143"],
            "it should have asked only for the two it was missing: \(asked)"
        )
        #expect(store.isComplete(for: url, total: Int64(source.count)))
    }

    @Test("a clip already whole in the cache is not fetched at all")
    func aCachedClipIsLeftAlone() async throws {
        let (cacheDirectory, blockDirectory) = directories()
        defer {
            try? FileManager.default.removeItem(at: cacheDirectory)
            try? FileManager.default.removeItem(at: blockDirectory)
        }
        let store = MediaBlockStore(directory: blockDirectory, blockSize: blockSize)
        let cache = MediaCache(directory: cacheDirectory, byteLimit: 1 << 30, blocks: store)
        let url = URL(string: "https://example.invalid/already-here.mp4")!

        let source = body(blockSize * 2)
        CompleterServingProtocol.reset(body: source)
        _ = try await cache.store(source, for: url)
        CompleterServingProtocol.requestedRanges.withLock { $0 = [] }

        let completer = MediaCompleter(store: store, cache: cache, session: makeSession())
        await completer.complete(url, referer: nil)
        await completer.waitForCurrentFill()

        #expect(CompleterServingProtocol.requestedRanges.withLock { $0 }.isEmpty)
    }

    @Test("paging to another clip stops the one being fetched")
    func cancellingStopsTheFetch() async throws {
        let (cacheDirectory, blockDirectory) = directories()
        defer {
            try? FileManager.default.removeItem(at: cacheDirectory)
            try? FileManager.default.removeItem(at: blockDirectory)
        }
        let store = MediaBlockStore(directory: blockDirectory, blockSize: blockSize)
        let cache = MediaCache(directory: cacheDirectory, byteLimit: 1 << 30, blocks: store)
        let url = URL(string: "https://example.invalid/swiped-past.mp4")!

        let source = body(blockSize * 8)
        CompleterServingProtocol.reset(body: source)
        let gate = DispatchSemaphore(value: 0)
        CompleterServingProtocol.gate.withLock { $0 = gate }

        let completer = MediaCompleter(store: store, cache: cache, session: makeSession())
        await completer.complete(url, referer: nil)
        await completer.cancel(url)
        // Let whatever was held through, so the fill can notice it was cancelled.
        for _ in 0..<16 { gate.signal() }
        await completer.waitForCurrentFill()

        #expect(
            !store.isComplete(for: url, total: Int64(source.count)),
            "it carried on fetching a clip nobody is watching"
        )
    }

    @Test("asking for the clip already being fetched changes nothing")
    func askingTwiceIsOneFetch() async throws {
        let (cacheDirectory, blockDirectory) = directories()
        defer {
            try? FileManager.default.removeItem(at: cacheDirectory)
            try? FileManager.default.removeItem(at: blockDirectory)
        }
        let store = MediaBlockStore(directory: blockDirectory, blockSize: blockSize)
        let cache = MediaCache(directory: cacheDirectory, byteLimit: 1 << 30, blocks: store)
        let url = URL(string: "https://example.invalid/asked-twice.mp4")!

        let source = body(blockSize * 3)
        CompleterServingProtocol.reset(body: source)

        let completer = MediaCompleter(store: store, cache: cache, session: makeSession())
        await completer.complete(url, referer: nil)
        await completer.complete(url, referer: nil)
        await completer.waitForCurrentFill()

        let asked = CompleterServingProtocol.requestedRanges.withLock { $0 }
        #expect(asked.count == Set(asked).count, "a block was fetched twice: \(asked)")
    }

    @Test("how far it has got is reported as it goes")
    func reportsHowFarItHasGot() async throws {
        let (cacheDirectory, blockDirectory) = directories()
        defer {
            try? FileManager.default.removeItem(at: cacheDirectory)
            try? FileManager.default.removeItem(at: blockDirectory)
        }
        let store = MediaBlockStore(directory: blockDirectory, blockSize: blockSize)
        let cache = MediaCache(directory: cacheDirectory, byteLimit: 1 << 30, blocks: store)
        let url = URL(string: "https://example.invalid/reported.mp4")!

        let source = body(blockSize * 4)
        CompleterServingProtocol.reset(body: source)

        let seen = Mutex([Double]())
        let completer = MediaCompleter(store: store, cache: cache, session: makeSession())
        await completer.complete(url, referer: nil) { fraction in
            seen.withLock { $0.append(fraction) }
        }
        await completer.waitForCurrentFill()

        let fractions = seen.withLock { $0 }
        #expect(fractions.last == 1, "it never reported being done: \(fractions)")
        #expect(fractions == fractions.sorted(), "progress went backwards: \(fractions)")
        #expect(fractions.allSatisfy { $0 >= 0 && $0 <= 1 })
    }
}
