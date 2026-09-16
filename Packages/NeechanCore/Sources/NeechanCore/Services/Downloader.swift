import Foundation
import NeechanAPI

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
    /// An agent for this downloader alone, or nil to follow `UserAgent`.
    private let overriddenUserAgent: String?

    /// Read per request, not captured: the device's own agent is adopted after
    /// this object exists.
    private var userAgent: String { overriddenUserAgent ?? UserAgent.current }

    public init(
        session: URLSession? = nil,
        userAgent: String? = nil
    ) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
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

        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DownloadError.badStatus(http.statusCode)
        }

        let expected = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)
        FileManager.default.createFile(atPath: destination.path, contents: nil)

        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        // Buffered rather than byte-by-byte: a 20 MB WebM is millions of writes
        // otherwise.
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        var received: Int64 = 0

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                onProgress?(Progress(bytesReceived: received, bytesExpected: expected))
            }
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: destination)
                throw DownloadError.cancelled
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
        }
        onProgress?(Progress(bytesReceived: received, bytesExpected: expected))
        return destination
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
            throw DownloadError.badStatus(http.statusCode)
        }
        return data
    }
}
