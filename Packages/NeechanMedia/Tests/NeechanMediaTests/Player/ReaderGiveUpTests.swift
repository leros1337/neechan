import Foundation
import Synchronization
import Testing
@testable import NeechanMedia

/// Refuses every request, so reads fail the way a dropped connection does.
final class FailingProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static let requestCount = Mutex(0)

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "failing.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount.withLock { $0 += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

/// Giving up on a reader that is no longer wanted.
///
/// The regression: a feed swiping to the next clip left the last one's reads
/// running. Each failed, waited, and tried again, for something over half a
/// minute, and all the while they held connections the clip now on screen was
/// waiting for. Two clips were being fetched at once and neither could make
/// progress.
@Suite("Giving up on a reader", .serialized)
struct ReaderGiveUpTests {
    private func makeIO(shouldStop: @escaping @Sendable () -> Bool) -> RangeReaderIO {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FailingProtocol.self]
        let reader = MediaRangeReader(
            url: URL(string: "https://failing.invalid/clip.webm")!,
            session: URLSession(configuration: configuration)
        )
        let io = RangeReaderIO(reader: reader)
        io.shouldStopReading = shouldStop
        return io
    }

    private func read(_ io: RangeReaderIO) -> (result: Int32, took: TimeInterval) {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        let started = ContinuousClock.now
        let result = buffer.withUnsafeMutableBufferPointer {
            io.read(into: $0.baseAddress!, size: 4_096)
        }
        return (result, (ContinuousClock.now - started).seconds)
    }

    @Test("a reader still wanted keeps trying")
    func stillWantedRetries() {
        let io = makeIO { false }
        defer { io.close() }

        let before = FailingProtocol.requestCount.withLock { $0 }
        let (result, took) = read(io)

        #expect(result < 0, "a failing read reported success")
        // Every attempt, and the waits between them.
        #expect(
            FailingProtocol.requestCount.withLock { $0 } - before >= 2,
            "it gave up after a single attempt"
        )
        #expect(took > 0.2, "it did not wait between attempts, it took \(took)s")
    }

    /// The fix: a reader that has been given up on stops at once. Before this,
    /// it worked through every attempt and every wait first.
    @Test("a reader given up on stops at once")
    func givenUpOnStopsImmediately() {
        let io = makeIO { true }
        defer { io.close() }

        let before = FailingProtocol.requestCount.withLock { $0 }
        let (result, took) = read(io)

        #expect(result < 0)
        #expect(
            FailingProtocol.requestCount.withLock { $0 } == before,
            "it asked the server for something it had been told to stop wanting"
        )
        #expect(took < 0.1, "it took \(took)s to give up on a read nobody wanted")
    }

    @Test("the wait between attempts grows, and is capped")
    func theWaitsGrow() {
        #expect(RangeReaderIO.pause(beforeAttempt: 1) == 0.25)
        #expect(RangeReaderIO.pause(beforeAttempt: 2) == 0.5)
        #expect(RangeReaderIO.pause(beforeAttempt: 3) == 1)
        // Capped, so a long outage does not turn into a longer and longer one.
        #expect(RangeReaderIO.pause(beforeAttempt: 9) == 1)
    }
}
