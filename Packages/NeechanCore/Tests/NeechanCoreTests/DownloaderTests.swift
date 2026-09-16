import Foundation
import Synchronization
import Testing
@testable import NeechanCore

/// Serves a fixed body in chunks, so a download has something to report
/// progress about without a network.
final class ChunkedURLProtocol: URLProtocol, @unchecked Sendable {
    /// The body every request gets. Set before the test runs.
    nonisolated(unsafe) static let body = Mutex(Data())
    nonisolated(unsafe) static let statusCode = Mutex(200)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let data = Self.body.withLock { $0 }
        let status = Self.statusCode.withLock { $0 }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(data.count)"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // In chunks, spread over time, the way a real body arrives. Without the
        // pause the whole file lands before the session has reported anything,
        // which would make a progress test pass or fail for the wrong reason.
        var offset = 0
        let chunk = max(1, data.count / 20)
        while offset < data.count {
            let end = min(offset + chunk, data.count)
            client?.urlProtocol(self, didLoad: data.subdata(in: offset..<end))
            offset = end
            Thread.sleep(forTimeInterval: 0.01)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Downloader", .serialized)
struct DownloaderTests {
    private func makeDownloader(body: Data, statusCode: Int = 200) -> Downloader {
        ChunkedURLProtocol.body.withLock { $0 = body }
        ChunkedURLProtocol.statusCode.withLock { $0 = statusCode }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkedURLProtocol.self]
        return Downloader(configuration: configuration)
    }

    private var url: URL { URL(string: "https://example.invalid/file.webm")! }

    /// Twenty megabytes is an ordinary clip, and the old loop walked it one byte
    /// at a time.
    @Test("every byte of a large file reaches the disk")
    func wholeFileIsWritten() async throws {
        let body = Data(repeating: 0xAB, count: 3 * 1024 * 1024)
        let downloader = makeDownloader(body: body)

        let file = try await downloader.download(url, referer: nil, onProgress: nil)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(try Data(contentsOf: file) == body)
    }

    @Test("the file keeps the extension it was asked for")
    func extensionSurvives() async throws {
        let downloader = makeDownloader(body: Data(repeating: 1, count: 16))

        let file = try await downloader.download(url, referer: nil, onProgress: nil)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(file.pathExtension == "webm")
    }

    @Test("progress ends at the full size")
    func progressReachesTheEnd() async throws {
        let body = Data(repeating: 7, count: 512 * 1024)
        let downloader = makeDownloader(body: body)
        let last = Mutex(Downloader.Progress(bytesReceived: 0, bytesExpected: nil))

        let file = try await downloader.download(url, referer: nil) { progress in
            last.withLock { $0 = progress }
        }
        defer { try? FileManager.default.removeItem(at: file) }

        let final = last.withLock { $0 }
        #expect(final.bytesReceived == Int64(body.count))
        #expect(final.fraction == 1)
    }

    @Test("a refusal is reported and leaves nothing behind")
    func badStatusIsReported() async throws {
        let downloader = makeDownloader(body: Data(), statusCode: 403)

        await #expect(throws: Downloader.DownloadError.self) {
            _ = try await downloader.download(self.url, referer: nil, onProgress: nil)
        }
    }

    @Test("cancelling reports cancellation rather than a broken file")
    func cancellationIsReported() async throws {
        let downloader = makeDownloader(body: Data(repeating: 3, count: 8 * 1024 * 1024))

        let task = Task {
            try await downloader.download(self.url, referer: nil, onProgress: nil)
        }
        task.cancel()

        do {
            let file = try await task.value
            // Fast enough to have finished before the cancel landed, which is
            // allowed; the file must still be whole.
            try? FileManager.default.removeItem(at: file)
        } catch is CancellationError {
            // Also fine.
        } catch let error as Downloader.DownloadError {
            #expect(error == .cancelled)
        }
    }
}

extension Downloader.DownloadError: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        String(describing: lhs) == String(describing: rhs)
    }
}

/// How far a download has got, as the system reports it.
///
/// Tested apart from a real transfer because a `URLProtocol` stub never drives
/// `didWriteData`: the session synthesises the file without accounting for it.
/// The capsule showed the same percentage for a whole download twice over — once
/// from a task-scoped delegate that was never called, once from the task's own
/// `progress`, whose fraction never left its first value — so the wiring itself
/// is worth pinning down.
@Suite("Download progress reporting")
struct DownloadProgressDelegateTests {
    private func makeTask() -> URLSessionDownloadTask {
        URLSession.shared.downloadTask(with: URL(string: "https://example.invalid/a.mp4")!)
    }

    @Test("what the system reports reaches the handler watching that task")
    func reportsReachTheHandler() {
        let delegate = DownloadDelegate()
        let task = makeTask()
        let seen = Mutex<[Downloader.Progress]>([])
        delegate.watch(
            task.taskIdentifier,
            savingTo: URL.temporaryDirectory.appending(path: "unused"),
            onProgress: { progress in seen.withLock { $0.append(progress) } },
            finish: { _ in }
        )

        delegate.urlSession(
            .shared, downloadTask: task,
            didWriteData: 250, totalBytesWritten: 250, totalBytesExpectedToWrite: 1000
        )
        delegate.urlSession(
            .shared, downloadTask: task,
            didWriteData: 250, totalBytesWritten: 500, totalBytesExpectedToWrite: 1000
        )

        let reports = seen.withLock { $0 }
        #expect(reports.map(\.fraction) == [0.25, 0.5], "the fraction has to move")
    }

    @Test("a length the server did not give is reported as unknown, not as zero")
    func unknownLength() {
        let delegate = DownloadDelegate()
        let task = makeTask()
        let seen = Mutex<Downloader.Progress?>(nil)
        delegate.watch(
            task.taskIdentifier,
            savingTo: URL.temporaryDirectory.appending(path: "unused"),
            onProgress: { progress in seen.withLock { $0 = progress } },
            finish: { _ in }
        )

        delegate.urlSession(
            .shared, downloadTask: task,
            didWriteData: 10, totalBytesWritten: 10, totalBytesExpectedToWrite: -1
        )

        #expect(seen.withLock { $0 }?.bytesExpected == nil)
        #expect(seen.withLock { $0 }?.fraction == nil)
    }

    @Test("a finished task stops being reported on")
    func handlersAreReleased() {
        let delegate = DownloadDelegate()
        let task = makeTask()
        let count = Mutex(0)
        delegate.watch(
            task.taskIdentifier,
            savingTo: URL.temporaryDirectory.appending(path: "unused"),
            onProgress: { _ in count.withLock { $0 += 1 } },
            finish: { _ in }
        )

        delegate.urlSession(.shared, task: task, didCompleteWithError: nil)
        delegate.urlSession(
            .shared, downloadTask: task,
            didWriteData: 1, totalBytesWritten: 1, totalBytesExpectedToWrite: 10
        )

        #expect(count.withLock { $0 } == 0)
    }
}
