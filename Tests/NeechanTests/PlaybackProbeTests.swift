import Foundation
import NeechanMedia
import NeechanTestSupport
import Testing

/// A video reaches the engine and comes out playable, on the simulator.
///
/// Headless: the same engine and options the viewer uses, without the view.
/// This is what found the two reasons videos were not playing — the engine
/// being asked to fetch from a mirror that refuses it, and an MP4 being handed
/// to AVFoundation — so it stays as the floor under both.
@Suite("Playback on the simulator", .serialized)
@MainActor
struct PlaybackProbeTests {
    @Test("a local webm becomes playable, not merely ready")
    func localWebMIsPlayable() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("playback-\(UUID().uuidString).webm")
        try FixtureLoader.data(.sampleVideo).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let report = await PlaybackDiagnostics.open(url, options: MediaPlayerOptions(kind: .webmVideo))

        #expect(report.isPlayable, "\(report.error ?? "no error reported")")
        #expect(report.naturalSize == CGSize(width: 320, height: 240))
    }
}
