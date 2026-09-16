import AVFoundation
import Foundation
import NeechanTestSupport
import Synchronization
import Testing
@testable import NeechanMedia

/// Turning a WebM into something the rest of the system can play.
///
/// Photos refuses a WebM outright — `PHPhotosErrorDomain 3302` — and the file
/// that comes back from the board is VP9 with Opus, which no part of
/// AVFoundation can open in any container.
@Suite("WebM conversion", .serialized)
struct WebMConverterTests {
    private func makeSourceFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("webm")
        try FixtureLoader.data(.sampleVideo).write(to: url)
        return url
    }

    private func destinationFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
    }

    /// The point of the whole exercise: the input cannot be opened by
    /// AVFoundation and the output can.
    @Test("the result is an H.264 MP4 that AVFoundation can open")
    func convertsToPlayableMP4() async throws {
        let source = try makeSourceFile()
        let destination = destinationFile()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }

        // The file as it arrives: AVFoundation has no Matroska demuxer, so it
        // cannot even see a track.
        let original = AVURLAsset(url: source)
        let originalTracks = try? await original.loadTracks(withMediaType: .video)
        #expect(
            originalTracks?.isEmpty != false,
            "the fixture is supposed to be unreadable by AVFoundation"
        )

        try await WebMConverter().convert(fileAt: source, to: destination)

        #expect(FileManager.default.fileExists(atPath: destination.path))
        let converted = AVURLAsset(url: destination)
        let tracks = try await converted.loadTracks(withMediaType: .video)
        let track = try #require(tracks.first, "the converted file has no video track")

        let descriptions = try await track.load(.formatDescriptions)
        let codec = try #require(descriptions.first).mediaSubType
        #expect(codec == .h264, "expected H.264, got \(codec)")

        let duration = try await converted.load(.duration).seconds
        #expect(duration > 0.5 && duration < 2, "the clip is a second long, got \(duration)")
    }

    @Test("the audio comes across as well")
    func keepsAudio() async throws {
        let source = try makeSourceFile()
        let destination = destinationFile()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }

        try await WebMConverter().convert(fileAt: source, to: destination)

        let audio = try await AVURLAsset(url: destination).loadTracks(withMediaType: .audio)
        #expect(audio.isEmpty == false, "the Opus track was dropped")
    }

    @Test("progress is reported and ends at the end")
    func reportsProgress() async throws {
        let source = try makeSourceFile()
        let destination = destinationFile()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }

        let reported = Mutex<[Double]>([])
        try await WebMConverter().convert(fileAt: source, to: destination) { fraction in
            reported.withLock { $0.append(fraction) }
        }

        let fractions = reported.withLock { $0 }
        #expect(fractions.isEmpty == false, "nothing was reported")
        #expect(fractions.last == 1, "the last word should be that it finished")
        #expect(fractions.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test("a file that is not a video is refused rather than half written")
    func refusesNonVideo() async throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("webm")
        try Data("not a video".utf8).write(to: source)
        let destination = destinationFile()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }

        await #expect(throws: (any Error).self) {
            try await WebMConverter().convert(fileAt: source, to: destination)
        }
    }

    @Test("the encoded size keeps the shape and stays even")
    func fittedSize() {
        // H.264 wants even dimensions, and NV12's chroma is half size in both
        // directions, so an odd number here is a broken last row.
        #expect(WebMConverter.fitted(width: 1920, height: 1080, longSide: 1920) == (1920, 1080))
        #expect(WebMConverter.fitted(width: 3840, height: 2160, longSide: 1920) == (1920, 1080))
        #expect(WebMConverter.fitted(width: 641, height: 481, longSide: 1920) == (640, 480))
        #expect(WebMConverter.fitted(width: 0, height: 0, longSide: 1920) == (1920, 1920))
    }

    @Test("an odd sample rate moves to one AAC can encode")
    func sampleRates() {
        #expect(WebMConverter.supportedSampleRate(48000) == 48000)
        #expect(WebMConverter.supportedSampleRate(44100) == 44100)
        #expect(WebMConverter.supportedSampleRate(0) == 48000)
        #expect(WebMConverter.supportedSampleRate(47000) == 48000)
    }
}
