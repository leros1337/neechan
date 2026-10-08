import CoreGraphics
import Foundation
import NeechanTestSupport
import Synchronization
import Testing
@testable import NeechanMedia

/// Pictures from a clip for the scrubber, from what is already on the device.
@Suite("Scrub previews", .serialized)
struct ScrubPreviewerTests {
    /// Counts every request a session makes, and answers none of them.
    final class CountingProtocol: URLProtocol, @unchecked Sendable {
        static let requests = Mutex(0)

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.requests.withLock { $0 += 1 }
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }

        override func stopLoading() {}
    }

    private func countingSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CountingProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func directory() -> URL {
        URL.temporaryDirectory.appending(path: "scrub-\(UUID().uuidString)")
    }

    private let url = URL(string: "https://2ch.org/b/src/1/clip.webm")!

    @Test("a clip on the device gives a small picture anywhere in it")
    func wholeFileGivesPictures() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = MediaCache(directory: folder.appending(path: "files"))
        _ = try await cache.store(FixtureLoader.data(.sampleLong), for: url)
        let previewer = ScrubPreviewer(
            url: url,
            cache: cache,
            blocks: MediaBlockStore(directory: folder.appending(path: "blocks")),
            session: countingSession()
        )
        defer { previewer.close() }

        for time in [0.0, 6, 11.5] {
            let image = try #require(await previewer.preview(at: time), "no picture at \(time)s")
            #expect(max(image.width, image.height) <= 160)
            #expect(image.width > 0 && image.height > 0)
        }
    }

    /// The scrubber is dragged over the whole clip, most of which may not have
    /// arrived. Fetching a piece for each position would compete with the
    /// clip itself for the connection.
    @Test("a part not yet on the device gives nothing, and nothing is fetched")
    func missingPartFetchesNothing() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = try FixtureLoader.data(.sampleLong)
        let blockSize = 16 * 1024
        let blocks = MediaBlockStore(directory: folder.appending(path: "blocks"), blockSize: blockSize)
        blocks.setLength(Int64(data.count), for: url)
        // What a clip opened in the player has on the device so far: its
        // opening, and its last block, which holds the index the demuxer
        // reads as it opens. The middle has not arrived.
        let lastBlock = (data.count - 1) / blockSize
        for index in [0, 1, lastBlock] {
            let start = index * blockSize
            blocks.store(data.subdata(in: start..<min(data.count, start + blockSize)), block: index, for: url)
        }
        CountingProtocol.requests.withLock { $0 = 0 }
        let previewer = ScrubPreviewer(
            url: url,
            cache: MediaCache(directory: folder.appending(path: "files")),
            blocks: blocks,
            session: countingSession()
        )
        defer { previewer.close() }

        let early = await previewer.preview(at: 0.5)
        let late = await previewer.preview(at: 11)

        #expect(early != nil, "the opening is on the device and has a picture")
        #expect(late == nil, "the keyframe for 11s is in the part not yet here")
        #expect(CountingProtocol.requests.withLock { $0 } == 0)
    }

    /// Without the index the demuxer reads forward from the start to find a
    /// keyframe, comes to the gap, and stops at the keyframe before it. That
    /// picture is of somewhere else, and is not shown.
    @Test("without the file's index, a position past a gap gives nothing rather than the wrong picture")
    func gapWithoutIndex() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = try FixtureLoader.data(.sampleLong)
        let blockSize = 16 * 1024
        let blocks = MediaBlockStore(directory: folder.appending(path: "blocks"), blockSize: blockSize)
        blocks.setLength(Int64(data.count), for: url)
        for index in 0..<2 {
            let start = index * blockSize
            blocks.store(data.subdata(in: start..<min(data.count, start + blockSize)), block: index, for: url)
        }
        let previewer = ScrubPreviewer(
            url: url,
            cache: MediaCache(directory: folder.appending(path: "files")),
            blocks: blocks,
            session: countingSession()
        )
        defer { previewer.close() }

        #expect(await previewer.preview(at: 11) == nil)
    }

    /// A drag sends a position for every point the finger crosses. Only the
    /// last is worth answering.
    @Test("only the latest of several requests is answered")
    func olderRequestsAreDropped() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = MediaCache(directory: folder.appending(path: "files"))
        _ = try await cache.store(FixtureLoader.data(.sampleLong), for: url)
        let previewer = ScrubPreviewer(
            url: url,
            cache: cache,
            blocks: MediaBlockStore(directory: folder.appending(path: "blocks")),
            session: countingSession()
        )
        defer { previewer.close() }

        // In this order for certain: each waits until the one before has
        // taken its turn.
        let older = Task { await previewer.preview(at: 2) }
        while previewer.requestCount < 1 { await Task.yield() }
        let middle = Task { await previewer.preview(at: 4) }
        while previewer.requestCount < 2 { await Task.yield() }
        let newest = await previewer.preview(at: 8)
        _ = await (older.value, middle.value)

        #expect(newest != nil, "the latest position went unanswered")
    }
}
