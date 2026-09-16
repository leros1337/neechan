import Foundation
import Synchronization

/// Reads a remote file in pieces, on demand, through the app's own networking.
///
/// This exists so a video can start playing before it has finished arriving.
/// The player's own HTTP client cannot be used against 2ch: Cloudflare answers
/// it with 403, carrying as it does neither the browser-check cookie nor
/// Apple's TLS stack. Reading here instead keeps the bytes on `URLSession`,
/// where they are let through, and hands the decoder only the part it is asking
/// for.
///
/// Deliberately blocking. It is driven from the decoder's own demuxing thread,
/// which expects to be held up while a read completes, the way reading a file
/// would hold it up.
final class MediaRangeReader: @unchecked Sendable {
    /// How much is fetched for a read that misses.
    ///
    /// The decoder asks in small pieces, and a request each time would be
    /// thousands of them for one clip; a megabyte is roughly one request per
    /// second of a board video and keeps a seek cheap.
    static let chunkSize = 1 << 20

    private let url: URL
    private let headers: [String: String]
    private let session: URLSession
    private let chunkSize: Int

    private let lock = NSLock()
    /// Total size, once the server has told us. Nil until the first read.
    private var totalLength: Int64?
    /// The piece most recently fetched, kept so consecutive reads inside it
    /// cost nothing.
    private var windowOffset: Int64 = 0
    private var window = Data()

    init(
        url: URL,
        headers: [String: String] = [:],
        session: URLSession,
        chunkSize: Int = MediaRangeReader.chunkSize
    ) {
        self.url = url
        self.headers = headers
        self.session = session
        self.chunkSize = max(64 << 10, chunkSize)
    }

    /// The file's size, or nil when it is not known yet and cannot be asked for.
    func length() -> Int64? {
        if let known = lock.withLock({ totalLength }) { return known }
        // Asking for one byte is enough: the answer carries the total.
        _ = fetch(from: 0, count: 1)
        return lock.withLock { totalLength }
    }

    /// Copies up to `count` bytes from `offset` into `buffer`.
    ///
    /// - Returns: how many bytes were copied, zero at the end of the file, or
    ///   -1 when the read could not be made at all.
    func read(into buffer: UnsafeMutablePointer<UInt8>, at offset: Int64, count: Int) -> Int {
        guard count > 0 else { return 0 }
        if let total = lock.withLock({ totalLength }), offset >= total { return 0 }

        if let copied = copyFromWindow(into: buffer, at: offset, count: count) {
            return copied
        }
        guard fetch(from: offset, count: max(count, chunkSize)) else { return -1 }
        if let copied = copyFromWindow(into: buffer, at: offset, count: count) {
            return copied
        }
        // A fetch that produced nothing at this offset is the end of the file.
        return 0
    }

    /// Serves a read from the piece already in hand, if it covers the offset.
    private func copyFromWindow(
        into buffer: UnsafeMutablePointer<UInt8>,
        at offset: Int64,
        count: Int
    ) -> Int? {
        lock.withLock {
            guard !window.isEmpty else { return nil }
            let start = offset - windowOffset
            guard start >= 0, start < Int64(window.count) else { return nil }

            let available = window.count - Int(start)
            let copied = min(count, available)
            window.withUnsafeBytes { bytes in
                let base = bytes.bindMemory(to: UInt8.self).baseAddress! + Int(start)
                buffer.update(from: base, count: copied)
            }
            return copied
        }
    }

    /// Fetches a range and keeps it as the current piece.
    @discardableResult
    private func fetch(from offset: Int64, count: Int) -> Bool {
        var request = URLRequest(url: url)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let last = offset + Int64(count) - 1
        request.setValue("bytes=\(offset)-\(last)", forHTTPHeaderField: "Range")

        let outcome = Mutex<(data: Data, total: Int64?)?>(nil)
        let done = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, _ in
            defer { done.signal() }
            guard
                let data,
                let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode)
            else { return }
            outcome.withLock { $0 = (data, Self.totalLength(of: http)) }
        }
        task.resume()
        done.wait()

        guard let result = outcome.withLock({ $0 }), !result.data.isEmpty else { return false }
        lock.withLock {
            windowOffset = offset
            window = result.data
            if let total = result.total { totalLength = total }
        }
        return true
    }

    /// The file's total size, from whichever header carries it.
    ///
    /// A ranged answer states it after the slash in `Content-Range`. A server
    /// that ignored the range answers 200 with the whole body, and then the
    /// length is simply how much it sent.
    static func totalLength(of response: HTTPURLResponse) -> Int64? {
        if let range = response.value(forHTTPHeaderField: "Content-Range"),
           let slash = range.lastIndex(of: "/")
        {
            let total = range[range.index(after: slash)...]
            if total != "*", let value = Int64(total) { return value }
        }
        guard response.statusCode == 200, response.expectedContentLength > 0 else { return nil }
        return response.expectedContentLength
    }
}
