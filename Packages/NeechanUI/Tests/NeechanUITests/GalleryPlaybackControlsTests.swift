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
