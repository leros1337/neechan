import Foundation
import NeechanAPI
import NeechanAPITesting
import NeechanCore
import NeechanMedia
import NeechanSettings
import NeechanTestSupport
import Testing
@testable import NeechanUI

/// The feed of a thread's videos.
///
/// What can be asked here is everything but the picture: which clips the feed
/// holds, what it asks the player for, what it sends as the reader pages, and
/// what it warms. That only one decoder is alive, and that a warm shortened a
/// wait, cannot be asserted anywhere — the first is a property of a view's
/// lifetime and the second is a stopwatch. Looping end to end belongs to
/// `VideoLoopingUITests`, which drives the engine; what is asserted here is
/// that this mode always asks for it.
@Suite("Doomscroll", .serialized)
@MainActor
struct DoomscrollTests {
    /// Records what the feed asked to have warmed.
    private final class WarmSpy: MediaWarming, @unchecked Sendable {
        private let lock = NSLock()
        private var _warmed: [URL] = []
        private var _cancels = 0

        var warmed: [URL] { lock.withLock { _warmed } }
        var cancels: Int { lock.withLock { _cancels } }

        func warm(_ url: URL, referer: URL?) async {
            lock.withLock { _warmed.append(url) }
        }

        func cancelAll() async {
            lock.withLock { _cancels += 1 }
        }
    }

    /// Built by decoding, the way the site delivers them. Type 6 is WebM, 10 is
    /// MP4, 1 is a JPEG.
    private func attachment(_ name: String, type: Int) throws -> NeechanAPI.Attachment {
        let json = """
        {"path": "/b/src/1/\(name)", "thumbnail": "/b/thumb/1/s.jpg", \
        "name": "\(name)", "type": \(type)}
        """
        return try JSONDecoder().decode(NeechanAPI.Attachment.self, from: Data(json.utf8))
    }

    private func item(_ name: String, type: Int, postNum: Int) throws -> GalleryItem {
        GalleryItem(
            attachment: try attachment(name, type: type),
            postNum: postNum,
            threadKey: ThreadKey(site: .dvach, board: "b", threadNum: 1)
        )
    }

    private func makeModel(
        mixed: Bool = true,
        warmer: WarmSpy = WarmSpy(),
        configure: (AppSettings) -> Void = { _ in }
    ) throws -> (DoomscrollViewModel, WarmSpy) {
        let settings = AppSettings(
            defaults: UserDefaults(suiteName: "doomscroll.\(UUID().uuidString)")!
        )
        configure(settings)
        let services = try AppServices.inMemory(settings: settings, transport: StubTransport())

        var items: [GalleryItem] = [
            try item("1.webm", type: 6, postNum: 1),
            try item("2.mp4", type: 10, postNum: 2),
            try item("3.webm", type: 6, postNum: 3),
        ]
        if mixed {
            items.insert(try item("a.jpg", type: 1, postNum: 9), at: 1)
            items.append(try item("b.png", type: 2, postNum: 10))
        }
        let model = DoomscrollViewModel(items: items, services: services, warmer: warmer)
        return (model, warmer)
    }

    // MARK: What the feed holds

    @Test("only videos, in the order they were posted")
    func onlyVideos() throws {
        let (model, _) = try makeModel()
        #expect(model.items.count == 3, "an image reached a feed of videos")
        #expect(model.items.map(\.postNum) == [1, 2, 3])
        #expect(model.items.allSatisfy { $0.isVideo })
    }

    @Test("a thread with no video makes an empty feed rather than a broken one")
    func noVideosIsEmpty() throws {
        let settings = AppSettings(
            defaults: UserDefaults(suiteName: "doomscroll.\(UUID().uuidString)")!
        )
        let services = try AppServices.inMemory(settings: settings, transport: StubTransport())
        let model = DoomscrollViewModel(
            items: [try item("a.jpg", type: 1, postNum: 1)], services: services
        )
        #expect(model.items.isEmpty)
        #expect(model.currentItem == nil)
        #expect(model.positionText.isEmpty)
    }

    @Test("the position counts videos, not attachments")
    func positionCountsVideos() throws {
        let (model, _) = try makeModel()
        #expect(model.positionText == "1 / 3")
        model.settled(on: model.items[2].id)
        #expect(model.positionText == "3 / 3")
    }

    // MARK: What it asks the player for

    /// The assertion that proves the mode overrides the reader's preferences
    /// rather than happening to agree with them.
    @Test("it always loops and always autoplays, whatever the settings say")
    func loopingAndAutoplayAreForced() throws {
        let (model, _) = try makeModel { settings in
            settings.videoLoops = false
            settings.videoAutoplay = false
        }
        let options = try #require(model.currentItem.map(model.playerOptions(for:)))
        #expect(options.loops, "a feed that stops at the end of a clip is not a feed")
        #expect(options.autoplays, "autoplay is the feature")
    }

    @Test("it starts muted")
    func startsMuted() throws {
        let (model, _) = try makeModel()
        #expect(model.isMuted)
        let options = try #require(model.currentItem.map(model.playerOptions(for:)))
        #expect(options.startsMuted)
    }

    @Test("turning the sound on reaches the player, and the options with it")
    func mutingReachesThePlayer() throws {
        let (model, _) = try makeModel()
        model.toggleMute()

        #expect(!model.isMuted)
        #expect(model.playbackControl.command == .setMuted(false))
        let options = try #require(model.currentItem.map(model.playerOptions(for:)))
        #expect(!options.startsMuted, "the options kept the old mute")
    }

    /// `startsMuted` reaches the engine through an optional chain that does
    /// nothing when the layer is not built yet, so it is re-sent.
    @Test("the mute is re-sent every time a clip starts playing")
    func muteIsReappliedOnPlay() throws {
        let (model, _) = try makeModel()
        model.playbackStateChanged(.playing)
        #expect(model.playbackControl.command == .setMuted(true))

        model.toggleMute()
        model.settled(on: model.items[1].id)
        model.playbackStateChanged(.playing)
        #expect(model.playbackControl.command == .setMuted(false), "the new clip lost the choice")
    }

    // MARK: Paging

    @Test("a drag stops the clip, and settling starts the one arrived at")
    func pagingStopsAndStarts() throws {
        let (model, _) = try makeModel()

        model.beganScrolling()
        #expect(!model.isSettled)
        #expect(model.playbackControl.command == .pause)

        model.settled(on: model.items[1].id)
        #expect(model.isSettled)
        #expect(model.playingID == model.items[1].id)
        #expect(model.playbackControl.command == .play)
    }

    @Test("leaving and coming back pauses and plays")
    func suspendAndResume() async throws {
        let (model, spy) = try makeModel()
        model.suspend()
        #expect(model.playbackControl.command == .pause)
        model.resume()
        #expect(model.playbackControl.command == .setMuted(true))

        // The cancellation is handed to a task, so it lands a turn later.
        try await Task.sleep(for: .milliseconds(50))
        #expect(spy.cancels >= 1, "the warm was left running in the background")
    }

    // MARK: Warming

    @Test("the next clip is warmed once the current one is playing")
    func warmsTheNextClip() async throws {
        let (model, spy) = try makeModel()
        #expect(spy.warmed.isEmpty, "a warm started before anything was playing")

        model.playbackStateChanged(.playing)
        try await Task.sleep(for: .milliseconds(50))

        #expect(spy.warmed.count == 1)
        #expect(spy.warmed.first?.absoluteString.hasSuffix("2.mp4") == true,
                "warmed \(spy.warmed) instead of the next clip")
    }

    @Test("nothing is warmed at the last clip")
    func nothingToWarmAtTheEnd() async throws {
        let (model, spy) = try makeModel()
        model.settled(on: model.items[2].id)
        model.playbackStateChanged(.playing)
        try await Task.sleep(for: .milliseconds(50))

        #expect(spy.warmed.isEmpty, "warmed \(spy.warmed) past the end of the thread")
    }

    @Test("the same clip is not warmed twice")
    func warmsEachClipOnce() async throws {
        let (model, spy) = try makeModel()
        model.playbackStateChanged(.playing)
        model.playbackStateChanged(.playing)
        try await Task.sleep(for: .milliseconds(50))

        #expect(spy.warmed.count == 1, "warmed \(spy.warmed)")
    }

    /// Opening the mode is consent to watch; it is not consent to fetch a clip
    /// the reader has not reached.
    @Test("nothing is warmed when media loading is held back, but playing goes on")
    func noWarmingWhenMediaIsHeldBack() async throws {
        let (model, spy) = try makeModel { $0.mediaLoadPolicy = .never }
        model.playbackStateChanged(.playing)
        try await Task.sleep(for: .milliseconds(50))

        #expect(spy.warmed.isEmpty, "speculative traffic went out anyway")
        // Playback is unaffected: the clip on screen is what the reader asked for.
        let options = try #require(model.currentItem.map(model.playerOptions(for:)))
        #expect(options.autoplays)
    }
}

@Suite("Doomscroll scheduling")
struct DoomscrollPolicyTests {
    @Test("the clip after the current one, and only forwards")
    func nextClipOnly() {
        let items = ["a", "b", "c"]
        #expect(DoomscrollPolicy.clipToWarm(after: "a", in: items) == "b")
        #expect(DoomscrollPolicy.clipToWarm(after: "b", in: items) == "c")
        #expect(DoomscrollPolicy.clipToWarm(after: "c", in: items) == nil)
        #expect(DoomscrollPolicy.clipToWarm(after: "missing", in: items) == nil)
    }

    @Test("warming waits for the picture, and for permission")
    func warmingNeedsBoth() {
        #expect(DoomscrollPolicy.mayWarm(isPlaying: true, allowsMediaLoading: true))
        #expect(!DoomscrollPolicy.mayWarm(isPlaying: false, allowsMediaLoading: true))
        #expect(!DoomscrollPolicy.mayWarm(isPlaying: true, allowsMediaLoading: false))
    }
}
