import Foundation
import NeechanAPI
import os

/// Fetches the bytes of a media file.
///
/// A protocol so saving a thread offline can be tested without a network, and
/// so a caller can substitute a cache.
public protocol MediaFetching: Sendable {
    func data(_ url: URL, referer: URL?) async throws -> Data
}

/// Fetching a file to disk, reporting how far it has got.
///
/// Separate from `MediaFetching`, which reads small files into memory: this is
/// what the gallery saves and shares with, and what the progress capsule reads.
public protocol MediaDownloading: Sendable {
    func download(
        _ url: URL,
        referer: URL?,
        onProgress: (@Sendable (Downloader.Progress) -> Void)?
    ) async throws -> URL
}

extension Downloader: MediaFetching {}
extension Downloader: MediaDownloading {}

/// Fetches media files to disk.
///
/// Separate from `ImageLoader`, which caches decoded thumbnails in memory: this
/// writes the original bytes, which is what saving and sharing need.
public actor Downloader {
    /// How far a download has got.
    public struct Progress: Sendable, Equatable {
        public let bytesReceived: Int64
        /// Total size, or nil when the server did not say.
        public let bytesExpected: Int64?

        public var fraction: Double? {
            guard let bytesExpected, bytesExpected > 0 else { return nil }
            return min(1, Double(bytesReceived) / Double(bytesExpected))
        }

        public init(bytesReceived: Int64, bytesExpected: Int64?) {
            self.bytesReceived = bytesReceived
            self.bytesExpected = bytesExpected
        }
    }

    public enum DownloadError: Error, CustomStringConvertible {
        case badStatus(Int)
        case cancelled

        public var description: String {
            switch self {
            case .badStatus(let code): "The server answered with status \(code)."
            case .cancelled: "The download was cancelled."
            }
        }
    }

    private let session: URLSession
    /// Runs the downloads and reports how far each has got.
    private let downloads: DownloadDelegate
    /// An agent for this downloader alone, or nil to follow `UserAgent`.
    private let overriddenUserAgent: String?

    /// Read per request, not captured: the device's own agent is adopted after
    /// this object exists.
    private var userAgent: String { overriddenUserAgent ?? UserAgent.current }

    /// - Parameter configuration: the session's configuration. Taken instead of
    ///   a whole session because the session has to be built around this
    ///   downloader's own delegate, which is where progress comes from.
    public init(
        configuration: URLSessionConfiguration? = nil,
        userAgent: String? = nil
    ) {
        let configuration = configuration ?? {
            let configuration = URLSessionConfiguration.default
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            // Media files are large and the reader is waiting on one of them,
            // not six; more sockets to the same host would only make each
            // slower and hold the radio at full power for longer.
            configuration.httpMaximumConnectionsPerHost = 2
            return configuration
        }()
        let downloads = DownloadDelegate()
        self.downloads = downloads
        self.session = URLSession(
            configuration: configuration, delegate: downloads, delegateQueue: nil
        )
        self.overriddenUserAgent = userAgent
    }

    /// Downloads `url` to a temporary file and returns where it landed.
    ///
    /// The caller owns the file and must move or delete it.
    public func download(
        _ url: URL,
        referer: URL? = nil,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }

        // A download task rather than the byte sequence. `URLSession.bytes`
        // yields one `UInt8` at a time, so a 20 MB clip cost twenty million
        // iterations of an async sequence, twenty million appends and twenty
        // million cancellation checks: seconds of a core, for a file the system
        // will happily write to disk itself.
        //
        // Driven entirely through the session's delegate, and deliberately
        // carrying no completion handler: `didWriteData` is the only place the
        // system says how many bytes have landed, it reaches the session's
        // delegate alone, and a task built with a completion handler is never
        // sent it. Three other shapes were tried and each left the capsule stuck
        // on one number for a whole download — a task-scoped delegate, which the
        // async form of `download` never calls; the task's own `progress`, whose
        // fraction never leaves its first value; and a completion handler, which
        // reports nothing at all.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)
        let running = RunningDownload()

        let file: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<URL, any Error>) in
                let task = session.downloadTask(with: request)
                downloads.watch(
                    task.taskIdentifier,
                    savingTo: destination,
                    onProgress: onProgress
                ) { result in
                    continuation.resume(with: result)
                }
                running.begin(task)
                task.resume()
            }
        } onCancel: {
            running.cancel()
        }

        // One last report, from the file that actually landed, so a finished
        // download never sits next to a capsule reading 98%.
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size])
        let received = (size as? NSNumber)?.int64Value ?? 0
        onProgress?(Progress(bytesReceived: received, bytesExpected: received))
        return file
    }

    /// Downloads straight into memory. For small files only.
    public func data(_ url: URL, referer: URL? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            Self.logRefusal(of: request, status: http.statusCode)
            throw DownloadError.badStatus(http.statusCode)
        }
        return data
    }

    static let log = Logger(subsystem: Signposts.subsystem, category: "download")

    /// One line saying what was asked for, as whom, and what came back.
    ///
    /// A 403 from a media host is nearly always about the request's headers
    /// rather than the file, and the error the reader sees carries only the
    /// number. This is the line to look at.
    static func logRefusal(of request: URLRequest, status: Int) {
        log.error(
            """
            refused with \(status, privacy: .public): \
            \(request.url?.host() ?? "?", privacy: .public)\(request.url?.path() ?? "", privacy: .public), \
            referer \(request.value(forHTTPHeaderField: "Referer") ?? "none", privacy: .public), \
            agent \(request.value(forHTTPHeaderField: "User-Agent")?.prefix(40) ?? "default", privacy: .public)
            """
        )
    }
}

/// Holds the download in flight, so it can be cancelled.
///
/// `URLSessionDownloadTask` is not `Sendable`, and the two things that touch it
/// — starting the download and cancelling it — can happen on different threads,
/// so access is locked rather than assumed.
private final class RunningDownload: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?

    func begin(_ task: URLSessionDownloadTask) {
        lock.withLock { self.task = task }
    }

    func cancel() {
        let task = lock.withLock { self.task }
        task?.cancel()
    }
}

/// Runs the app's downloads and says how far each has got.
///
/// Keyed by task, because one downloader serves the whole app.
final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct Waiter {
        let destination: URL
        let onProgress: (@Sendable (Downloader.Progress) -> Void)?
        let finish: @Sendable (Result<URL, any Error>) -> Void
    }

    private let lock = NSLock()
    private var waiters: [Int: Waiter] = [:]

    func watch(
        _ taskIdentifier: Int,
        savingTo destination: URL,
        onProgress: (@Sendable (Downloader.Progress) -> Void)?,
        finish: @escaping @Sendable (Result<URL, any Error>) -> Void
    ) {
        lock.withLock {
            waiters[taskIdentifier] = Waiter(
                destination: destination, onProgress: onProgress, finish: finish
            )
        }
    }

    /// Removes and returns a waiter, so one download is finished exactly once: a
    /// task that produced a file also reports completion afterwards.
    private func take(_ taskIdentifier: Int) -> Waiter? {
        lock.withLock { waiters.removeValue(forKey: taskIdentifier) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let waiter = lock.withLock { waiters[downloadTask.taskIdentifier] }
        waiter?.onProgress?(
            Downloader.Progress(
                bytesReceived: totalBytesWritten,
                bytesExpected: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
            )
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let waiter = take(downloadTask.taskIdentifier) else { return }

        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode)
        {
            if let request = downloadTask.originalRequest {
                Downloader.logRefusal(of: request, status: http.statusCode)
            }
            waiter.finish(.failure(Downloader.DownloadError.badStatus(http.statusCode)))
            return
        }
        do {
            // Moved before returning: the system deletes what it handed over as
            // soon as this call is done with it.
            try? FileManager.default.removeItem(at: waiter.destination)
            try FileManager.default.moveItem(at: location, to: waiter.destination)
            waiter.finish(.success(waiter.destination))
        } catch {
            waiter.finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        // Gone already means the file arrived and has been handed over.
        guard let waiter = take(task.taskIdentifier) else { return }

        if let error {
            if (error as? URLError)?.code == .cancelled {
                waiter.finish(.failure(Downloader.DownloadError.cancelled))
            } else {
                waiter.finish(.failure(error))
            }
        } else {
            waiter.finish(.failure(Downloader.DownloadError.badStatus(-1)))
        }
    }
}
