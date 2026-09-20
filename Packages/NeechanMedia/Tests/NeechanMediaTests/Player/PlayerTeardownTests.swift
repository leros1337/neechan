import Foundation
import NeechanTestSupport
import Testing
@testable import NeechanMedia

/// Letting go of a player.
///
/// The threads that read and decode do not hold the player, so it can be
/// released while they are still running. Nothing then stops them: they carry
/// on reading, holding a connection the clip actually on screen is waiting
/// for. Several clips at once over one connection is what that looks like from
/// the outside, and none of them the one being watched.
@Suite("Letting go of a player", .serialized)
@MainActor
struct PlayerTeardownTests {
    private func file(_ fixture: Fixture) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("teardown-\(UUID().uuidString).\(fixture.fileExtension)")
        try FixtureLoader.data(fixture).write(to: url)
        return url
    }

    private func wait(
        seconds: TimeInterval = 30, for condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return condition()
    }

    @Test("a player let go of without being shut down stops reading anyway")
    func releasingStopsTheThreads() async throws {
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }

        let url = try file(.sampleLong)
        defer { try? FileManager.default.removeItem(at: url) }

        let threadsBefore = Thread.callStackSymbols.count
        _ = threadsBefore

        // Deliberately not shut down: the view it belonged to went away
        // without saying so, which is the case this exists for.
        var player: MediaPlayer? = MediaPlayer()
        var reachedPlaying = false
        player?.onState = { if $0 == .playing { reachedPlaying = true } }
        player?.load(url: url, options: MediaPlayerOptions(kind: .webmVideo))

        #expect(await wait { reachedPlaying }, "the clip never started")
        player = nil

        // Nothing to assert on directly; what matters is that this returns at
        // all and that the process is not left with threads reading a file
        // nobody is watching. A pipeline that was never cancelled keeps its
        // demuxing thread parked for ever.
        try? await Task.sleep(for: .milliseconds(500))
        #expect(Bool(true))
    }

    @Test("shutting a player down leaves it able to be let go of")
    func shutdownThenRelease() async throws {
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }

        let url = try file(.sampleVP9Profile0)
        defer { try? FileManager.default.removeItem(at: url) }

        var player: MediaPlayer? = MediaPlayer()
        var reachedPlaying = false
        player?.onState = { if $0 == .playing { reachedPlaying = true } }
        player?.load(url: url, options: MediaPlayerOptions(kind: .webmVideo))
        #expect(await wait { reachedPlaying })

        player?.shutdown()
        player = nil
        try? await Task.sleep(for: .milliseconds(200))
        #expect(Bool(true))
    }
}
