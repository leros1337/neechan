import CoreMedia
import Foundation
import NeechanTestSupport
import Synchronization
import Testing
@testable import NeechanMedia

/// Seeking, from the file to the first picture, without a clock or a screen.
@Suite("Seeking a pipeline", .serialized)
struct PipelineSeekTests {
    private func file(_ fixture: Fixture) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seek-\(UUID().uuidString).\(fixture.fileExtension)")
        try FixtureLoader.data(fixture).write(to: url)
        return url
    }

    private func wait(seconds: TimeInterval = 10, for condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// The 2ch clip this came from has one keyframe in its first eleven
    /// seconds and an index listing every frame. A seek believed the index,
    /// the decoder refused every frame up to the next real keyframe, and the
    /// clip either failed or showed that keyframe's picture over the sound
    /// from where the reader had asked.
    @Test("a seek in a file whose index lies shows the picture that was asked for")
    func seekShowsTheTarget() async throws {
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }

        let url = try file(.sampleMisindexed)
        defer { try? FileManager.default.removeItem(at: url) }

        let pipeline = try Pipeline(source: .file(url))
        defer { pipeline.cancel() }

        let answered = Mutex<[TimeInterval]>([])
        let failures = Mutex<[String]>([])
        pipeline.onFirstFrame = { picture in
            if let target = picture.forSeek { answered.withLock { $0.append(target) } }
        }
        pipeline.onFailed = { message in failures.withLock { $0.append(message) } }
        pipeline.start()

        pipeline.seek(to: 2)
        #expect(await wait { answered.withLock { $0.contains(2) } }, "the seek was never answered")

        let first = try #require(pipeline.videoFrames.peek())
        let shown = TimeMath.seconds(first.presentation)
        #expect(shown >= 2 && shown < 2.1, "the first picture after the seek was at \(shown)s")
        #expect(failures.withLock { $0 }.isEmpty, "the clip failed: \(failures.withLock { $0 })")
    }
}
