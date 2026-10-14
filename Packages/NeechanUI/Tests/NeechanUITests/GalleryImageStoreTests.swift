import Foundation
import NeechanMedia
import Observation
import Synchronization
import Testing
@testable import NeechanUI

/// The gallery's decoded pictures, held by the viewer rather than by its pages.
///
/// The bug behind this: a page threw its picture away every time it became the
/// one on screen, showed a spinner, and read and decoded the whole file again,
/// so every swipe ended in a flash even between pictures already seen.
@Suite("Gallery image store")
@MainActor
struct GalleryImageStoreTests {
    private typealias F = GalleryPreloadFixtures

    private let referer = URL(string: "https://2ch.org/b/res/1.html")!

    private func url(_ name: String) -> URL {
        URL(string: "https://2ch.org/b/src/1/\(name)")!
    }

    private func image(in store: GalleryImageStore, _ id: String) -> PlatformImage? {
        guard case .loaded(.still(let image)) = store.entries[id] else { return nil }
        return image
    }

    @Test("a loaded picture is kept")
    func loads() async throws {
        let fetcher = CountingFetcher(body: try F.png())
        let store = GalleryImageStore(fetcher: fetcher, cache: F.cache())

        await store.load("a", url: url("a.png"), referer: referer)

        #expect(image(in: store, "a") != nil)
        #expect(fetcher.names == ["a.png"])
    }

    @Test("a picture already loaded is neither fetched nor decoded again")
    func secondLoadIsFree() async throws {
        let fetcher = CountingFetcher(body: try F.png())
        let store = GalleryImageStore(fetcher: fetcher, cache: F.cache())
        await store.load("a", url: url("a.png"), referer: referer)
        let first = try #require(image(in: store, "a"))

        let changed = Mutex(false)
        withObservationTracking {
            _ = store.entries
        } onChange: {
            changed.withLock { $0 = true }
        }
        await store.load("a", url: url("a.png"), referer: referer)

        #expect(fetcher.names == ["a.png"])
        #expect(image(in: store, "a") === first, "the page would be handed a new picture and lose its place")
        #expect(!changed.withLock { $0 }, "the page went back to a spinner")
    }

    @Test("a page asking for a picture being preloaded waits for that one")
    func joinsThePreload() async throws {
        let fetcher = CountingFetcher(body: try F.png(), gated: true)
        let store = GalleryImageStore(fetcher: fetcher, cache: F.cache())

        store.preload("a", url: url("a.png"), referer: referer)
        #expect(await F.waitUntil { fetcher.names.count == 1 })
        let landing = Task { await store.load("a", url: url("a.png"), referer: referer) }
        // Give the page's load the chance to start a second fetch, if it would.
        try await Task.sleep(for: .milliseconds(50))
        fetcher.release()
        await landing.value

        #expect(fetcher.names == ["a.png"])
        #expect(image(in: store, "a") != nil)
    }

    @Test("pictures outside the window are let go, and their fetches stopped")
    func keepsOnlyTheWindow() async throws {
        let fetcher = CountingFetcher(body: try F.png())
        let store = GalleryImageStore(fetcher: fetcher, cache: F.cache())
        await store.load("a", url: url("a.png"), referer: referer)
        await store.load("b", url: url("b.png"), referer: referer)

        store.keep(only: ["b"])

        #expect(store.entries["a"] == nil)
        #expect(image(in: store, "b") != nil)
    }

    @Test("a preload stopped part way leaves nothing behind")
    func cancelledPreload() async throws {
        let fetcher = CountingFetcher(body: try F.png(), gated: true)
        let store = GalleryImageStore(fetcher: fetcher, cache: F.cache())

        store.preload("a", url: url("a.png"), referer: referer)
        #expect(await F.waitUntil { fetcher.names.count == 1 })
        store.keep(only: [])
        fetcher.release()
        // Nothing should arrive, so this waits for the chance to.
        _ = await F.waitUntil({ store.entries["a"] != nil }, within: 0.2)

        #expect(store.entries["a"] == nil)
    }

    @Test("a picture let go comes back from the disk, not the network")
    func comesBackFromDisk() async throws {
        let fetcher = CountingFetcher(body: try F.png())
        let store = GalleryImageStore(fetcher: fetcher, cache: F.cache())
        await store.load("a", url: url("a.png"), referer: referer)

        store.keep(only: [])
        await store.load("a", url: url("a.png"), referer: referer)

        #expect(fetcher.names == ["a.png"])
        #expect(image(in: store, "a") != nil)
    }

    @Test("a failure is reported, and landing again tries again")
    func failureRetries() async throws {
        let fetcher = CountingFetcher(body: try F.png())
        fetcher.failing.withLock { $0 = ["a.png"] }
        let store = GalleryImageStore(fetcher: fetcher, cache: F.cache())

        await store.load("a", url: url("a.png"), referer: referer)
        guard case .failed(.other) = store.entries["a"] else {
            Issue.record("expected a failure, got \(String(describing: store.entries["a"]))")
            return
        }

        fetcher.failing.withLock { $0 = [] }
        await store.load("a", url: url("a.png"), referer: referer)

        #expect(image(in: store, "a") != nil)
        #expect(fetcher.names == ["a.png", "a.png"])
    }

    @Test("a file that is not a picture says so")
    func notAnImage() async throws {
        let fetcher = CountingFetcher(body: Data("<html>nope</html>".utf8))
        let store = GalleryImageStore(fetcher: fetcher, cache: F.cache())

        await store.load("a", url: url("a.png"), referer: referer)

        guard case .failed(.notAnImage) = store.entries["a"] else {
            Issue.record("expected notAnImage, got \(String(describing: store.entries["a"]))")
            return
        }
    }
}
