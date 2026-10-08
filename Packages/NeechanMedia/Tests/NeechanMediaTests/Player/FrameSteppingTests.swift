import CoreMedia
import Foundation
import NeechanTestSupport
import Testing
@testable import NeechanMedia

/// Moving one picture at a time through a stopped clip.
@Suite("Frame stepping", .serialized)
@MainActor
struct FrameSteppingTests {
    private func file(_ fixture: Fixture) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("step-\(UUID().uuidString).\(fixture.fileExtension)")
        try FixtureLoader.data(fixture).write(to: url)
        return url
    }

    private func wait(
        seconds: TimeInterval = 10, for condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// A paused player on the twelve-second clip, with the renderer given a
    /// moment to take what it wants.
    private func pausedPlayer(_ url: URL) async throws -> MediaPlayer {
        let player = MediaPlayer()
        player.load(url: url, options: MediaPlayerOptions(kind: .webmVideo, autoplays: false))
        #expect(await wait { player.state == .paused })
        try await Task.sleep(for: .milliseconds(300))
        return player
    }

    /// Settled: no seek is waiting for its picture, and the renderer has
    /// been handed the one that answered it.
    private func settled(_ player: MediaPlayer) async -> Bool {
        await wait { !player.isSeeking && player.shownPresentation != nil }
    }

    /// Steps forward once, waiting for the renderer to have been handed the
    /// next picture first: a step with nothing after it does nothing.
    private func stepForward(_ player: MediaPlayer) async throws {
        let before = try #require(player.shownPresentation)
        #expect(await wait { player.hasPicture(after: before) }, "nothing after \(seconds(before)) to step to")
        player.step(forward: true)
        #expect(await wait(seconds: 2) { (player.shownPresentation ?? before) > before }, "the step from \(seconds(before)) went nowhere")
    }

    private func seconds(_ time: CMTime?) -> Double {
        time.map(TimeMath.seconds) ?? .nan
    }

    @Test("a step forward shows the next picture and nothing more")
    func stepForward() async throws {
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }
        let url = try file(.sampleLong)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = try await pausedPlayer(url)
        defer { player.shutdown() }
        let before = try #require(player.shownPresentation)

        try await stepForward(player)

        let after = try #require(player.shownPresentation)
        let gap = seconds(after) - seconds(before)
        #expect(gap > 0 && gap < 0.1, "moved \(gap)s for one picture")
        #expect(player.state == .paused)
        if let displayed = player.displayedPresentation {
            #expect(abs(seconds(displayed) - seconds(after)) < 0.001, "the renderer shows \(seconds(displayed)), the clock says \(seconds(after))")
        }
    }

    @Test("a step back undoes a step forward, exactly")
    func stepBack() async throws {
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }
        let url = try file(.sampleLong)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = try await pausedPlayer(url)
        defer { player.shutdown() }
        for _ in 0..<3 { try await stepForward(player) }
        let third = try #require(player.shownPresentation)
        try await stepForward(player)

        player.step(forward: false)
        #expect(await settled(player))

        #expect(
            abs(seconds(player.shownPresentation) - seconds(third)) < 0.001,
            "stepped back to \(seconds(player.shownPresentation)), wanted \(seconds(third))"
        )
        #expect(player.state == .paused)
        if let displayed = player.displayedPresentation {
            #expect(abs(seconds(displayed) - seconds(third)) < 0.001, "the renderer shows \(seconds(displayed))")
        }
    }

    /// A stopped renderer holds a handful of pictures and takes no more, so
    /// a walk forward has to keep handing it the next ones.
    @Test("a walk forward goes past the pictures the renderer held at first")
    func longWalkForward() async throws {
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }
        let url = try file(.sampleLong)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = try await pausedPlayer(url)
        defer { player.shutdown() }

        for _ in 0..<20 { try await stepForward(player) }

        let reached = seconds(player.shownPresentation)
        #expect(reached > 1, "twenty pictures in reached only \(reached)s")
        if let displayed = player.displayedPresentation {
            #expect(abs(seconds(displayed) - reached) < 0.001, "the renderer shows \(seconds(displayed))")
        }
        player.step(forward: false)
        #expect(await settled(player))
        #expect(seconds(player.shownPresentation) < reached)
    }

    /// After a seek the pictures before where it landed were never handed to
    /// the renderer, so the one before has to be found by going back for it.
    @Test("a step back from where a seek landed shows the picture before it")
    func stepBackAfterSeek() async throws {
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }
        let url = try file(.sampleLong)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = try await pausedPlayer(url)
        defer { player.shutdown() }
        player.seek(to: 6)
        #expect(await settled(player))
        try await Task.sleep(for: .milliseconds(200))
        let landed = seconds(player.shownPresentation)
        #expect(landed >= 6 && landed < 6.1, "the seek landed at \(landed)")

        player.step(forward: false)
        #expect(await settled(player))

        let back = seconds(player.shownPresentation)
        #expect(back < landed && back > landed - 0.1, "stepped back from \(landed) to \(back)")
        #expect(player.state == .paused)
        player.step(forward: false)
        #expect(await settled(player))
        let further = seconds(player.shownPresentation)
        #expect(further < back && further > back - 0.1, "stepped back again from \(back) to \(further)")
    }

    /// A paused seek used to leave the old picture up when the first picture
    /// at the target came a little after it: the clock stayed at the target,
    /// before the picture's time, so it was never shown.
    @Test("a seek while paused shows the picture it landed on")
    func pausedSeekShowsItsPicture() async throws {
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }
        let url = try file(.sampleLong)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = try await pausedPlayer(url)
        defer { player.shutdown() }

        player.seek(to: 4.013)
        #expect(await settled(player))
        try await Task.sleep(for: .milliseconds(200))

        let shown = seconds(player.shownPresentation)
        #expect(shown >= 4.013 && shown < 4.1, "the clock shows the picture at \(shown)")
        if let displayed = player.displayedPresentation {
            #expect(abs(seconds(displayed) - shown) < 0.001, "the renderer shows \(seconds(displayed))")
        }
        #expect(player.state == .paused)
    }

    @Test("a finished clip steps back into itself and stays paused")
    func stepFromTheEnd() async throws {
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }
        let url = try file(.sampleVP9Profile0)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = MediaPlayer()
        defer { player.shutdown() }
        player.load(url: url, options: MediaPlayerOptions(kind: .webmVideo))
        #expect(await wait { player.state == .finished })
        let end = seconds(player.shownPresentation)

        player.step(forward: false)
        #expect(await settled(player))
        try await Task.sleep(for: .milliseconds(300))

        #expect(player.state == .paused)
        #expect(seconds(player.shownPresentation) < end)
    }

    @Test("a playing clip is not stepped")
    func noStepWhilePlaying() async throws {
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }
        let url = try file(.sampleLong)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = MediaPlayer()
        defer { player.shutdown() }
        player.load(url: url, options: MediaPlayerOptions(kind: .webmVideo))
        #expect(await wait { player.state == .playing })

        player.step(forward: false)

        #expect(player.state == .playing)
        #expect(player.isSeeking == false)
    }
}
