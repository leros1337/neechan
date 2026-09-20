import CoreMedia
import Foundation
import NeechanTestSupport
import Testing
@testable import NeechanMedia

/// Decoding sound, all the way to something the renderer will take.
@Suite("Audio decoding")
struct AudioDecoderTests {
    private func file(_ fixture: Fixture) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-\(UUID().uuidString).\(fixture.fileExtension)")
        try FixtureLoader.data(fixture).write(to: url)
        return url
    }

    private func decodeEverything(_ fixture: Fixture) throws -> (
        runs: [DecodedAudio], rate: Int32, channels: Int32
    ) {
        let url = try file(fixture)
        defer { try? FileManager.default.removeItem(at: url) }

        let demuxer = try Demuxer(source: .file(url))
        defer { demuxer.close() }
        let stream = try #require(demuxer.audioStream)
        let decoder = try AudioDecoder(stream: stream)
        defer { decoder.close() }

        var runs: [DecodedAudio] = []
        while let packet = demuxer.readPacket() {
            guard packet.streamIndex == stream.pointee.index else { continue }
            try decoder.decode(packet, generation: 0) { runs.append($0) }
        }
        try decoder.decode(nil, generation: 0) { runs.append($0) }
        return (runs, decoder.sampleRate, decoder.channelCount)
    }

    /// Opus, Vorbis, AAC, MP3 and FLAC between them cover every fixture, and
    /// between them cover what a board or a Matroska file actually carries.
    @Test(
        "every audio codec the app meets decodes",
        arguments: [
            Fixture.sampleVP9Profile0, .sampleVP8, .sampleVideo,
            .sampleH264, .sampleHEV1, .sampleMatroska
        ]
    )
    func everyCodecDecodes(fixture: Fixture) throws {
        let (runs, rate, channels) = try decodeEverything(fixture)

        #expect(!runs.isEmpty, "\(fixture.rawValue) produced no sound")
        #expect(rate > 0)
        #expect(channels == 1 || channels == 2)

        // About a second of it, which is how long every fixture runs.
        let total = runs.reduce(0) { $0 + $1.mediaDuration }
        #expect(total > 0.8 && total < 1.3, "\(fixture.rawValue) decoded \(total)s of sound")
    }

    @Test("sound comes back in order and knows when it should be heard")
    func runsAreTimedAndOrdered() throws {
        let (runs, _, _) = try decodeEverything(.sampleVP9Profile0)

        let times = runs.map { TimeMath.seconds($0.presentation) }
        #expect(times == times.sorted(), "sound came back out of order")
        // Opus begins with samples that exist only to prime the decoder and
        // must not be heard. libavcodec trims them, so the first run starts at
        // the beginning rather than before it.
        #expect(times.first.map { $0 >= 0 } == true, "the first run started before zero")
    }

    @Test("what comes out is what the renderer was promised")
    func sampleBuffersAreWellFormed() throws {
        let (runs, rate, channels) = try decodeEverything(.sampleMatroska)
        let first = try #require(runs.first)

        let description = try #require(CMSampleBufferGetFormatDescription(first.sampleBuffer))
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)

        #expect(asbd.mFormatID == kAudioFormatLinearPCM)
        #expect(asbd.mBitsPerChannel == 32)
        #expect(asbd.mSampleRate == Float64(rate))
        #expect(asbd.mChannelsPerFrame == UInt32(channels))
        #expect(CMSampleBufferGetNumSamples(first.sampleBuffer) > 0)
        #expect(CMSampleBufferIsValid(first.sampleBuffer))
    }

    @Test("a decoder can be flushed and used again, which is what a seek does")
    func flushingAndDecodingAgain() throws {
        let url = try file(.sampleVP9Profile0)
        defer { try? FileManager.default.removeItem(at: url) }

        let demuxer = try Demuxer(source: .file(url))
        defer { demuxer.close() }
        let stream = try #require(demuxer.audioStream)
        let decoder = try AudioDecoder(stream: stream)
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
            try decoder.decode(packet, generation: 2) { run in
                after += 1
                #expect(run.generation == 2)
            }
        }
        #expect(after > 0, "nothing decoded after the flush")
    }
}
