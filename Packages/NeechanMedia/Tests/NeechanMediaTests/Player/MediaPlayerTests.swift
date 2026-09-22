import CoreMedia
import Synchronization
import Foundation
import NeechanTestSupport
import Testing
@testable import NeechanMedia

/// A clip, end to end: opened, decoded, clocked and reported on.
///
/// The pieces below this are covered on their own. This is the one that would
/// catch them being wired together wrongly, which is the failure that reaches
/// a reader as a clip that sits there doing nothing.
@Suite("Playing a clip", .serialized)
@MainActor
struct MediaPlayerTests {
    private func file(_ fixture: Fixture) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("play-\(UUID().uuidString).\(fixture.fileExtension)")
        try FixtureLoader.data(fixture).write(to: url)
        return url
    }

    /// Waits for `condition`, or gives up.
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

    @Test(
        "every kind of file plays through to the end",
        arguments: [
            (Fixture.sampleVP9Profile0, MediaKind.webmVideo),
            (.sampleVP8, .webmVideo),
            (.sampleH264, .mp4Video),
            (.sampleHEV1, .mp4Video),
            (.sampleMatroska, .webmVideo)
        ]
    )
    func everyFilePlays(fixture: Fixture, kind: MediaKind) async throws {
        // One playback test at a time; see PlayerTestGate.
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }

        let url = try file(fixture)
        defer { try? FileManager.default.removeItem(at: url) }

        let player = MediaPlayer()
        defer { player.shutdown() }

        var seen: [PlaybackState] = []
        player.onState = { seen.append($0) }

        player.load(url: url, options: MediaPlayerOptions(kind: kind))

        #expect(
            await wait { player.state == .playing },
            "\(fixture.rawValue) never started: \(seen), \(player.lastFailure ?? "no error")"
        )
        #expect(player.naturalSize.width > 0)

        #expect(
            await wait { player.state == .finished },
            "\(fixture.rawValue) never finished: \(seen)"
        )
        #expect(seen.contains(.preparing), "the clip never reported that it was opening")
    }

    @Test("progress is reported while a clip runs")
    func progressAdvances() async throws {
        // One playback test at a time; see PlayerTestGate.
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }

        let url = try file(.sampleVP9Profile0)
        defer { try? FileManager.default.removeItem(at: url) }

        let player = MediaPlayer()
        defer { player.shutdown() }

        var furthest: TimeInterval = 0
        var reportedTotal: TimeInterval = 0
        player.onProgress = { progress in
            furthest = max(furthest, progress.current)
            reportedTotal = progress.total
        }

        player.load(url: url, options: MediaPlayerOptions(kind: .webmVideo))
        #expect(await wait { furthest > 0.2 }, "progress never moved")
        #expect(reportedTotal > 0.9 && reportedTotal < 1.2, "duration was \(reportedTotal)")
    }

    @Test("a clip that is not set to play by itself waits")
    func autoplayIsObeyed() async throws {
        // One playback test at a time; see PlayerTestGate.
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }

        let url = try file(.sampleVP9Profile0)
        defer { try? FileManager.default.removeItem(at: url) }

        let player = MediaPlayer()
        defer { player.shutdown() }
        player.load(
            url: url,
            options: MediaPlayerOptions(kind: .webmVideo, autoplays: false)
        )

        #expect(await wait { player.state == .paused }, "the clip started by itself")
        player.play()
        #expect(await wait { player.state == .playing })
    }

    /// A looping clip never reports that it finished, because it never does.
    @Test("a looping clip keeps going instead of ending")
    func loopingNeverFinishes() async throws {
        // One playback test at a time; see PlayerTestGate.
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }

        let url = try file(.sampleVP9Profile0)
        defer { try? FileManager.default.removeItem(at: url) }

        let player = MediaPlayer()
        defer { player.shutdown() }

        var reportedFinished = false
        player.onState = { if $0 == .finished { reportedFinished = true } }
        player.load(url: url, options: MediaPlayerOptions(kind: .webmVideo, loops: true))

        #expect(await wait { player.state == .playing })
        // Longer than the clip, so it has been round at least once.
        try? await Task.sleep(for: .milliseconds(1_600))
        #expect(!reportedFinished, "a looping clip reported that it finished")
        #expect(player.state == .playing, "a looping clip stopped: \(player.state)")
    }

    @Test("pausing stops the clock and playing starts it again")
    func pauseAndResume() async throws {
        // One playback test at a time; see PlayerTestGate.
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }

        let url = try file(.sampleVP9Profile0)
        defer { try? FileManager.default.removeItem(at: url) }

        let player = MediaPlayer()
        defer { player.shutdown() }
        player.load(url: url, options: MediaPlayerOptions(kind: .webmVideo, loops: true))
        #expect(await wait { player.state == .playing })

        player.pause()
        #expect(player.state == .paused)

        var whilePaused: TimeInterval = 0
        player.onProgress = { whilePaused = $0.current }
        try? await Task.sleep(for: .milliseconds(300))
        let settled = whilePaused
        try? await Task.sleep(for: .milliseconds(300))
        #expect(whilePaused == settled, "the clock kept running while paused")

        player.play()
        #expect(await wait { player.state == .playing })
    }

    @Test("a file that is not media reports a failure rather than sitting there")
    func brokenFilesFail() async throws {
        // One playback test at a time; see PlayerTestGate.
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("play-\(UUID().uuidString).webm")
        try Data(repeating: 0x41, count: 4_096).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let player = MediaPlayer()
        defer { player.shutdown() }
        player.load(url: url, options: MediaPlayerOptions(kind: .webmVideo))

        #expect(await wait(seconds: 5) {
            if case .failed = player.state { return true }
            return false
        }, "a broken file never reported a failure: \(player.state)")
        // The reader is shown one sentence; the detail is kept for diagnostics.
        #expect(player.lastFailure != nil)
    }

    /// What a feed does: one player, one layer, a different clip.
    @Test("the same player can be handed another clip")
    func swappingTheClip() async throws {
        // One playback test at a time; see PlayerTestGate.
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }

        let first = try file(.sampleVP9Profile0)
        let second = try file(.sampleH264)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let player = MediaPlayer()
        defer { player.shutdown() }
        let layer = player.displayLayer

        player.load(url: first, options: MediaPlayerOptions(kind: .webmVideo))
        #expect(await wait { player.state == .playing })

        player.load(url: second, options: MediaPlayerOptions(kind: .mp4Video))
        #expect(await wait { player.state == .playing }, "the second clip never started")
        #expect(player.displayLayer === layer, "the layer was replaced along with the clip")
    }
}

/// Clips that are missing one half, and players handed one clip after another.
///
/// The reason this suite exists: the audio renderer is attached to the clock
/// only while a clip has sound, because a clock slaved to an audio renderer
/// that will never be fed does not advance and the picture sits still. That
/// attaching is also the one API here that aborts the process outright when it
/// is done twice, which is exactly what a feed swapping clips would do. Both
/// failures are invisible to a test that only ever plays one ordinary file.
@Suite("Clips missing a stream, and players reused", .serialized)
@MainActor
struct PlayerStreamCombinationTests {
    private func file(_ fixture: Fixture) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("streams-\(UUID().uuidString).\(fixture.fileExtension)")
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

    /// A silent clip must not wait for a clock that will never tick.
    @Test("a clip with no sound plays and ends")
    func videoOnlyPlays() async throws {
        // One playback test at a time; see PlayerTestGate.
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }

        let url = try file(.sampleVideoOnly)
        defer { try? FileManager.default.removeItem(at: url) }

        let player = MediaPlayer()
        defer { player.shutdown() }
        var furthest: TimeInterval = 0
        player.onProgress = { furthest = max(furthest, $0.current) }
        player.load(url: url, options: MediaPlayerOptions(kind: .webmVideo))

        #expect(await wait { player.state == .playing }, "a silent clip never started")
        #expect(await wait { furthest > 0.2 }, "the clock did not advance without audio")
        #expect(await wait { player.state == .finished }, "a silent clip never ended")
    }

    @Test("a clip with no picture plays and ends")
    func audioOnlyPlays() async throws {
        // One playback test at a time; see PlayerTestGate.
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }

        let url = try file(.sampleAudioOnly)
        defer { try? FileManager.default.removeItem(at: url) }

        let player = MediaPlayer()
        defer { player.shutdown() }
        player.load(url: url, options: MediaPlayerOptions(kind: .webmVideo))

        #expect(await wait { player.state == .playing }, "a soundtrack never started")
        #expect(await wait { player.state == .finished }, "a soundtrack never ended")
    }

    /// The abort this guards against: the audio renderer being attached to the
    /// clock a second time. It takes a clip with sound, then one without, then
    /// one with again, which is the order that moves the renderer on and off.
    @Test("one player survives clips that gain and lose their sound")
    func swappingBetweenSilentAndNot() async throws {
        // One playback test at a time; see PlayerTestGate.
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }

        let withSound = try file(.sampleVP9Profile0)
        let silent = try file(.sampleVideoOnly)
        let soundOnly = try file(.sampleAudioOnly)
        defer {
            for url in [withSound, silent, soundOnly] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let player = MediaPlayer()
        defer { player.shutdown() }
        let layer = player.displayLayer

        for url in [withSound, silent, soundOnly, silent, withSound] {
            player.load(url: url, options: MediaPlayerOptions(kind: .webmVideo))
            #expect(
                await wait { player.state == .playing },
                "\(url.lastPathComponent) never started after a swap"
            )
        }
        #expect(player.displayLayer === layer, "the layer was replaced along with the clip")
    }

    /// A feed pages quickly, so a clip is often replaced before it has opened.
    @Test("a player handed clips faster than it can open them keeps up")
    func rapidSwapsDoNotPileUp() async throws {
        // One playback test at a time; see PlayerTestGate.
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }

        let first = try file(.sampleVP9Profile0)
        let second = try file(.sampleVideoOnly)
        let third = try file(.sampleH264)
        defer {
            for url in [first, second, third] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let player = MediaPlayer()
        defer { player.shutdown() }

        // No waiting in between: each load lands while the one before it is
        // still opening, and only the last should ever reach the screen.
        player.load(url: first, options: MediaPlayerOptions(kind: .webmVideo))
        player.load(url: second, options: MediaPlayerOptions(kind: .webmVideo))
        player.load(url: third, options: MediaPlayerOptions(kind: .mp4Video))

        #expect(await wait { player.state == .playing }, "nothing played after rapid swaps")
        #expect(player.naturalSize == CGSize(width: 64, height: 64))
    }
}

/// Clips long enough to outlast what the renderer was handed at the start.
///
/// Every other fixture is a second long, which the renderer swallows whole
/// before the clock has moved: nothing in those tests ever asks the player to
/// keep a clip fed. A real clip does, and a player that cannot stops dead a
/// few seconds in with the picture frozen and no error, which is exactly what
/// this suite exists to catch.
@Suite("Clips that outlast the first buffer", .serialized)
@MainActor
struct LongClipTests {
    private func file(_ fixture: Fixture) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("long-\(UUID().uuidString).\(fixture.fileExtension)")
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

    @Test("a twelve-second clip plays all the way through")
    func aLongClipDoesNotStopHalfway() async throws {
        // One playback test at a time; see PlayerTestGate.
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }

        let url = try file(.sampleLong)
        defer { try? FileManager.default.removeItem(at: url) }

        let player = MediaPlayer()
        defer { player.shutdown() }

        var furthest: TimeInterval = 0
        var stateChanges = 0
        player.onProgress = { furthest = max(furthest, $0.current) }
        player.onState = { _ in stateChanges += 1 }
        player.load(url: url, options: MediaPlayerOptions(kind: .webmVideo))

        #expect(await wait { player.state == .playing }, "the clip never started")

        // Past where the renderer's first handful of frames runs out. A player
        // that stops being fed freezes here with the clock standing still.
        #expect(
            await wait { furthest > 8 },
            "playback stalled at \(furthest)s of 12"
        )
        #expect(await wait { player.state == .finished }, "the clip never reached its end")
        #expect(furthest > 11, "the clip ended early, at \(furthest)s")

        // The regression underneath the freeze: the player flipping between
        // playing and buffering hundreds of times a second while the picture
        // stayed still. A dozen seconds of video does not need many changes.
        #expect(stateChanges < 30, "the player changed state \(stateChanges) times")
    }

    @Test("seeking into a long clip carries on from there")
    func seekingCarriesOn() async throws {
        // One playback test at a time; see PlayerTestGate.
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }

        let url = try file(.sampleLong)
        defer { try? FileManager.default.removeItem(at: url) }

        let player = MediaPlayer()
        defer { player.shutdown() }

        var latest: TimeInterval = 0
        player.onProgress = { latest = $0.current }
        player.load(url: url, options: MediaPlayerOptions(kind: .webmVideo))
        #expect(await wait { player.state == .playing })

        player.seek(to: 6)
        // Playing again, not merely repositioned: the clock is moved to the
        // target the moment the seek is asked for, so a check on the time
        // alone passes before anything has been decoded.
        #expect(
            await wait { player.state == .playing && latest >= 6 },
            "the clip stopped at the seek: \(player.state), clock \(latest)s"
        )

        // And keeps going afterwards rather than freezing where it landed.
        let landed = latest
        #expect(
            await wait { latest > landed + 1.5 },
            "playback stopped after seeking, at \(latest)s"
        )
    }

    /// Scrubbing is many seeks in quick succession, which is what the viewer's
    /// timeline sends while a finger is moving.
    @Test("scrubbing back and forth leaves the clip playing")
    func repeatedSeeksKeepPlaying() async throws {
        // One playback test at a time; see PlayerTestGate.
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }

        let url = try file(.sampleLong)
        defer { try? FileManager.default.removeItem(at: url) }

        let player = MediaPlayer()
        defer { player.shutdown() }

        var latest: TimeInterval = 0
        player.onProgress = { latest = $0.current }
        player.load(url: url, options: MediaPlayerOptions(kind: .webmVideo))
        #expect(await wait { player.state == .playing })

        for target in [8.0, 2.0, 9.0, 4.0] {
            player.seek(to: target)
            try? await Task.sleep(for: .milliseconds(120))
        }

        #expect(await wait { player.state == .playing }, "scrubbing left the clip stopped")
        let landed = latest
        #expect(
            await wait { latest > landed + 1 },
            "the clip did not carry on after scrubbing, stuck at \(latest)s"
        )
    }
}

/// Playing a clip a second time, and going round and round.
///
/// A clip that has reached its end has also, underneath, run its reader and
/// its decoders out of work. Whether they are still able to do any more is
/// what decides between a clip that plays again and one that shows its first
/// frame and stops.
@Suite("Playing a clip again", .serialized)
@MainActor
struct ReplayTests {
    private func file(_ fixture: Fixture) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("replay-\(UUID().uuidString).\(fixture.fileExtension)")
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

    /// The regression: pressing play on a finished clip showed its first frame
    /// and went no further, because the threads that would have decoded the
    /// rest had ended along with the file.
    @Test("a clip that has finished plays again when asked")
    func playingAfterTheEnd() async throws {
        // One playback test at a time; see PlayerTestGate.
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }

        let url = try file(.sampleLong)
        defer { try? FileManager.default.removeItem(at: url) }

        let player = MediaPlayer()
        defer { player.shutdown() }

        var latest: TimeInterval = 0
        player.onProgress = { latest = $0.current }
        player.load(url: url, options: MediaPlayerOptions(kind: .webmVideo))
        #expect(await wait { player.state == .finished }, "the clip never finished")

        player.play()
        #expect(await wait { player.state == .playing }, "playing again did nothing")

        // Back to the beginning, not still sitting where it ended. Checking
        // only that the reported time is large passes without the clip moving
        // at all, because it is still reporting the end of the last play.
        #expect(
            await wait { latest < 2 },
            "the clip never went back to the start, still reporting \(latest)s"
        )
        let restarted = latest
        #expect(
            await wait { latest > restarted + 2 },
            "it showed the beginning and stopped, at \(latest)s"
        )
    }

    @Test("seeking back into a clip that has finished starts it again")
    func seekingAfterTheEnd() async throws {
        // One playback test at a time; see PlayerTestGate.
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }

        let url = try file(.sampleLong)
        defer { try? FileManager.default.removeItem(at: url) }

        let player = MediaPlayer()
        defer { player.shutdown() }

        var latest: TimeInterval = 0
        player.onProgress = { latest = $0.current }
        player.load(url: url, options: MediaPlayerOptions(kind: .webmVideo))
        #expect(await wait { player.state == .finished })

        player.seek(to: 3)
        // Somewhere near three, rather than still at the end. The clip ran to
        // twelve, so "at least three" is true before anything has happened.
        #expect(
            await wait { latest >= 2.5 && latest < 5 },
            "the seek did not take, the clock reads \(latest)s"
        )
        let landed = latest
        #expect(await wait { latest > landed + 1 }, "it stopped again at \(latest)s")
    }

    /// A short clip on loop goes round many times, so this is the one that
    /// notices a restart which only works once.
    @Test("a looping clip goes round more than once")
    func loopingGoesRoundAgain() async throws {
        // One playback test at a time; see PlayerTestGate.
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }

        let url = try file(.sampleVP9Profile0)
        defer { try? FileManager.default.removeItem(at: url) }

        let player = MediaPlayer()
        defer { player.shutdown() }

        var timesRewound = 0
        var previous: TimeInterval = 0
        player.onProgress = { progress in
            if progress.current + 0.3 < previous { timesRewound += 1 }
            previous = progress.current
        }
        player.load(url: url, options: MediaPlayerOptions(kind: .webmVideo, loops: true))
        #expect(await wait { player.state == .playing })

        // The clip is a second long, so this is several times round.
        try? await Task.sleep(for: .milliseconds(3_500))
        #expect(timesRewound >= 2, "the clip went round \(timesRewound) times")
        #expect(player.state == .playing, "looping stopped: \(player.state)")
    }
}

/// Serves a fixture slowly enough that playback runs out of media.
///
/// A local file never starves, so nothing else in this suite ever asks what
/// the player does when the bytes stop keeping up. This answers each range
/// after a pause, the way a slow connection does.
final class SlowServingProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static let body: Data =
        (try? FixtureLoader.data(.sampleLong)) ?? Data()
    /// How long each answer is held back.
    nonisolated(unsafe) static let delay = Mutex(TimeInterval(0))

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "slow.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.body
        var status = 200
        var slice = body
        var headers = ["Content-Type": "video/webm"]

        if let header = request.value(forHTTPHeaderField: "Range"),
           let range = Self.parse(header, count: body.count) {
            status = 206
            slice = body.subdata(in: range)
            headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(body.count)"
        }
        headers["Content-Length"] = "\(slice.count)"

        Thread.sleep(forTimeInterval: Self.delay.withLock { $0 })

        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: slice)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func parse(_ header: String, count: Int) -> Range<Int>? {
        guard header.hasPrefix("bytes=") else { return nil }
        let parts = header.dropFirst("bytes=".count).split(
            separator: "-", omittingEmptySubsequences: false
        )
        guard let start = Int(parts.first ?? ""), start < count else { return nil }
        let end = parts.count > 1 ? Int(parts[1]) ?? count - 1 : count - 1
        return start..<min(count, end + 1)
    }
}

/// What happens when the bytes stop keeping up.
///
/// The regression this exists for: playback stopping to wait, and then waiting
/// for ever. Noticing that enough has arrived was driven by the clock, and the
/// clock is stopped while waiting, so nothing ever looked again. On a phone
/// that is a clip that stops mid-way and needs play pressed to carry on.
@Suite("Running out of media", .serialized)
@MainActor
struct StarvationTests {
    private func wait(
        seconds: TimeInterval = 60, for condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return condition()
    }

    private func slowSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowServingProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test("a clip that runs out carries on by itself once more arrives")
    func starvationRecoversWithoutHelp() async throws {
        // One playback test at a time; see PlayerTestGate.
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }

        // Small pieces, each held back: together slower than the clip plays,
        // which is what makes it run out part way through.
        SlowServingProtocol.delay.withLock { $0 = 0.8 }
        defer { SlowServingProtocol.delay.withLock { $0 = 0 } }

        let player = MediaPlayer()
        defer { player.shutdown() }

        var furthest: TimeInterval = 0
        var everWaited = false
        player.onProgress = { furthest = max(furthest, $0.current) }
        player.onState = { if $0 == .buffering { everWaited = true } }

        player.load(
            // A name of its own each time: pieces already fetched are kept on
            // disk, and a clip the store has seen before arrives instantly.
            url: URL(string: "https://slow.invalid/\(UUID().uuidString).webm")!,
            options: MediaPlayerOptions(kind: .webmVideo),
            session: slowSession(),
            blockSize: 4 << 10
        )

        #expect(await wait { player.state == .playing }, "the clip never started")

        // It has to run out first, or there is nothing to recover from.
        #expect(
            await wait(seconds: 30) { everWaited },
            "the server was not slow enough to make it wait at all"
        )
        let stalledAt = furthest

        // Nobody presses anything. Carrying on is the whole point: waiting was
        // never the bug, waiting for ever was.
        #expect(
            await wait(seconds: 45) { furthest > stalledAt + 2 },
            "it stopped at \(stalledAt)s and stayed there, reaching only \(furthest)s"
        )
        #expect(player.state != .failed(""), "it failed rather than waiting")
    }
}

/// A player handed one clip after another, the way a feed does.
///
/// The regression: the clock was left wherever the last clip got to, so a new
/// clip whose pictures start at zero arrived entirely in the past. The
/// renderer filled with frames it would never show, stopped asking for more,
/// and the clip waited for ever with everything it needed in hand.
@Suite("A player reused for clip after clip", .serialized)
@MainActor
struct ReusedPlayerTests {
    private func file(_ fixture: Fixture) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reused-\(UUID().uuidString).\(fixture.fileExtension)")
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

    /// A paged gallery builds two views for the page it lands on, and both
    /// ask the one player for the same clip. The second ask used to throw
    /// away the first's work and open the file over again.
    @Test("asking for the clip a player already holds changes nothing")
    func theSameClipAgainIsNotAReload() async throws {
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }

        let url = try file(.sampleH264)
        defer { try? FileManager.default.removeItem(at: url) }

        let player = MediaPlayer()
        defer { player.shutdown() }

        var seen: [PlaybackState] = []
        player.onState = { seen.append($0) }
        player.load(url: url, options: MediaPlayerOptions(kind: .mp4Video))
        #expect(await wait { player.state == .playing })
        let statesBefore = seen.count

        player.load(url: url, options: MediaPlayerOptions(kind: .mp4Video))

        #expect(player.state == .playing, "it went back to opening: \(seen)")
        #expect(seen.count == statesBefore, "nothing should have been announced: \(seen)")
        #expect(player.url == url)
    }

    /// After a failure, the same clip is a second attempt, not a repeat.
    @Test("a clip that failed can be asked for again")
    func aFailedClipIsTriedAgain() async throws {
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reused-\(UUID().uuidString).mp4")
        try Data("not a video".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let player = MediaPlayer()
        defer { player.shutdown() }

        player.load(url: url, options: MediaPlayerOptions(kind: .mp4Video))
        #expect(await wait { if case .failed = player.state { return true } else { return false } })

        var reopened = false
        player.onState = { if $0 == .preparing { reopened = true } }
        player.load(url: url, options: MediaPlayerOptions(kind: .mp4Video))
        #expect(reopened, "a failed clip asked for again should be opened again")
    }

    /// A view describes its player every time it appears, and a paged
    /// gallery makes the same view appear many times.
    @Test("describing a player twice names it once")
    func describingIsNotAppending() {
        let player = MediaPlayer()
        defer { player.shutdown() }

        player.describe(as: "viewer:348")
        player.describe(as: "viewer:348")

        #expect(player.name.components(separatedBy: "viewer:348").count == 2, "\(player.name)")
    }

    /// The clip before had run well past where the next one starts.
    @Test("a clip loaded after a longer one starts at its own beginning")
    func theClockGoesBackForTheNextClip() async throws {
        // One playback test at a time; see PlayerTestGate.
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }

        let long = try file(.sampleLong)
        let short = try file(.sampleVP9Profile0)
        defer {
            try? FileManager.default.removeItem(at: long)
            try? FileManager.default.removeItem(at: short)
        }

        let player = MediaPlayer()
        defer { player.shutdown() }

        var latest: TimeInterval = 0
        player.onProgress = { latest = $0.current }

        player.load(url: long, options: MediaPlayerOptions(kind: .webmVideo))
        #expect(await wait { player.state == .playing })
        #expect(await wait { latest > 4 }, "the first clip did not get far enough in")

        // The second is a second long. Left at the first clip's position, its
        // pictures would all be in the past and it would never play.
        player.load(url: short, options: MediaPlayerOptions(kind: .webmVideo))
        #expect(await wait { player.state == .playing }, "the second clip never started")
        #expect(
            await wait { latest < 1.2 },
            "the second clip carried on from the first, at \(latest)s"
        )
        #expect(await wait { player.state == .finished }, "the second clip never finished")
    }

    /// A feed asks a clip to play while it is still being opened.
    @Test("asking to play before there is a picture does not run the clock away")
    func playingBeforeThereIsAnythingToShow() async throws {
        // One playback test at a time; see PlayerTestGate.
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }

        let long = try file(.sampleLong)
        let short = try file(.sampleVP9Profile0)
        defer {
            try? FileManager.default.removeItem(at: long)
            try? FileManager.default.removeItem(at: short)
        }

        let player = MediaPlayer()
        defer { player.shutdown() }

        var latest: TimeInterval = 0
        player.onProgress = { latest = $0.current }

        player.load(url: long, options: MediaPlayerOptions(kind: .webmVideo))
        #expect(await wait { latest > 3 })

        // Loaded and told to play in the same breath, before it has opened.
        player.load(url: short, options: MediaPlayerOptions(kind: .webmVideo, autoplays: false))
        player.play()

        #expect(await wait { player.state == .playing }, "it never started")
        #expect(
            await wait { latest < 1.2 },
            "the clock ran on from the previous clip, reaching \(latest)s"
        )
    }
}

/// The end of a clip, when the end arrives while it is waiting for bytes.
///
/// The regression: a clip that ran out of media just before its end resumed
/// anyway, because everything had arrived and there was nothing more coming.
/// With nothing left to show, the clock then ran on past the end of the file
/// for ever, the last picture frozen on screen and the timeline still
/// counting up.
@Suite("Reaching the end while waiting", .serialized)
@MainActor
struct EndWhileWaitingTests {
    private func wait(
        seconds: TimeInterval = 60, for condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return condition()
    }

    @Test("a clip whose last bytes arrive slowly still ends, and ends once")
    func theEndStillArrives() async throws {
        // One playback test at a time; see PlayerTestGate.
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }

        SlowServingProtocol.delay.withLock { $0 = 0.8 }
        defer { SlowServingProtocol.delay.withLock { $0 = 0 } }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowServingProtocol.self]

        let player = MediaPlayer()
        defer { player.shutdown() }

        var furthest: TimeInterval = 0
        var timesFinished = 0
        player.onProgress = { furthest = max(furthest, $0.current) }
        player.onState = { if $0 == .finished { timesFinished += 1 } }

        player.load(
            url: URL(string: "https://slow.invalid/\(UUID().uuidString).webm")!,
            options: MediaPlayerOptions(kind: .webmVideo),
            session: URLSession(configuration: configuration),
            blockSize: 4 << 10
        )

        #expect(await wait { player.state == .playing }, "the clip never started")
        #expect(await wait { player.state == .finished }, "it never reached the end")

        // The clip is twelve seconds. A clock that ran past the end would be
        // well beyond that by the time it was noticed.
        #expect(furthest < 14, "the clock ran past the end, to \(furthest)s")
        #expect(timesFinished == 1, "it reported the end \(timesFinished) times")
    }
}

/// Clips with a half the app cannot decode.
///
/// The FFmpeg build is trimmed to what an imageboard serves, and a file from
/// anywhere else may carry sound in something it has never heard of. That is
/// survivable: the picture is what the reader came for. What is not survivable
/// is the clip never ending, which is what happened when the thread decoding
/// the sound gave up quietly and nothing was left to say that no more was
/// coming. The timeline then counted up past the end of the file for as long
/// as anyone watched it.
@Suite("Clips the app can only half decode", .serialized)
@MainActor
struct HalfDecodableTests {
    private func wait(
        seconds: TimeInterval = 40, for condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return condition()
    }

    @Test("a clip whose sound will not decode still plays, and still ends")
    func soundThatWillNotDecode() async throws {
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("deaf-\(UUID().uuidString).mkv")
        try FixtureLoader.data(.sampleUndecodableAudio).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let player = MediaPlayer()
        defer { player.shutdown() }

        var furthest: TimeInterval = 0
        player.onProgress = { furthest = max(furthest, $0.current) }
        player.load(url: url, options: MediaPlayerOptions(kind: .webmVideo))

        #expect(await wait { player.state == .playing }, "the picture never started")
        #expect(await wait { player.state == .finished }, "it never reached the end")

        // Two seconds of video. A clock with nothing to stop it would be well
        // past that by the time anyone noticed.
        #expect(furthest < 4, "the clock ran past the end, to \(furthest)s")
    }
}
