import Foundation
import Testing
@testable import NeechanMedia

/// Pieces of a file, kept so that watching a clip twice fetches it once.
@Suite("Media block store")
struct MediaBlockStoreTests {
    /// A store of its own per test, since these all touch the file system.
    private func makeStore(blockSize: Int = 1024) throws -> (MediaBlockStore, URL) {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let store = MediaBlockStore(directory: directory, blockSize: blockSize)
        return (store, directory)
    }

    private func url(_ name: String = "clip.webm") -> URL {
        URL(string: "https://example.invalid/\(UUID().uuidString)/\(name)")!
    }

    private func body(_ count: Int) -> Data {
        Data((0..<count).map { UInt8($0 % 251) })
    }

    @Test("a block that was stored reads back exactly")
    func storeAndRead() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = url()
        let piece = body(1024)

        store.store(piece, block: 3, for: clip)

        #expect(store.block(3, for: clip) == piece)
    }

    @Test("a block that was never stored is nothing")
    func missingBlock() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(store.block(0, for: url()) == nil)
    }

    @Test("two files do not share pieces")
    func noCollisions() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = url("a.webm")
        let second = url("b.webm")

        store.store(body(1024), block: 0, for: first)

        #expect(store.block(0, for: first) != nil)
        #expect(store.block(0, for: second) == nil)
    }

    /// Seeking has to work without asking the server how long the file is, or a
    /// clip already on disk could not be scrubbed offline.
    @Test("the total length is remembered")
    func lengthRoundTrip() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = url()

        #expect(store.length(for: clip) == nil)
        store.setLength(60_768_236, for: clip)

        #expect(store.length(for: clip) == 60_768_236)
    }

    @Test("what is missing is worked out from the total, last piece included")
    func missingBlocks() throws {
        let (store, directory) = try makeStore(blockSize: 1000)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = url()
        // 2500 bytes is two whole pieces and a short one.
        store.store(body(1000), block: 0, for: clip)
        store.store(body(500), block: 2, for: clip)

        #expect(store.missingBlocks(for: clip, total: 2500) == [1])
        #expect(store.isComplete(for: clip, total: 2500) == false)

        store.store(body(1000), block: 1, for: clip)

        #expect(store.missingBlocks(for: clip, total: 2500).isEmpty)
        #expect(store.isComplete(for: clip, total: 2500))
    }

    @Test("a file of nothing needs no pieces")
    func emptyFile() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(store.missingBlocks(for: url(), total: 0).isEmpty)
    }

    @Test("the pieces assemble back into the file they came from")
    func assemble() throws {
        let (store, directory) = try makeStore(blockSize: 1000)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = url()
        let original = body(2500)
        for index in 0..<3 {
            let start = index * 1000
            let end = min(start + 1000, original.count)
            store.store(original.subdata(in: start..<end), block: index, for: clip)
        }
        store.setLength(2500, for: clip)

        let assembled = try store.assemble(for: clip)
        defer { try? FileManager.default.removeItem(at: assembled) }

        #expect(try Data(contentsOf: assembled) == original)
    }

    @Test("assembling something incomplete is refused rather than half done")
    func assembleIncomplete() throws {
        let (store, directory) = try makeStore(blockSize: 1000)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = url()
        store.store(body(1000), block: 0, for: clip)
        store.setLength(2500, for: clip)

        #expect(throws: (any Error).self) {
            _ = try store.assemble(for: clip)
        }
    }

    @Test("what is held is counted, and clearing leaves nothing")
    func sizeAndClearing() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = url()
        store.store(body(1024), block: 0, for: clip)
        store.store(body(1024), block: 1, for: clip)

        #expect(store.sizeOnDisk() >= 2048)

        store.removeAll()

        #expect(store.sizeOnDisk() == 0)
        #expect(store.block(0, for: clip) == nil)
    }

    @Test("one file's pieces can be dropped without touching another's")
    func removeOne() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = url("kept.webm")
        let dropped = url("dropped.webm")
        store.store(body(1024), block: 0, for: kept)
        store.store(body(1024), block: 0, for: dropped)

        store.remove(dropped)

        #expect(store.block(0, for: kept) != nil)
        #expect(store.block(0, for: dropped) == nil)
    }

    /// Eviction needs one entry per file, not one per piece, or a long clip
    /// would be thrown away a megabyte at a time.
    @Test("each file is one entry for eviction, sized and dated")
    func entries() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = url()
        store.store(body(1024), block: 0, for: clip)
        store.store(body(1024), block: 1, for: clip)

        let entries = store.entries()

        #expect(entries.count == 1)
        #expect(entries.first?.size ?? 0 >= 2048)
    }
}

/// The one number in settings has to cover the pieces too, or it lies about
/// what the app is keeping.
@Suite("Media cache with pieces")
struct MediaCacheWithBlocksTests {
    private func make(limit: Int) -> (MediaCache, MediaBlockStore, URL, URL) {
        let cacheDirectory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let blockDirectory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let blocks = MediaBlockStore(directory: blockDirectory, blockSize: 1024)
        let cache = MediaCache(directory: cacheDirectory, byteLimit: limit, blocks: blocks)
        return (cache, blocks, cacheDirectory, blockDirectory)
    }

    private func url(_ name: String) -> URL {
        URL(string: "https://example.invalid/\(name)")!
    }

    private func body(_ count: Int) -> Data {
        Data(repeating: 7, count: count)
    }

    @Test("pieces count towards what the cache says it is holding")
    func blocksAreCounted() async {
        let (cache, blocks, cacheDirectory, blockDirectory) = make(limit: 1 << 20)
        defer {
            try? FileManager.default.removeItem(at: cacheDirectory)
            try? FileManager.default.removeItem(at: blockDirectory)
        }

        blocks.store(body(1024), block: 0, for: url("a.webm"))

        #expect(await cache.currentSize() >= 1024)
    }

    @Test("clearing the cache clears the pieces as well")
    func clearingRemovesBlocks() async {
        let (cache, blocks, cacheDirectory, blockDirectory) = make(limit: 1 << 20)
        defer {
            try? FileManager.default.removeItem(at: cacheDirectory)
            try? FileManager.default.removeItem(at: blockDirectory)
        }
        blocks.store(body(1024), block: 0, for: url("a.webm"))

        await cache.removeAll()

        #expect(blocks.sizeOnDisk() == 0)
        #expect(await cache.currentSize() == 0)
    }

    /// Pieces get a corner of the budget, so clips nobody finished cannot crowd
    /// out the files that are whole.
    @Test("pieces are dropped a whole file at a time when they outgrow their corner")
    func blocksAreEvictedByFile() async throws {
        let (cache, blocks, cacheDirectory, blockDirectory) = make(limit: 1 << 20)
        defer {
            try? FileManager.default.removeItem(at: cacheDirectory)
            try? FileManager.default.removeItem(at: blockDirectory)
        }
        // The floor is 32 MB, so fill past that with two clips.
        let older = url("older.webm")
        let newer = url("newer.webm")
        for index in 0..<17 { blocks.store(body(1 << 20), block: index, for: older) }
        try await Task.sleep(for: .milliseconds(30))
        for index in 0..<17 { blocks.store(body(1 << 20), block: index, for: newer) }

        await cache.evictIfNeeded()

        #expect(blocks.block(0, for: older) == nil, "the older clip should have gone first")
        #expect(blocks.block(0, for: newer) != nil, "the newer clip should have survived")
    }
}
