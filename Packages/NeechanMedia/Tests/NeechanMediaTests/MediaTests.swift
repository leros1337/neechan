import Foundation
import NeechanTestSupport
import Testing
@testable import NeechanMedia

@Suite("Media kind resolution")
struct MediaKindTests {
    @Test("file names map to a presentation", arguments: [
        ("clip.webm", MediaKind.webmVideo),
        ("clip.mkv", .webmVideo),
        ("clip.mp4", .mp4Video),
        ("clip.m4v", .mp4Video),
        ("pic.gif", .animatedImage),
        ("pic.apng", .animatedImage),
        ("pic.png", .stillImage),
        ("pic.jpg", .stillImage),
        ("pic.webp", .stillImage),
    ])
    func resolvesByExtension(fileName: String, expected: MediaKind) {
        #expect(MediaKind.resolve(fileName: fileName) == expected)
    }

    @Test("the type code is used when the name says nothing")
    func fallsBackToTypeCode() {
        #expect(MediaKind.resolve(fileName: "file", declaredTypeCode: 6) == .webmVideo)
        #expect(MediaKind.resolve(fileName: "file", declaredTypeCode: 10) == .mp4Video)
        #expect(MediaKind.resolve(fileName: "file", declaredTypeCode: 4) == .animatedImage)
    }

    @Test("the extension wins over the type code")
    func extensionWinsOverCode() {
        // 2ch serves WebP under the JPEG code, so trusting the code would show
        // the wrong thing.
        #expect(MediaKind.resolve(fileName: "x.webm", declaredTypeCode: 1) == .webmVideo)
    }

    @Test("only WebM needs the bundled FFmpeg build")
    func onlyWebMNeedsFFmpeg() {
        #expect(MediaKind.webmVideo.requiresFFmpeg)
        // MP4 too: the board serves HEVC tagged `hev1`, which AVFoundation
        // refuses to open, so nothing played and nothing said why.
        #expect(MediaKind.mp4Video.requiresFFmpeg)
        #expect(MediaKind.stillImage.requiresFFmpeg == false)
        #expect(MediaKind.webmVideo.isVideo)
        #expect(MediaKind.mp4Video.isVideo)
        #expect(MediaKind.animatedImage.isVideo == false)
    }
}

@Suite("Media player options")
struct MediaPlayerOptionsTests {
    @Test("headers carry the user agent, referer and cookies")
    func buildsHeaders() {
        let options = MediaPlayerOptions(
            kind: .webmVideo,
            referer: URL(string: "https://2ch.org/"),
            userAgent: "Neechan/1.0",
            cookies: ["passcode_auth": "abc", "ageallow": "1"]
        )
        let headers = options.httpHeaders
        #expect(headers["User-Agent"] == "Neechan/1.0")
        #expect(headers["Referer"] == "https://2ch.org/")
        // Sorted, so the header is stable between runs.
        #expect(headers["Cookie"] == "ageallow=1; passcode_auth=abc")
    }

    @Test("no cookies means no cookie header")
    func omitsEmptyCookieHeader() {
        let options = MediaPlayerOptions(kind: .mp4Video)
        #expect(options.cookieHeader == nil)
        #expect(options.httpHeaders["Cookie"] == nil)
    }

    @Test("WebM asks for software decoding, MP4 does not")
    func decodingRoute() {
        #expect(MediaPlayerOptions(kind: .webmVideo).requiresSoftwareDecoding)
        #expect(MediaPlayerOptions(kind: .mp4Video).requiresSoftwareDecoding)
        #expect(MediaPlayerOptions(kind: .stillImage).requiresSoftwareDecoding == false)
    }

    @Test("a video plays once by default; looping is something the reader turns on")
    func defaults() {
        let options = MediaPlayerOptions(kind: .webmVideo)
        #expect(options.loops == false)
        #expect(options.autoplays)
        #expect(options.startsMuted == false)
    }

    @Test("looping can be asked for")
    func loopingIsOptional() {
        #expect(MediaPlayerOptions(kind: .webmVideo, loops: true).loops)
    }

    @Test("repeating a looping command still reaches the player")
    func loopCommandsAreDistinct() {
        var control = PlaybackControl()
        control.send(.setLooping(true))
        let first = control
        control.send(.setLooping(true))
        #expect(control != first)
    }
}

@Suite("Animated image decoder")
struct AnimatedImageDecoderTests {
    @Test("a still image reads as one frame")
    func stillImage() throws {
        let data = try FixtureLoader.data(.sampleStillPNG)
        let metadata = try AnimatedImageDecoder.metadata(data)

        #expect(metadata.frameCount == 1)
        #expect(metadata.isAnimated == false)
        #expect(metadata.pixelSize == CGSize(width: 4, height: 4))
        #expect(AnimatedImageDecoder.isAnimated(data) == false)
    }

    @Test("an animated GIF reads every frame's delay")
    func animatedGIF() throws {
        let data = try FixtureLoader.data(.sampleAnimatedGIF)
        let metadata = try AnimatedImageDecoder.metadata(data)

        #expect(metadata.frameCount > 1)
        #expect(metadata.isAnimated)
        #expect(metadata.totalDuration > 0)
        #expect(metadata.durations.allSatisfy { $0 >= 0.02 })
        #expect(AnimatedImageDecoder.isAnimated(data))
    }

    @Test("the frame limit caps how much of a file is considered")
    func honoursFrameLimit() throws {
        let data = try FixtureLoader.data(.sampleAnimatedGIF)
        let metadata = try AnimatedImageDecoder.metadata(data, frameLimit: 1)
        #expect(metadata.frameCount == 1)
    }

    @Test("every frame of a real GIF can be produced on demand")
    func framesArrive() async throws {
        let data = try FixtureLoader.data(.sampleAnimatedGIF)
        let decoder = try AnimatedFrameDecoder(data: data)
        let count = await decoder.metadata.frameCount

        for index in 0..<count {
            #expect(await decoder.frame(at: index) != nil, "frame \(index) did not decode")
        }
    }

    @Test("bytes that are not an image are reported, not crashed on")
    func rejectsGarbage() {
        #expect(throws: (any Error).self) {
            _ = try AnimatedImageDecoder.metadata(Data("not an image".utf8))
        }
        #expect(AnimatedImageDecoder.isAnimated(Data("not an image".utf8)) == false)
    }

    @Test("an empty payload is rejected")
    func rejectsEmpty() {
        #expect(throws: (any Error).self) {
            _ = try AnimatedImageDecoder.metadata(Data())
        }
    }
}

@Suite("Playback state")
struct PlaybackStateTests {
    @Test("progress reports a clamped fraction")
    func fraction() {
        #expect(PlaybackProgress(current: 5, total: 10).fraction == 0.5)
        #expect(PlaybackProgress(current: 20, total: 10).fraction == 1)
        #expect(PlaybackProgress(current: -1, total: 10).fraction == 0)
    }

    @Test("a clip with no known duration is not seekable and reports zero")
    func unknownDuration() {
        let progress = PlaybackProgress(current: 3, total: 0)
        #expect(progress.fraction == 0)
        #expect(progress.isSeekable == false)
    }

    @Test("busy states are the ones that should show a spinner")
    func busyStates() {
        #expect(PlaybackState.preparing.isBusy)
        #expect(PlaybackState.buffering.isBusy)
        #expect(PlaybackState.playing.isBusy == false)
        #expect(PlaybackState.playing.isPlaying)
    }

    @Test("repeating a command still registers as a change")
    func repeatedCommandsAreDistinct() {
        var control = PlaybackControl()
        control.send(.pause)
        let first = control
        control.send(.pause)
        #expect(control != first, "a repeated command must still reach the player")
    }
}

@Suite("Media cache")
struct MediaCacheTests {
    private func makeCache(limit: Int = 1024 * 1024) -> (MediaCache, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MediaCacheTests-\(UUID().uuidString)")
        return (MediaCache(directory: directory, byteLimit: limit), directory)
    }

    @Test("a stored file can be read back")
    func storeAndRead() async throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try #require(URL(string: "https://2ch.org/b/src/1/a.webm"))
        let payload = Data(repeating: 0xAB, count: 2048)
        _ = try await cache.store(payload, for: url)

        let file = try #require(await cache.cachedFile(for: url))
        #expect(try Data(contentsOf: file) == payload)
    }

    @Test("a URL that was never stored reports nothing")
    func missReportsNil() async throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try #require(URL(string: "https://2ch.org/b/src/1/missing.jpg"))
        #expect(await cache.cachedFile(for: url) == nil)
    }

    @Test("the file keeps the original extension so players can sniff the type")
    func keepsExtension() async throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try #require(URL(string: "https://2ch.org/b/src/1/clip.webm"))
        let file = try await cache.store(Data([1, 2, 3]), for: url)
        #expect(file.pathExtension == "webm")
    }

    @Test("different URLs never collide")
    func noCollisions() async throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try #require(URL(string: "https://2ch.org/b/src/1/a.jpg"))
        let second = try #require(URL(string: "https://2ch.org/b/src/2/a.jpg"))
        _ = try await cache.store(Data([1]), for: first)
        _ = try await cache.store(Data([2, 2]), for: second)

        #expect(try Data(contentsOf: #require(await cache.cachedFile(for: first))).count == 1)
        #expect(try Data(contentsOf: #require(await cache.cachedFile(for: second))).count == 2)
    }

    @Test("going over the limit evicts until it fits")
    func evictsOverLimit() async throws {
        // Room for roughly two of the three files below.
        let (cache, directory) = makeCache(limit: 2500)
        defer { try? FileManager.default.removeItem(at: directory) }

        for index in 1...3 {
            let url = try #require(URL(string: "https://2ch.org/b/src/\(index)/f.bin"))
            _ = try await cache.store(Data(repeating: UInt8(index), count: 1000), for: url)
            // Distinct modification times, so eviction order is well defined.
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await cache.currentSize() <= 2500)
    }

    @Test("clearing removes everything")
    func removeAll() async throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try #require(URL(string: "https://2ch.org/b/src/1/a.jpg"))
        _ = try await cache.store(Data([1, 2, 3]), for: url)
        await cache.removeAll()

        #expect(await cache.cachedFile(for: url) == nil)
        #expect(await cache.currentSize() == 0)
    }

    @Test("a downloaded file can be moved in rather than copied")
    func adoptsFile() async throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = FileManager.default.temporaryDirectory
            .appending(path: "adopt-\(UUID().uuidString).jpg")
        try Data([9, 9, 9]).write(to: source)

        let url = try #require(URL(string: "https://2ch.org/b/src/1/a.jpg"))
        _ = try await cache.adopt(fileAt: source, for: url)

        #expect(await cache.cachedFile(for: url) != nil)
        #expect(FileManager.default.fileExists(atPath: source.path) == false)
    }
}

@Suite("EXIF reader")
struct EXIFReaderTests {
    @Test("dimensions are read from a plain PNG")
    func readsDimensions() throws {
        let metadata = try #require(EXIFReader.read(try FixtureLoader.data(.sampleStillPNG)))
        #expect(metadata.pixelWidth == 4)
        #expect(metadata.pixelHeight == 4)
    }

    @Test("a file with no camera data reports none, rather than guessing")
    func noCameraData() throws {
        let metadata = try #require(EXIFReader.read(try FixtureLoader.data(.sampleStillPNG)))
        #expect(metadata.cameraMake == nil)
        #expect(metadata.cameraModel == nil)
        #expect(metadata.hasLocation == false)
    }

    @Test("bytes that are not an image yield nothing")
    func rejectsGarbage() {
        #expect(EXIFReader.read(Data("nope".utf8)) == nil)
    }
}

@Suite("Media cache budget")
struct MediaCacheBudgetTests {
    private func makeCache(limit: Int) throws -> (MediaCache, URL) {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        return (MediaCache(directory: directory, byteLimit: limit), directory)
    }

    @Test("lowering the budget evicts down to it straight away")
    func loweringTheBudgetEvicts() async throws {
        let (cache, directory) = try makeCache(limit: 10_000)
        defer { try? FileManager.default.removeItem(at: directory) }

        for index in 0..<5 {
            let url = try #require(URL(string: "https://2ch.org/b/src/1/\(index).bin"))
            _ = try await cache.store(Data(repeating: 0, count: 1_000), for: url)
        }
        #expect(await cache.currentSize() == 5_000)

        await cache.setByteLimit(2_000)
        #expect(await cache.currentByteLimit() == 2_000)
        #expect(await cache.currentSize() <= 2_000)
    }
}

@Suite("Looping")
struct LoopPolicyTests {
    @Test("a clip that ended with looping on starts again")
    func restartsWhenFinished() {
        #expect(LoopPolicy.shouldRestart(state: .finished, isLooping: true))
    }

    @Test("a clip that ended with looping off stays ended")
    func staysEndedWhenNotLooping() {
        #expect(LoopPolicy.shouldRestart(state: .finished, isLooping: false) == false)
    }

    @Test(
        "nothing restarts a clip that has not ended",
        arguments: [
            PlaybackState.idle, .preparing, .buffering, .playing, .paused,
            .failed("no"),
        ]
    )
    func onlyTheEndRestarts(state: PlaybackState) {
        #expect(LoopPolicy.shouldRestart(state: state, isLooping: true) == false)
    }
}
