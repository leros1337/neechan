import Foundation
import Synchronization
import Testing
@testable import NeechanMedia

/// Saving a clip already watched should cost the remainder, not the file.
@Suite("Completing a part-watched file", .serialized)
struct MediaFileCompletionTests {
    private let blockSize = 64 << 10

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeServingProtocol.self]
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
        RangeServingProtocol.reset(body: source)
        seed(source, upToBlock: 2, for: url, in: store)
        RangeServingProtocol.requestedRanges.withLock { $0 = [] }

        let whole = try #require(
            await MediaFileCompletion.wholeFile(
                for: url, referer: nil, cache: cache, store: store, session: makeSession()
            )
        )

        let asked = RangeServingProtocol.requestedRanges.withLock { $0 }
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
        RangeServingProtocol.reset(body: source)
        seed(source, upToBlock: 2, for: url, in: store)
        RangeServingProtocol.requestedRanges.withLock { $0 = [] }

        let whole = try #require(
            await MediaFileCompletion.wholeFile(
                for: url, referer: nil, cache: cache, store: store, session: makeSession()
            )
        )

        #expect(RangeServingProtocol.requestedRanges.withLock { $0 }.isEmpty)
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
        RangeServingProtocol.reset(body: source)
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
        RangeServingProtocol.reset(body: body(blockSize * 3))

        let whole = await MediaFileCompletion.wholeFile(
            for: url, referer: nil, cache: cache, store: store, session: makeSession()
        )

        #expect(whole == nil)
    }
}
