import Foundation
import Synchronization
import Testing
@testable import NeechanMedia

/// Serves byte ranges from a body held in memory, and counts what was asked for.
final class RangeServingProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static let body = Mutex(Data())
    /// Set false to answer the whole body whatever range was asked for, the way
    /// a server with no range support would.
    nonisolated(unsafe) static let honoursRanges = Mutex(true)
    /// Every `Range` header seen, so a test can show a read was not a download.
    nonisolated(unsafe) static let requestedRanges = Mutex([String]())

    static func reset(body: Data, honoursRanges: Bool = true) {
        Self.body.withLock { $0 = body }
        Self.honoursRanges.withLock { $0 = honoursRanges }
        requestedRanges.withLock { $0 = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.body.withLock { $0 }
        let honours = Self.honoursRanges.withLock { $0 }
        let header = request.value(forHTTPHeaderField: "Range")
        if let header { Self.requestedRanges.withLock { $0.append(header) } }

        var status = 200
        var slice = body
        var headers = ["Content-Type": "video/webm"]

        if honours, let header, let range = Self.parse(header, count: body.count) {
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

    /// `bytes=start-end`, clamped to what there is.
    private static func parse(_ header: String, count: Int) -> Range<Int>? {
        guard header.hasPrefix("bytes=") else { return nil }
        let parts = header.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        guard let start = Int(parts.first ?? ""), start < count else { return nil }
        let end = parts.count > 1 ? Int(parts[1]) ?? count - 1 : count - 1
        return start..<min(count, end + 1)
    }
}

/// Takes every request and answers none of them, the way a saturated
/// connection does from the caller's side.
final class HangingProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "hanging.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

@Suite("Ranged media reads", .serialized)
struct MediaRangeReaderTests {
    private func makeReader(
        body: Data,
        honoursRanges: Bool = true,
        blockSize: Int = 64 << 10,
        store: MediaBlockStore? = nil,
        url: URL = URL(string: "https://example.invalid/clip.webm")!,
        serving: Bool = true
    ) -> MediaRangeReader {
        if serving { RangeServingProtocol.reset(body: body, honoursRanges: honoursRanges) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeServingProtocol.self]
        return MediaRangeReader(
            url: url,
            headers: ["Referer": "https://example.invalid/"],
            session: URLSession(configuration: configuration),
            store: store,
            blockSize: blockSize
        )
    }

    /// A block store of its own, so one test's pieces are not another's.
    private func makeStore(blockSize: Int = 64 << 10) -> (MediaBlockStore, URL) {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        return (MediaBlockStore(directory: directory, blockSize: blockSize), directory)
    }

    private func requestsSoFar() -> [String] {
        RangeServingProtocol.requestedRanges.withLock { $0 }
    }

    private func forgetRequests() {
        RangeServingProtocol.requestedRanges.withLock { $0 = [] }
    }

    private func body(_ count: Int) -> Data {
        Data((0..<count).map { UInt8($0 % 251) })
    }

    private func read(_ reader: MediaRangeReader, at offset: Int64, count: Int) -> (Int, Data) {
        var buffer = [UInt8](repeating: 0, count: count)
        let copied = buffer.withUnsafeMutableBufferPointer {
            reader.read(into: $0.baseAddress!, at: offset, count: count)
        }
        return (copied, Data(buffer.prefix(max(0, copied))))
    }

    @Test("the size is learned from the server without fetching the file")
    func lengthIsAsked() {
        let reader = makeReader(body: body(500_000))

        #expect(reader.length() == 500_000)
    }

    /// Opening a clip asks its size and then reads its first bytes. Those
    /// used to be two requests, one of them for a single byte, and on a
    /// connection already carrying other clips' pieces each request queued
    /// for seconds behind them. One request answers both.
    @Test("the size comes with the first block, not with a request of its own")
    func lengthComesWithTheFirstBlock() {
        let reader = makeReader(body: body(500_000), blockSize: 64 << 10)

        #expect(reader.length() == 500_000)
        let (copied, _) = read(reader, at: 0, count: 4096)

        #expect(copied == 4096)
        #expect(requestsSoFar() == ["bytes=0-65535"], "asked for \(requestsSoFar())")
    }

    /// A player swiped away from while its clip was still opening had no way
    /// to be stopped: the reader was waiting on the network, and nothing had a
    /// handle on it until the file opened. Its request went on holding a
    /// connection that the clip now on screen was waiting for.
    @Test("a reader given up on answers at once, without waiting on the network")
    func givingUpAnswersAtOnce() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingProtocol.self]
        let reader = MediaRangeReader(
            url: URL(string: "https://hanging.invalid/clip.webm")!,
            headers: [:],
            session: URLSession(configuration: configuration),
            store: nil,
            blockSize: 64 << 10
        )

        let outcome = Mutex<Int?>(nil)
        let thread = Thread {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let copied = buffer.withUnsafeMutableBufferPointer {
                reader.read(into: $0.baseAddress!, at: 0, count: 4096)
            }
            outcome.withLock { $0 = copied }
        }
        thread.start()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(outcome.withLock { $0 } == nil, "the read should still be waiting")

        let started = ContinuousClock.now
        reader.giveUp()
        while outcome.withLock({ $0 }) == nil, ContinuousClock.now - started < .seconds(2) {
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(outcome.withLock { $0 } == -1, "the read should have failed, not waited")
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(reader.length() == nil, "nothing more is asked of the network")
        #expect(reader.wasGivenUp)
    }

    @Test("a read returns the bytes that are actually at that offset")
    func readsAreCorrect() {
        let source = body(300_000)
        let reader = makeReader(body: source)

        let (copied, data) = read(reader, at: 1000, count: 256)

        #expect(copied == 256)
        #expect(data == source.subdata(in: 1000..<1256))
    }

    /// The point of the whole thing: playing a clip must not mean fetching it.
    @Test("reading the start of a large file fetches only the start")
    func readingTheStartIsNotADownload() {
        let reader = makeReader(body: body(8 << 20), blockSize: 64 << 10)

        _ = read(reader, at: 0, count: 4096)

        let asked = RangeServingProtocol.requestedRanges.withLock { $0 }
        #expect(asked == ["bytes=0-65535"], "asked for \(asked)")
    }

    @Test("consecutive reads inside one piece cost no further requests")
    func windowIsReused() {
        let reader = makeReader(body: body(1 << 20), blockSize: 64 << 10)

        _ = read(reader, at: 0, count: 1024)
        _ = read(reader, at: 1024, count: 1024)
        _ = read(reader, at: 2048, count: 1024)

        #expect(RangeServingProtocol.requestedRanges.withLock { $0.count } == 1)
    }

    /// Scrubbing an hour-long clip has to reach the middle without the rest.
    @Test("a read far away fetches from there, not from the beginning")
    func seekingReadsFromTheOffset() {
        let source = body(4 << 20)
        let reader = makeReader(body: source, blockSize: 64 << 10)
        _ = read(reader, at: 0, count: 1024)

        let (copied, data) = read(reader, at: 3 << 20, count: 512)

        #expect(copied == 512)
        #expect(data == source.subdata(in: (3 << 20)..<((3 << 20) + 512)))
        let asked = RangeServingProtocol.requestedRanges.withLock { $0 }
        #expect(asked.last == "bytes=3145728-3211263", "asked for \(asked)")
    }

    @Test("reading past the end reports the end rather than an error")
    func endOfFile() {
        let reader = makeReader(body: body(10_000))
        _ = reader.length()

        let (copied, _) = read(reader, at: 10_000, count: 256)

        #expect(copied == 0)
    }

    @Test("a read is clipped to what is left at the end of the file")
    func partialTail() {
        let reader = makeReader(body: body(10_000))

        let (copied, _) = read(reader, at: 9_900, count: 4096)

        #expect(copied == 100)
    }

    @Test("a server that ignores ranges still reads correctly")
    func withoutRangeSupport() {
        let source = body(20_000)
        let reader = makeReader(body: source, honoursRanges: false)

        let (copied, data) = read(reader, at: 0, count: 256)

        #expect(copied == 256)
        #expect(data == source.subdata(in: 0..<256))
        #expect(reader.length() == 20_000)
    }

    @Test("a total is read out of a ranged answer")
    func totalFromContentRange() throws {
        let response = try #require(
            HTTPURLResponse(
                url: URL(string: "https://example.invalid/a")!,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Range": "bytes 0-1023/60768236"]
            )
        )
        #expect(MediaRangeReader.totalLength(of: response) == 60_768_236)
    }

    @Test("an unknown total is reported as unknown")
    func unknownTotal() throws {
        let response = try #require(
            HTTPURLResponse(
                url: URL(string: "https://example.invalid/a")!,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Range": "bytes 0-1023/*"]
            )
        )
        #expect(MediaRangeReader.totalLength(of: response) == nil)
    }

    // MARK: Keeping what was fetched

    /// Fetches land on block boundaries, so what is kept lines up with what can
    /// be served back.
    @Test("a read part way into a block still fetches the whole block")
    func fetchesAreAligned() {
        let reader = makeReader(body: body(4 << 20))

        _ = read(reader, at: 1000, count: 256)

        #expect(requestsSoFar() == ["bytes=0-65535"], "asked for \(requestsSoFar())")
    }

    /// Scrubbing backwards over ground already watched used to pay for it twice.
    @Test("seeking back over what was already read costs nothing")
    func backwardSeekIsFree() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = makeReader(body: body(4 << 20), store: store)

        _ = read(reader, at: 0, count: 256)
        _ = read(reader, at: 2 << 20, count: 256)
        forgetRequests()
        _ = read(reader, at: 0, count: 256)

        #expect(requestsSoFar().isEmpty, "went back to the server for \(requestsSoFar())")
    }

    /// The promise across sessions: reopening a clip reads it off the disk.
    @Test("a second reader over the same store asks the server for nothing")
    func aSecondReaderReadsFromDisk() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = URL(string: "https://example.invalid/again.webm")!
        let source = body(4 << 20)

        let first = makeReader(body: source, store: store, url: clip)
        _ = read(first, at: 0, count: 4096)
        forgetRequests()

        let second = makeReader(body: source, store: store, url: clip, serving: false)
        let (copied, data) = read(second, at: 0, count: 4096)

        #expect(requestsSoFar().isEmpty, "went back to the server for \(requestsSoFar())")
        #expect(copied == 4096)
        #expect(data == source.subdata(in: 0..<4096))
        #expect(second.length() == Int64(source.count), "the size has to survive too")
    }

    @Test("the short last block is kept and served like any other")
    func lastBlockIsKept() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Two whole blocks and a short one.
        let source = body((64 << 10) * 2 + 1234)
        let clip = URL(string: "https://example.invalid/tail.webm")!
        let tailStart = Int64((64 << 10) * 2)

        let first = makeReader(body: source, store: store, url: clip)
        _ = read(first, at: tailStart, count: 1234)
        forgetRequests()

        let second = makeReader(body: source, store: store, url: clip, serving: false)
        let (copied, data) = read(second, at: tailStart, count: 1234)

        #expect(requestsSoFar().isEmpty, "went back to the server for \(requestsSoFar())")
        #expect(copied == 1234)
        #expect(data == source.subdata(in: Int(tailStart)..<source.count))
    }

    /// A server that answers a ranged request with the whole file starts at the
    /// beginning, whatever was asked for. Labelling that answer with the offset
    /// wanted served the wrong bytes from then on.
    @Test("a server that ignores ranges still reads correctly away from the start")
    func withoutRangeSupportAtAnOffset() {
        let source = body(20_000)
        let reader = makeReader(body: source, honoursRanges: false)

        let (copied, data) = read(reader, at: 15_000, count: 256)

        #expect(copied == 256)
        #expect(data == source.subdata(in: 15_000..<15_256))
    }

    /// A whole-file answer is only a block when the file fits in one. For
    /// anything larger it is not a block at all, and writing it down as one
    /// would have it read back later as though the file ended there.
    @Test("a whole-file answer larger than a block is not kept as one")
    func rangeIgnoringServerIsNotCached() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = URL(string: "https://example.invalid/whole.webm")!
        let reader = makeReader(
            body: body(4 << 20), honoursRanges: false, store: store, url: clip
        )

        _ = read(reader, at: 0, count: 256)

        #expect(store.sizeOnDisk() == 0)
    }

    @Test("a file smaller than one block is kept whole")
    func smallFileIsKept() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = URL(string: "https://example.invalid/small.webm")!
        let source = body(20_000)

        let first = makeReader(body: source, store: store, url: clip)
        _ = read(first, at: 0, count: 256)
        forgetRequests()

        let second = makeReader(body: source, store: store, url: clip, serving: false)
        let (copied, data) = read(second, at: 0, count: 256)

        #expect(requestsSoFar().isEmpty)
        #expect(copied == 256)
        #expect(data == source.subdata(in: 0..<256))
    }
}
