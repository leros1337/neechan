import Foundation
import NeechanAPI
import NeechanAPITesting
import NeechanCore
import NeechanMedia
import NeechanSettings
import Synchronization
import Testing
@testable import NeechanUI

/// Stands in for the thing that fetches the rest of the clip.
private final class SpyCompleter: MediaCompleting, @unchecked Sendable {
    let asked = Mutex([URL]())
    let cancelled = Mutex([URL]())
    let cancelledAll = Mutex(0)
    /// Handed back to whoever asked, so a test can drive the buffer bar.
    let report = Mutex<(@Sendable (Double) -> Void)?>(nil)

    func complete(_ url: URL, referer: URL?, onProgress: (@Sendable (Double) -> Void)?) async {
        asked.withLock { $0.append(url) }
        report.withLock { $0 = onProgress }
    }

    func cancel(_ url: URL) async {
        cancelled.withLock { $0.append(url) }
    }

    func cancelAll() async {
        cancelledAll.withLock { $0 += 1 }
    }
}

/// Fetching the whole of the clip on screen, and saying how far that has got.
///
/// The bug behind this: a clip whose bitrate is higher than the connection can
/// carry stalls a second or two in, because the player only ever fetched a few
/// megabytes ahead of the playhead. The viewer now pulls the rest of the file
/// underneath the clip while it plays.
@Suite("Fetching the clip the viewer is on")
@MainActor
struct GalleryCompletionTests {
    /// Waits for work the view model started in a `Task` of its own.
    ///
    /// The fetch is deliberately fire-and-forget — nothing in the app waits for
    /// it — so a test has to, and one `Task.yield()` is not enough: the call
    /// hops off the main actor and back.
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        within seconds: Double = 2
    ) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func item(_ path: String, postNum: Int = 1) throws -> GalleryItem {
        let json = """
        {"path": "\(path)", "thumbnail": "\(path)", "name": "f.mp4", "type": 6}
        """
        let attachment = try JSONDecoder().decode(
            NeechanAPI.Attachment.self, from: Data(json.utf8)
        )
        return GalleryItem(
            attachment: attachment, postNum: postNum,
            threadKey: ThreadKey(site: .dvach, board: "b", threadNum: 1)
        )
    }

    private func makeModel(
        _ items: [GalleryItem], completer: SpyCompleter
    ) throws -> GalleryViewModel {
        let settings = AppSettings(
            defaults: UserDefaults(suiteName: "completion.\(UUID().uuidString)")!
        )
        let services = try AppServices.inMemory(settings: settings, transport: StubTransport())
        return GalleryViewModel(
            items: items, startIndex: 0, services: services, completer: completer
        )
    }

    @Test("the clip on screen is fetched whole once it is playing")
    func fetchesTheClipOnScreen() async throws {
        let video = try item("/b/src/1/clip.mp4")
        let spy = SpyCompleter()
        let model = try makeModel([video], completer: spy)

        model.playbackState = .playing

        #expect(await waitUntil { spy.asked.withLock { $0 }.count == 1 })
        #expect(spy.asked.withLock { $0 }.first?.lastPathComponent == "clip.mp4")
    }

    @Test("a still is not fetched by the thing that fetches clips")
    func stillsAreNotFetched() async throws {
        let still = try item("/b/src/1/picture.jpg")
        let spy = SpyCompleter()
        let model = try makeModel([still], completer: spy)

        model.playbackState = .playing
        // Nothing should ever arrive, so this waits for the chance to.
        _ = await waitUntil({ !spy.asked.withLock { $0 }.isEmpty }, within: 0.2)

        #expect(spy.asked.withLock { $0 }.isEmpty)
    }

    @Test("playing on does not ask for the same clip again")
    func doesNotAskTwiceForTheSameClip() async throws {
        let video = try item("/b/src/1/clip.mp4")
        let spy = SpyCompleter()
        let model = try makeModel([video], completer: spy)

        model.playbackState = .playing
        #expect(await waitUntil { spy.asked.withLock { $0 }.count == 1 })
        model.playbackState = .buffering
        model.playbackState = .playing
        _ = await waitUntil({ spy.asked.withLock { $0 }.count > 1 }, within: 0.2)

        #expect(spy.asked.withLock { $0 }.count == 1)
    }

    @Test("paging to another file stops fetching the last one")
    func pagingStopsTheFetch() async throws {
        let first = try item("/b/src/1/one.mp4", postNum: 1)
        let second = try item("/b/src/1/two.mp4", postNum: 2)
        let spy = SpyCompleter()
        let model = try makeModel([first, second], completer: spy)

        model.playbackState = .playing
        #expect(await waitUntil { spy.asked.withLock { $0 }.count == 1 })
        model.currentIndex = 1
        model.resetPlayback()

        #expect(await waitUntil { spy.cancelledAll.withLock { $0 } >= 1 })
    }

    @Test("closing the gallery stops fetching")
    func closingStopsTheFetch() async throws {
        let video = try item("/b/src/1/clip.mp4")
        let spy = SpyCompleter()
        let model = try makeModel([video], completer: spy)

        model.playbackState = .playing
        #expect(await waitUntil { spy.asked.withLock { $0 }.count == 1 })
        model.finishPlayback()

        #expect(await waitUntil { spy.cancelledAll.withLock { $0 } >= 1 })
    }

    @Test("how much is on disk reaches the scrubber")
    func progressReachesTheScrubber() async throws {
        let video = try item("/b/src/1/clip.mp4")
        let spy = SpyCompleter()
        let model = try makeModel([video], completer: spy)

        #expect(model.bufferedFraction == 0)
        model.playbackState = .playing
        #expect(await waitUntil { spy.report.withLock { $0 } != nil })

        let report = try #require(spy.report.withLock { $0 })
        report(0.4)
        #expect(await waitUntil { model.bufferedFraction == 0.4 })
    }

    @Test("paging to another file empties the buffer bar")
    func pagingClearsTheBar() async throws {
        let first = try item("/b/src/1/one.mp4", postNum: 1)
        let second = try item("/b/src/1/two.mp4", postNum: 2)
        let spy = SpyCompleter()
        let model = try makeModel([first, second], completer: spy)

        model.playbackState = .playing
        #expect(await waitUntil { spy.report.withLock { $0 } != nil })
        let report = try #require(spy.report.withLock { $0 })
        report(0.8)
        #expect(await waitUntil { model.bufferedFraction == 0.8 })

        model.currentIndex = 1
        model.resetPlayback()

        #expect(model.bufferedFraction == 0, "the new clip inherited the old one's bar")
    }
}
