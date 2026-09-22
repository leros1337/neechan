import Foundation
import Synchronization
import Testing
@testable import NeechanMedia

/// A stub of this suite's own.
///
/// The body a stub serves lives in a global, and swift-testing runs separate
/// suites in parallel even when each is `.serialized` — so two suites sharing
/// one reset it under each other, and the failure looks like a bug in the
/// reader rather than in the test. A copy is cheaper than that confusion.
final class CompletionServingProtocol: URLProtocol, @unchecked Sendable {
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


/// Saving a clip already watched should cost the remainder, not the file.
@Suite("Completing a part-watched file", .serialized)
struct MediaFileCompletionTests {
    private let blockSize = 64 << 10

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompletionServingProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func body(_ count: Int) -> Data {
        Data((0..<count).map { UInt8($0 % 251) })
    }

    /// Seeds every block but the last, the way watching most of a clip would.
    private func seed(
        _ source: Data,
        upToBlock last: Int,
        for url: URL,
        in store: MediaBlockStore
    ) {
        store.setLength(Int64(source.count), for: url)
        for index in 0..<last {
            let start = index * blockSize
            let end = min(start + blockSize, source.count)
            store.store(source.subdata(in: start..<end), block: index, for: url)
        }
    }

    @Test("only the missing pieces are fetched, and the file comes out whole")
    func fetchesOnlyWhatIsMissing() async throws {
        let cacheDirectory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let blockDirectory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: cacheDirectory)
            try? FileManager.default.removeItem(at: blockDirectory)
        }
        let store = MediaBlockStore(directory: blockDirectory, blockSize: blockSize)
        let cache = MediaCache(directory: cacheDirectory, byteLimit: 1 << 30, blocks: store)
        let url = URL(string: "https://example.invalid/half-watched.webm")!

        // Two whole blocks and a short third.
        let source = body(blockSize * 2 + 5000)
        CompletionServingProtocol.reset(body: source)
        seed(source, upToBlock: 2, for: url, in: store)
        CompletionServingProtocol.requestedRanges.withLock { $0 = [] }

        let whole = try #require(
            await MediaFileCompletion.wholeFile(
                for: url, referer: nil, cache: cache, store: store, session: makeSession()
            )
        )

        let asked = CompletionServingProtocol.requestedRanges.withLock { $0 }
        #expect(asked == ["bytes=131072-196607"], "asked for \(asked)")
        #expect(try Data(contentsOf: whole) == source)
        #expect(await cache.cachedFile(for: url) != nil, "it should now be one cached file")
        #expect(store.sizeOnDisk() == 0, "the pieces have served their purpose")
    }

    @Test("a file already whole on disk is completed without asking for anything")
    func nothingMissingCostsNothing() async throws {
        let cacheDirectory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let blockDirectory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: cacheDirectory)
            try? FileManager.default.removeItem(at: blockDirectory)
        }
        let store = MediaBlockStore(directory: blockDirectory, blockSize: blockSize)
        let cache = MediaCache(directory: cacheDirectory, byteLimit: 1 << 30, blocks: store)
        let url = URL(string: "https://example.invalid/fully-watched.webm")!

        let source = body(blockSize + 100)
        CompletionServingProtocol.reset(body: source)
        seed(source, upToBlock: 2, for: url, in: store)
        CompletionServingProtocol.requestedRanges.withLock { $0 = [] }

        let whole = try #require(
            await MediaFileCompletion.wholeFile(
                for: url, referer: nil, cache: cache, store: store, session: makeSession()
            )
        )

        #expect(CompletionServingProtocol.requestedRanges.withLock { $0 }.isEmpty)
        #expect(try Data(contentsOf: whole) == source)
    }

    /// With no head start there is nothing to complete, and the caller is told
    /// so rather than being handed a ranged download of the whole file.
    /// The capsule reads this, and filling in is most of a save for a clip that
    /// has been watched: without progress it sat at nothing and then jumped to
    /// done, which is exactly what a hung button looks like.
    @Test("filling in the missing pieces says how far it has got")
    func reportsProgress() async throws {
        let cacheDirectory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let blockDirectory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: cacheDirectory)
            try? FileManager.default.removeItem(at: blockDirectory)
        }
        let store = MediaBlockStore(directory: blockDirectory, blockSize: blockSize)
        let cache = MediaCache(directory: cacheDirectory, byteLimit: 1 << 30, blocks: store)
        let url = URL(string: "https://example.invalid/part-watched.webm")!

        // Four blocks, of which the first two were left by watching it.
        let source = body(blockSize * 4)
        CompletionServingProtocol.reset(body: source)
        seed(source, upToBlock: 2, for: url, in: store)

        let reports = Mutex([Int64]())
        let total = Mutex(Int64(0))
        _ = await MediaFileCompletion.wholeFile(
            for: url, referer: nil, cache: cache, store: store, session: makeSession(),
            onProgress: { received, whole in
                reports.withLock { $0.append(received) }
                total.withLock { $0 = whole }
            }
        )

        let seen = reports.withLock { $0 }
        #expect(!seen.isEmpty, "nothing was reported at all")
        #expect(total.withLock { $0 } == Int64(source.count))

        // What is already on disk counts, so this never starts from zero.
        #expect(seen.first == Int64(blockSize * 2), "the head start was not counted: \(seen)")
        #expect(seen == seen.sorted(), "progress went backwards: \(seen)")
        #expect(seen.last == Int64(source.count), "it never reached the end: \(seen)")
    }

    @Test("a file with no pieces held is left to a plain download")
    func nothingHeldIsNotCompleted() async throws {
        let cacheDirectory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let blockDirectory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: cacheDirectory)
            try? FileManager.default.removeItem(at: blockDirectory)
        }
        let store = MediaBlockStore(directory: blockDirectory, blockSize: blockSize)
        let cache = MediaCache(directory: cacheDirectory, byteLimit: 1 << 30, blocks: store)
        let url = URL(string: "https://example.invalid/unwatched.webm")!
        CompletionServingProtocol.reset(body: body(blockSize * 3))

        let whole = await MediaFileCompletion.wholeFile(
            for: url, referer: nil, cache: cache, store: store, session: makeSession()
        )

        #expect(whole == nil)
    }

    // MARK: Filling the blocks in without assembling

    @Test("filling in leaves the pieces where playback can read them")
    func fillingLeavesThePieces() async throws {
        let blockDirectory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: blockDirectory) }
        let store = MediaBlockStore(directory: blockDirectory, blockSize: blockSize)
        let url = URL(string: "https://example.invalid/watching.webm")!

        let source = body(blockSize * 3 + 100)
        CompletionServingProtocol.reset(body: source)
        seed(source, upToBlock: 1, for: url, in: store)
        CompletionServingProtocol.requestedRanges.withLock { $0 = [] }

        let filled = await MediaFileCompletion.fillBlocks(
            for: url, referer: nil, store: store, session: makeSession()
        )

        #expect(filled)
        #expect(store.isComplete(for: url, total: Int64(source.count)))
        // The whole point of the split: the pieces stay, because the player is
        // still reading them.
        #expect(store.sizeOnDisk() > 0, "the pieces are what playback reads")
        #expect(try store.assemble(for: url).isFileURL, "and they add back up to the file")
    }

    @Test("filling in asks only for what is missing")
    func fillingAsksOnlyForWhatIsMissing() async throws {
        let blockDirectory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: blockDirectory) }
        let store = MediaBlockStore(directory: blockDirectory, blockSize: blockSize)
        let url = URL(string: "https://example.invalid/mostly-here.webm")!

        let source = body(blockSize * 2 + 5000)
        CompletionServingProtocol.reset(body: source)
        seed(source, upToBlock: 2, for: url, in: store)
        CompletionServingProtocol.requestedRanges.withLock { $0 = [] }

        #expect(await MediaFileCompletion.fillBlocks(
            for: url, referer: nil, store: store, session: makeSession()
        ))

        let asked = CompletionServingProtocol.requestedRanges.withLock { $0 }
        #expect(asked == ["bytes=131072-196607"], "asked for \(asked)")
    }

    @Test("filling in reports how far it has got")
    func fillingReportsProgress() async throws {
        let blockDirectory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: blockDirectory) }
        let store = MediaBlockStore(directory: blockDirectory, blockSize: blockSize)
        let url = URL(string: "https://example.invalid/progress.webm")!

        let source = body(blockSize * 4)
        CompletionServingProtocol.reset(body: source)
        seed(source, upToBlock: 1, for: url, in: store)

        let seen = Mutex([Int]())
        let blocks = Mutex(0)
        #expect(await MediaFileCompletion.fillBlocks(
            for: url, referer: nil, store: store, session: makeSession(),
            onProgress: { done, all in
                seen.withLock { $0.append(done) }
                blocks.withLock { $0 = all }
            }
        ))

        let done = seen.withLock { $0 }
        #expect(blocks.withLock { $0 } == 4)
        #expect(done.first == 1, "one of four blocks was already here: \(done)")
        #expect(done.last == 4, "it never reached the end: \(done)")
        #expect(done == done.sorted(), "progress went backwards: \(done)")
    }

    @Test("filling in works from nothing, for a clip only just opened")
    func fillingWorksFromNothing() async throws {
        let blockDirectory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: blockDirectory) }
        let store = MediaBlockStore(directory: blockDirectory, blockSize: blockSize)
        let url = URL(string: "https://example.invalid/fresh.webm")!

        // Nothing held and no length remembered: the shape the completer meets
        // when it starts before the player has kept its first block.
        let source = body(blockSize * 2)
        CompletionServingProtocol.reset(body: source)

        #expect(await MediaFileCompletion.fillBlocks(
            for: url, referer: nil, store: store, session: makeSession()
        ))
        #expect(store.isComplete(for: url, total: Int64(source.count)))
    }

    @Test("a server that will not answer stops the fill rather than spinning")
    func aDeadServerStopsTheFill() async throws {
        let blockDirectory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: blockDirectory) }
        let store = MediaBlockStore(directory: blockDirectory, blockSize: blockSize)
        let url = URL(string: "https://example.invalid/gone.webm")!

        // A server that ignores ranges answers the whole body however far in
        // the reader asked, which the store refuses to keep as a block.
        let source = body(blockSize * 3)
        CompletionServingProtocol.reset(body: source, honoursRanges: false)

        #expect(await MediaFileCompletion.fillBlocks(
            for: url, referer: nil, store: store, session: makeSession()
        ) == false)
    }
}
