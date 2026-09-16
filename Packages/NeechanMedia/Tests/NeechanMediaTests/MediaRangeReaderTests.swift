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

@Suite("Ranged media reads", .serialized)
struct MediaRangeReaderTests {
    private func makeReader(body: Data, honoursRanges: Bool = true, chunkSize: Int = 64 << 10)
        -> MediaRangeReader
    {
        RangeServingProtocol.reset(body: body, honoursRanges: honoursRanges)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeServingProtocol.self]
        return MediaRangeReader(
            url: URL(string: "https://example.invalid/clip.webm")!,
            headers: ["Referer": "https://example.invalid/"],
            session: URLSession(configuration: configuration),
            chunkSize: chunkSize
        )
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
        let reader = makeReader(body: body(8 << 20), chunkSize: 64 << 10)

        _ = read(reader, at: 0, count: 4096)

        let asked = RangeServingProtocol.requestedRanges.withLock { $0 }
        #expect(asked == ["bytes=0-65535"], "asked for \(asked)")
    }

    @Test("consecutive reads inside one piece cost no further requests")
    func windowIsReused() {
        let reader = makeReader(body: body(1 << 20), chunkSize: 64 << 10)

        _ = read(reader, at: 0, count: 1024)
        _ = read(reader, at: 1024, count: 1024)
        _ = read(reader, at: 2048, count: 1024)

        #expect(RangeServingProtocol.requestedRanges.withLock { $0.count } == 1)
    }

    /// Scrubbing an hour-long clip has to reach the middle without the rest.
    @Test("a read far away fetches from there, not from the beginning")
    func seekingReadsFromTheOffset() {
        let source = body(4 << 20)
        let reader = makeReader(body: source, chunkSize: 64 << 10)
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
}
