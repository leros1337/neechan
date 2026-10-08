import Foundation
import NeechanTestSupport
import Testing
@testable import NeechanMedia

/// Playing a clip faster or slower than it was recorded.
@Suite("Playback speed", .serialized)
@MainActor
struct PlaybackRateTests {
    private func file(_ fixture: Fixture) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rate-\(UUID().uuidString).\(fixture.fileExtension)")
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

    /// How far the clip moves for each second of the reader's time.
    private func measuredSpeed(of player: MediaPlayer, current: @MainActor () -> TimeInterval) async throws -> Double {
        let startMedia = current()
        let startWall = ContinuousClock.now
        try await Task.sleep(for: .milliseconds(1500))
        let wall = ContinuousClock.now - startWall
        let wallSeconds = Double(wall.components.seconds) + Double(wall.components.attoseconds) / 1e18
        return (current() - startMedia) / wallSeconds
    }

    @Test("a clip at twice the speed covers twice the ground", arguments: [Float(2), 0.5])
    func rateIsKept(rate: Float) async throws {
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }
        let url = try file(.sampleLong)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = MediaPlayer()
        defer { player.shutdown() }
        var current: TimeInterval = 0
        player.onProgress = { current = $0.current }

        // Set before the clip opens: the reader picked a speed for the
        // viewer, not for the clip that happened to be on screen.
        player.playbackRate = rate
        player.load(url: url, options: MediaPlayerOptions(kind: .webmVideo))
        #expect(await wait { player.state == .playing && current > 0.1 })

        let speed = try await measuredSpeed(of: player) { current }
        #expect(abs(speed - Double(rate)) < Double(rate) * 0.25, "played at \(speed)x, asked for \(rate)x")
    }

    @Test("changing the speed of a playing clip takes effect at once")
    func rateChangesWhilePlaying() async throws {
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }
        let url = try file(.sampleLong)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = MediaPlayer()
        defer { player.shutdown() }
        var current: TimeInterval = 0
        player.onProgress = { current = $0.current }
        player.load(url: url, options: MediaPlayerOptions(kind: .webmVideo))
        #expect(await wait { player.state == .playing && current > 0.1 })

        player.playbackRate = 2

        let speed = try await measuredSpeed(of: player) { current }
        #expect(abs(speed - 2) < 0.5, "played at \(speed)x after asking for 2x")
    }

    /// A seek attaches a new audio renderer and starts the clock again, and
    /// both used to be done at the speed the clip was recorded at.
    @Test("the speed holds across a seek")
    func rateSurvivesASeek() async throws {
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }
        let url = try file(.sampleLong)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = MediaPlayer()
        defer { player.shutdown() }
        var current: TimeInterval = 0
        player.onProgress = { current = $0.current }
        player.playbackRate = 2
        player.load(url: url, options: MediaPlayerOptions(kind: .webmVideo))
        #expect(await wait { player.state == .playing && current > 0.1 })

        player.seek(to: 3)
        #expect(await wait { player.state == .playing && current > 3.1 })

        let speed = try await measuredSpeed(of: player) { current }
        #expect(abs(speed - 2) < 0.5, "played at \(speed)x after the seek")
    }

    @Test("a paused clip stays paused when the speed changes")
    func pausedStaysPaused() async throws {
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }
        let url = try file(.sampleLong)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = MediaPlayer()
        defer { player.shutdown() }
        var current: TimeInterval = 0
        player.onProgress = { current = $0.current }
        player.load(url: url, options: MediaPlayerOptions(kind: .webmVideo, autoplays: false))
        #expect(await wait { player.state == .paused })

        player.playbackRate = 1.5
        let before = current
        try await Task.sleep(for: .milliseconds(500))

        #expect(player.state == .paused)
        #expect(current == before)
    }
}
