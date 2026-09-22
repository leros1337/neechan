import CoreMedia
import CoreVideo
import Foundation
import Libavcodec
import NeechanTestSupport
import Testing
@testable import NeechanMedia

/// Decoding, all the way to a picture.
///
/// The unit tests above this one check which path a file should take. These
/// check that the path works: a decoder that is asked for hardware it does not
/// have produces nothing at all, silently, and no amount of testing the rule
/// would catch it.
@Suite("Video decoding")
struct VideoDecoderTests {
    private func file(_ fixture: Fixture) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("decode-\(UUID().uuidString).\(fixture.fileExtension)")
        try FixtureLoader.data(fixture).write(to: url)
        return url
    }

    /// Decodes a whole file and hands back every picture it produced.
    private func decodeEverything(
        _ fixture: Fixture, capabilities: VideoDecoderCapabilities = .current
    ) throws -> (frames: [DecodedFrame], usedHardware: Bool) {
        let url = try file(fixture)
        defer { try? FileManager.default.removeItem(at: url) }

        let demuxer = try Demuxer(source: .file(url))
        defer { demuxer.close() }
        let stream = try #require(demuxer.videoStream)
        let decoder = try VideoDecoder(stream: stream, capabilities: capabilities)
        defer { decoder.close() }

        var frames: [DecodedFrame] = []
        while let packet = demuxer.readPacket() {
            guard packet.streamIndex == stream.pointee.index else { continue }
            try decoder.decode(packet, generation: 0) { frames.append($0) }
        }
        // A reordered stream keeps its last frames until it is drained.
        try decoder.decode(nil, generation: 0) { frames.append($0) }
        return (frames, decoder.isDecodingInHardware)
    }

    @Test(
        "every codec the app meets decodes to a picture",
        arguments: [
            (Fixture.sampleVP9Profile0, 64),
            (.sampleVP8, 64),
            (.sampleVideo, 320),
            (.sampleH264, 64),
            (.sampleHEV1, 64),
            (.sampleMatroska, 64)
        ]
    )
    func everyCodecDecodes(fixture: Fixture, width: Int) throws {
        let (frames, _) = try decodeEverything(fixture)

        #expect(frames.count == 15, "\(fixture.rawValue) produced \(frames.count) frames")
        let first = try #require(frames.first)
        #expect(CVPixelBufferGetWidth(first.pixelBuffer) == width)
        #expect(first.presentation.isValid, "the first frame had no timestamp")
    }

    /// The whole point of letting FFmpeg drive VideoToolbox: an MP4 with
    /// B-frames arrives out of display order and has to come back in order.
    @Test("frames come out in the order they are shown, not the order they arrive")
    func framesAreInPresentationOrder() throws {
        let (frames, _) = try decodeEverything(.sampleH264)

        let times = frames.map { TimeMath.seconds($0.presentation) }
        #expect(times == times.sorted(), "frames came back out of order: \(times)")
        #expect(Set(times).count == times.count, "two frames claimed the same time")
    }

    /// `hev1` carries its parameter sets in the stream rather than in the
    /// container, which is exactly what AVFoundation refuses to open. FFmpeg
    /// finds them, and this is the proof.
    @Test("HEVC with its parameter sets carried in-band decodes")
    func hev1Decodes() throws {
        let (frames, _) = try decodeEverything(.sampleHEV1)
        #expect(frames.count == 15)
        #expect(CVPixelBufferGetWidth(frames[0].pixelBuffer) == 64)
    }

    /// Whether this machine takes the hardware path is not something a test
    /// can decide, so it asserts the rule instead: hardware was used if and
    /// only if it was asked for and the picture came back.
    @Test("hardware is used when the rule says it should be")
    func hardwareIsUsedWhenAskedFor() throws {
        let (frames, usedHardware) = try decodeEverything(.sampleH264)
        #expect(!frames.isEmpty)
        // H.264 always qualifies, and every machine the tests run on decodes it.
        #expect(usedHardware, "H.264 was decoded on the CPU")

        // VP9 depends on the machine, so the assertion follows the probe. On a
        // recent iPhone or an Apple silicon Mac this is the path that matters;
        // on the simulator there is no decoder and the claim is the opposite.
        let (vp9Frames, vp9Hardware) = try decodeEverything(.sampleVP9Profile0)
        #expect(vp9Frames.count == 15)
        #expect(
            vp9Hardware == VideoDecoderCapabilities.current.hasVP9Hardware,
            "VP9 hardware decoding did not follow what the device reported"
        )
    }

    @Test("a decoder refused the hardware path still produces the same pictures")
    func softwareProducesTheSameFrames() throws {
        let noHardware = VideoDecoderCapabilities(hasVP9Hardware: false, hasAV1Hardware: false)
        let (soft, usedHardware) = try decodeEverything(.sampleVP9Profile0, capabilities: noHardware)

        #expect(!usedHardware)
        #expect(soft.count == 15)
        #expect(CVPixelBufferGetWidth(soft[0].pixelBuffer) == 64)
        // Software frames are converted to the same two-plane layout the
        // hardware hands back, so nothing downstream can tell them apart.
        #expect(CVPixelBufferGetPlaneCount(soft[0].pixelBuffer) == 2)
    }

    /// VP9 profile 1 is 4:4:4, which no Apple decoder takes. Asking for
    /// hardware anyway must still produce pictures, because FFmpeg withdraws
    /// the offer and decodes on the CPU instead.
    @Test("a profile VideoToolbox cannot take still decodes when hardware is asked for")
    func unsupportedProfileFallsBack() throws {
        let withHardware = VideoDecoderCapabilities(hasVP9Hardware: true, hasAV1Hardware: true)
        let (frames, _) = try decodeEverything(.sampleVideo, capabilities: withHardware)
        #expect(frames.count == 15, "the fallback produced \(frames.count) frames")
    }

    @Test("a decoder can be flushed and used again, which is what a seek does")
    func flushingAndDecodingAgain() throws {
        let url = try file(.sampleVP9Profile0)
        defer { try? FileManager.default.removeItem(at: url) }

        let demuxer = try Demuxer(source: .file(url))
        defer { demuxer.close() }
        let stream = try #require(demuxer.videoStream)
        let decoder = try VideoDecoder(stream: stream)
        defer { decoder.close() }

        var before = 0
        while let packet = demuxer.readPacket() {
            guard packet.streamIndex == stream.pointee.index else { continue }
            try decoder.decode(packet, generation: 0) { _ in before += 1 }
        }
        #expect(before > 0)

        decoder.flush()
        #expect(demuxer.seek(to: 0))

        var after = 0
        while let packet = demuxer.readPacket() {
            guard packet.streamIndex == stream.pointee.index else { continue }
            try decoder.decode(packet, generation: 1) { frame in
                after += 1
                #expect(frame.generation == 1, "a frame carried the wrong generation")
            }
        }
        #expect(after > 0, "nothing decoded after the flush")
    }
}
