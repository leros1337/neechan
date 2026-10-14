import Foundation
import NeechanAPI
import NeechanAPITesting
import NeechanCore
import NeechanMedia
import NeechanSettings
import Testing
@testable import NeechanUI

/// The viewer's controls for a clip beyond play and pause.
@Suite("Gallery playback controls")
@MainActor
struct GalleryPlaybackControlsTests {
    private func makeModel() throws -> GalleryViewModel {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "controls.\(UUID().uuidString)")!)
        let services = try AppServices.inMemory(settings: settings, transport: StubTransport())
        let json = #"{"path": "/b/src/1/1.mp4", "thumbnail": "/b/thumb/1/1s.jpg", "name": "1.mp4", "type": 10}"#
        let item = GalleryItem(
            attachment: try JSONDecoder().decode(Attachment.self, from: Data(json.utf8)),
            postNum: 7,
            threadKey: ThreadKey(site: .dvach, board: "b", threadNum: 1)
        )
        return GalleryViewModel(items: [item], startIndex: 0, services: services)
    }

    @Test("a viewer opens at the speed clips were recorded at")
    func opensAtNormalSpeed() throws {
        let model = try makeModel()
        defer { model.finishPlayback() }

        #expect(model.playbackRate == 1)
        #expect(model.player.playbackRate == 1)
    }

    /// The gallery has one player for every clip in it, so the speed set on
    /// it is the speed of the next clip too.
    @Test("the speed picked reaches the player, and stays as the reader pages")
    func speedReachesThePlayer() throws {
        let model = try makeModel()
        defer { model.finishPlayback() }

        model.playbackRate = 1.5
        model.resetPlayback()

        #expect(model.player.playbackRate == 1.5)
        #expect(model.playbackRate == 1.5)
    }

    // MARK: Mute

    @Test("a viewer opens with the sound on")
    func opensWithSound() throws {
        let model = try makeModel()
        defer { model.finishPlayback() }

        #expect(!model.isMuted)
        #expect(!model.playerOptions(for: model.items[0]).startsMuted)
    }

    /// The one player loads every clip with the options' mute, so a mute that
    /// is not in them is lost on the next page while the button still says
    /// muted.
    @Test("muting one clip keeps the next one muted")
    func muteCarriesToTheNextClip() throws {
        let model = try makeModel()
        defer { model.finishPlayback() }

        model.toggleMuted()
        model.resetPlayback()

        #expect(model.isMuted)
        #expect(model.playerOptions(for: model.items[0]).startsMuted)
    }

    @Test("the options follow the mute rather than keeping the first one")
    func optionsFollowTheMute() throws {
        let model = try makeModel()
        defer { model.finishPlayback() }
        let item = model.items[0]
        _ = model.playerOptions(for: item)

        model.toggleMuted()
        #expect(model.playerOptions(for: item).startsMuted, "the options kept the old mute")
        model.toggleMuted()
        #expect(!model.playerOptions(for: item).startsMuted, "the options kept the old mute")
    }

    @Test("the mute is applied again when a clip starts playing")
    func muteIsReappliedOnPlay() throws {
        let model = try makeModel()
        defer { model.finishPlayback() }

        model.toggleMuted()
        // Standing in for a load that came up with the sound on.
        model.player.isMuted = false
        model.playbackState = .playing

        #expect(model.player.isMuted, "the clip played with sound under a muted button")
    }

    // MARK: Scrubbing

    @Test("holding the scrubber says where, and letting go clears it")
    func scrubbingFollowsTheFinger() throws {
        let model = try makeModel()
        defer { model.finishPlayback() }
        model.playbackProgress = PlaybackProgress(current: 0, total: 12)

        model.scrub(to: 0.5)

        #expect(model.scrubbing?.fraction == 0.5)
        #expect(model.scrubbing?.seconds == 6)
        model.endScrub()
        #expect(model.scrubbing == nil)
    }

    /// A clip that does not say how long it is cannot be scrubbed at all.
    @Test("no preview for a clip without a length")
    func noScrubWithoutLength() throws {
        let model = try makeModel()
        defer { model.finishPlayback() }

        model.scrub(to: 0.5)

        #expect(model.scrubbing == nil)
    }
}
