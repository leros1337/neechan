import Foundation
import NeechanAPITesting
import NeechanCore
import NeechanMedia
import NeechanSettings
import Observation
import Synchronization
import Testing
@testable import NeechanUI

/// Fetching the next picture while the reader looks at this one.
///
/// Until now only the next video was fetched ahead, and only while a clip
/// played. A picture was fetched once the swipe onto it had ended, so every
/// page turned onto a spinner.
@Suite("Gallery preloading")
@MainActor
struct GalleryPreloadTests {
    private typealias F = GalleryPreloadFixtures

    private func makeModel(
        _ items: [GalleryItem],
        startIndex: Int = 0,
        fetcher: CountingFetcher,
        policy: MediaLoadPolicy = .always
    ) throws -> GalleryViewModel {
        let settings = AppSettings(
            defaults: UserDefaults(suiteName: "preload.\(UUID().uuidString)")!
        )
        settings.mediaLoadPolicy = policy
        let services = try AppServices.inMemory(settings: settings, transport: StubTransport())
        return GalleryViewModel(
            items: items,
            startIndex: startIndex,
            services: services,
            cache: F.cache(),
            completer: IdleCompleter(),
            imageFetcher: fetcher
        )
    }

    @Test("landing on a picture fetches it, then the one after it")
    func preloadsTheNextPicture() async throws {
        let items = [
            try F.item("a.jpg", postNum: 1),
            try F.item("b.jpg", postNum: 2),
            try F.item("c.jpg", postNum: 3),
        ]
        let fetcher = CountingFetcher(body: try F.png())
        let model = try makeModel(items, fetcher: fetcher)

        model.pageDidChange(from: nil)

        #expect(await F.waitUntil { fetcher.names == ["a.jpg", "b.jpg"] })
        #expect(await F.waitUntil {
            if case .loaded = model.images.entries[items[1].id] { return true }
            return false
        }, "the next picture was fetched but not decoded")
    }

    @Test("a next picture over 10 MB is not fetched ahead")
    func skipsALargePicture() async throws {
        let items = [
            try F.item("a.jpg", postNum: 1),
            try F.item("b.jpg", sizeKB: 12 * 1024, postNum: 2),
        ]
        let fetcher = CountingFetcher(body: try F.png())
        let model = try makeModel(items, fetcher: fetcher)

        model.pageDidChange(from: nil)
        #expect(await F.waitUntil { fetcher.names == ["a.jpg"] })
        _ = await F.waitUntil({ fetcher.names.count > 1 }, within: 0.2)

        #expect(fetcher.names == ["a.jpg"])
    }

    @Test("with media loading off, nothing is fetched ahead")
    func respectsTheDataSetting() async throws {
        let items = [try F.item("a.jpg", postNum: 1), try F.item("b.jpg", postNum: 2)]
        let fetcher = CountingFetcher(body: try F.png())
        let model = try makeModel(items, fetcher: fetcher, policy: .never)

        model.pageDidChange(from: nil)
        // The picture the reader opened is still shown: they asked for it.
        #expect(await F.waitUntil { fetcher.names == ["a.jpg"] })
        _ = await F.waitUntil({ fetcher.names.count > 1 }, within: 0.2)

        #expect(fetcher.names == ["a.jpg"])
    }

    @Test("on a video, the next picture waits until the clip is playing")
    func waitsForTheClip() async throws {
        let items = [
            try F.item("a.mp4", type: 10, postNum: 1),
            try F.item("b.jpg", postNum: 2),
        ]
        let fetcher = CountingFetcher(body: try F.png())
        let model = try makeModel(items, fetcher: fetcher)

        model.pageDidChange(from: nil)
        _ = await F.waitUntil({ !fetcher.names.isEmpty }, within: 0.2)
        #expect(fetcher.names.isEmpty, "the picture competed with the clip as it opened")

        model.playbackState = .playing

        #expect(await F.waitUntil { fetcher.names == ["b.jpg"] })
    }

    @Test("a clip that opens paused, with autoplay off, lets the next picture load")
    func clipOpenedPaused() async throws {
        let items = [
            try F.item("a.mp4", type: 10, postNum: 1),
            try F.item("b.jpg", postNum: 2),
        ]
        let fetcher = CountingFetcher(body: try F.png())
        let model = try makeModel(items, fetcher: fetcher)
        model.pageDidChange(from: nil)

        model.playbackState = .preparing
        _ = await F.waitUntil({ !fetcher.names.isEmpty }, within: 0.2)
        #expect(fetcher.names.isEmpty, "the picture competed with the clip as it opened")
        model.playbackState = .paused

        #expect(await F.waitUntil { fetcher.names == ["b.jpg"] })
    }

    @Test("paging on lets go of pictures out of reach")
    func dropsPicturesBehind() async throws {
        let items = try (1...4).map { try F.item("\($0).jpg", postNum: $0) }
        let fetcher = CountingFetcher(body: try F.png())
        let model = try makeModel(items, fetcher: fetcher)
        model.pageDidChange(from: nil)
        #expect(await F.waitUntil { fetcher.names == ["1.jpg", "2.jpg"] })

        model.currentIndex = 1
        model.pageDidChange(from: 0)
        model.currentIndex = 2
        model.pageDidChange(from: 1)

        #expect(model.images.entries[items[0].id] == nil)
        #expect(await F.waitUntil {
            if case .loaded = model.images.entries[items[3].id] { return true }
            return false
        })
    }

    @Test("picture to picture leaves the playback state alone")
    func pictureToPictureDoesNotResetPlayback() async throws {
        let items = [try F.item("a.jpg", postNum: 1), try F.item("b.jpg", postNum: 2)]
        let fetcher = CountingFetcher(body: try F.png())
        let model = try makeModel(items, fetcher: fetcher)

        let changed = Mutex(false)
        withObservationTracking {
            _ = model.playbackState
            _ = model.playbackControl
            _ = model.playbackProgress
        } onChange: {
            changed.withLock { $0 = true }
        }
        model.currentIndex = 1
        model.pageDidChange(from: 0)

        #expect(!changed.withLock { $0 }, "every page in the gallery was redrawn for nothing")
    }

    @Test("leaving a video still resets playback")
    func leavingAVideoResets() async throws {
        let items = [
            try F.item("a.mp4", type: 10, postNum: 1),
            try F.item("b.jpg", postNum: 2),
        ]
        let fetcher = CountingFetcher(body: try F.png())
        let model = try makeModel(items, fetcher: fetcher)
        model.playbackState = .playing

        model.currentIndex = 1
        model.pageDidChange(from: 0)

        #expect(model.playbackState == .idle)
    }
}
