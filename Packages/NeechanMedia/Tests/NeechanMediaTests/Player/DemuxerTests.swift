import CoreGraphics
import Foundation
import Libavcodec
import Synchronization
import Libavutil
import NeechanTestSupport
import Testing
@testable import NeechanMedia

/// Serves one fixture's bytes, honouring ranges.
///
/// Its own rather than the one the range reader's tests use: that one keeps
/// the body it serves in shared mutable state, so two suites running at once
/// hand each other the wrong file. This one is loaded once and never changes.
final class FixtureServingProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static let body: Data =
        (try? FixtureLoader.data(.sampleVP9Profile0)) ?? Data()
    nonisolated(unsafe) static let requestCount = Mutex(0)

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "fixtures.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount.withLock { $0 += 1 }
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

/// Opening a file and getting its packets out.
///
/// The demuxer is the first thing a clip meets, and the two ways in are worth
/// covering separately: a file already in the media cache, and one still
/// arriving over the network through the app's own reader.
@Suite("Demuxing")
struct DemuxerTests {
    private func file(_ fixture: Fixture) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("demux-\(UUID().uuidString).\(fixture.fileExtension)")
        try FixtureLoader.data(fixture).write(to: url)
        return url
    }

    @Test(
        "every container the app opens gives up its streams",
        arguments: [
            (Fixture.sampleVP9Profile0, CGSize(width: 64, height: 64)),
            (.sampleVP8, CGSize(width: 64, height: 64)),
            (.sampleVideo, CGSize(width: 320, height: 240)),
            (.sampleH264, CGSize(width: 64, height: 64)),
            (.sampleHEV1, CGSize(width: 64, height: 64)),
            (.sampleMatroska, CGSize(width: 64, height: 64))
        ]
    )
    func everyContainerOpens(fixture: Fixture, size: CGSize) throws {
        let url = try file(fixture)
        defer { try? FileManager.default.removeItem(at: url) }

        let demuxer = try Demuxer(source: .file(url))
        defer { demuxer.close() }

        #expect(demuxer.videoStream != nil, "\(fixture.rawValue) has no video stream")
        #expect(demuxer.audioStream != nil, "\(fixture.rawValue) has no audio stream")
        #expect(demuxer.naturalSize == size, "\(fixture.rawValue) is \(demuxer.naturalSize)")
        // Every fixture is a second long, give or take the last frame.
        #expect(demuxer.duration > 0.9 && demuxer.duration < 1.2, "duration was \(demuxer.duration)")
        #expect(demuxer.rotationDegrees == 0)
    }

    @Test("the codec and profile a stream holds are readable, which is what decides hardware")
    func streamsDescribeThemselves() throws {
        let vp9 = try file(.sampleVP9Profile0)
        defer { try? FileManager.default.removeItem(at: vp9) }
        let demuxer = try Demuxer(source: .file(vp9))
        defer { demuxer.close() }

        let parameters = try #require(demuxer.videoStream?.pointee.codecpar)
        #expect(parameters.pointee.codec_id == AV_CODEC_ID_VP9)
        // Profile 0 is the one VideoToolbox will take.
        #expect(parameters.pointee.profile == 0)
    }

    /// The `.mkv` case: the same container as WebM holding codecs WebM never
    /// does, which is the whole reason it is worth covering separately.
    @Test("a Matroska file reports what is actually in it, not what a WebM would hold")
    func matroskaReportsItsOwnCodecs() throws {
        let url = try file(.sampleMatroska)
        defer { try? FileManager.default.removeItem(at: url) }
        let demuxer = try Demuxer(source: .file(url))
        defer { demuxer.close() }

        #expect(demuxer.videoStream?.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_H264)
        #expect(demuxer.audioStream?.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_FLAC)
    }

    @Test("packets come out until the file runs out")
    func packetsRunOut() throws {
        let url = try file(.sampleVP9Profile0)
        defer { try? FileManager.default.removeItem(at: url) }
        let demuxer = try Demuxer(source: .file(url))
        defer { demuxer.close() }

        var videoPackets = 0
        var audioPackets = 0
        while let packet = demuxer.readPacket() {
            if packet.streamIndex == demuxer.videoStream?.pointee.index {
                videoPackets += 1
            } else {
                audioPackets += 1
            }
            #expect(packet.byteCount > 0)
        }
        // Fifteen frames a second for a second.
        #expect(videoPackets == 15, "got \(videoPackets) video packets")
        #expect(audioPackets > 0)
        // And it keeps saying the file is over rather than starting again.
        #expect(demuxer.readPacket() == nil)
    }

    @Test("seeking goes back to the beginning and reads again")
    func seekingRewinds() throws {
        let url = try file(.sampleVP9Profile0)
        defer { try? FileManager.default.removeItem(at: url) }
        let demuxer = try Demuxer(source: .file(url))
        defer { demuxer.close() }

        while demuxer.readPacket() != nil {}
        #expect(demuxer.seek(to: 0))
        #expect(demuxer.readPacket() != nil, "nothing came back after seeking to the start")
    }

    /// The first picture packet after a seek, in milliseconds, and whether it
    /// is a keyframe.
    private func firstPicture(after demuxer: Demuxer) throws -> (pts: Int64, isKeyframe: Bool) {
        let index = try #require(demuxer.videoStream?.pointee.index)
        while let packet = demuxer.readPacket() {
            guard packet.streamIndex == index else { continue }
            return (packet.packet.pointee.pts, packet.packet.pointee.flags & Int32(AV_PKT_FLAG_KEY) != 0)
        }
        Issue.record("no picture came back after the seek")
        return (-1, false)
    }

    /// A file whose index calls every frame a keyframe. Believing it landed a
    /// seek on a frame that cannot be decoded on its own, and the decoder then
    /// refused every frame until the next real keyframe: the clip failed, or
    /// showed a picture seconds away from the sound.
    @Test(
        "a seek lands on a real keyframe, whatever the file's index says",
        arguments: [0.5, 2, 2.96, 3.5]
    )
    func seekLandsOnAKeyframe(target: TimeInterval) throws {
        let url = try file(.sampleMisindexed)
        defer { try? FileManager.default.removeItem(at: url) }
        let demuxer = try Demuxer(source: .file(url))
        defer { demuxer.close() }

        #expect(demuxer.seek(to: target))
        let landed = try firstPicture(after: demuxer)
        #expect(landed.isKeyframe, "landed on a frame at \(landed.pts) ms that is not a keyframe")
        #expect(landed.pts <= Int64(target * 1000), "landed past the target, at \(landed.pts) ms")
    }

    /// Playing reads well ahead, so most keyframes have gone past by the time
    /// anyone seeks. Going back to the start instead would decode the whole
    /// clip up to the target before showing anything.
    @Test("a keyframe already read is gone back to rather than the start")
    func seekUsesAKeyframeAlreadyRead() throws {
        let url = try file(.sampleMisindexed)
        defer { try? FileManager.default.removeItem(at: url) }
        let demuxer = try Demuxer(source: .file(url))
        defer { demuxer.close() }

        while demuxer.readPacket() != nil {}
        #expect(demuxer.seek(to: 3.5))
        let landed = try firstPicture(after: demuxer)
        #expect(landed.isKeyframe)
        #expect(landed.pts == 3000, "landed at \(landed.pts) ms rather than on the keyframe at 3 s")
    }

    @Test("nothing read while finding a keyframe is lost")
    func seekKeepsWhatItRead() throws {
        let url = try file(.sampleMisindexed)
        defer { try? FileManager.default.removeItem(at: url) }

        func packets(afterSeekingTo target: TimeInterval) throws -> [Int64] {
            let demuxer = try Demuxer(source: .file(url))
            defer { demuxer.close() }
            #expect(demuxer.seek(to: target))
            var times: [Int64] = []
            while let packet = demuxer.readPacket() { times.append(packet.packet.pointee.pts) }
            return times
        }

        // A seek sent back to the start, after reading ahead to see where it
        // had landed, gives out the same packets as a seek to the start.
        let sentBack = try packets(afterSeekingTo: 2)
        let fromTheStart = try packets(afterSeekingTo: 0)
        #expect(sentBack == fromTheStart)
    }

    /// The path a clip from a board actually takes: bytes fetched by the app,
    /// with its cookies and Apple's TLS, and handed to the demuxer piecemeal.
    @Test("a file still arriving over the network opens the same way")
    func remoteFilesOpen() throws {
        let before = FixtureServingProtocol.requestCount.withLock { $0 }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureServingProtocol.self]
        let reader = MediaRangeReader(
            url: URL(string: "https://fixtures.invalid/clip.webm")!,
            session: URLSession(configuration: configuration),
            blockSize: 4 << 10
        )

        let demuxer = try Demuxer(source: .remote(reader))
        defer { demuxer.close() }

        #expect(demuxer.videoStream != nil)
        #expect(demuxer.naturalSize == CGSize(width: 64, height: 64))

        var packets = 0
        while demuxer.readPacket() != nil { packets += 1 }
        #expect(packets > 15, "only \(packets) packets came back over the network")

        // Read in pieces rather than downloaded whole, which is what lets a
        // clip start playing before it has finished arriving.
        let requests = FixtureServingProtocol.requestCount.withLock { $0 } - before
        #expect(requests > 1, "the whole file was fetched in one go")
    }

    @Test("a file that is not media at all fails rather than hanging")
    func nonsenseFails() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("demux-\(UUID().uuidString).webm")
        try Data(repeating: 0x41, count: 4_096).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: Demuxer.Failure.self) {
            _ = try Demuxer(source: .file(url))
        }
    }

    /// Tearing a player down must not wait for a server that has stopped
    /// answering, so a cancelled demuxer stops reading.
    @Test("a cancelled demuxer stops giving out packets")
    func cancellingStopsReads() throws {
        let url = try file(.sampleVP9Profile0)
        defer { try? FileManager.default.removeItem(at: url) }
        let demuxer = try Demuxer(source: .file(url))
        defer { demuxer.close() }

        #expect(demuxer.readPacket() != nil)
        demuxer.cancel()
        #expect(demuxer.readPacket() == nil, "a cancelled demuxer carried on reading")
    }
}
