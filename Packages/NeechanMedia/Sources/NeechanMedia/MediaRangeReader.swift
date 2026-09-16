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
/// Everything read is kept in a `MediaBlockStore`, so watching a clip a second
/// time, or seeking back over ground already watched, costs nothing.
///
/// Deliberately blocking. It is driven from the decoder's own demuxing thread,
/// which expects to be held up while a read completes, the way reading a file
/// would hold it up.
final class MediaRangeReader: @unchecked Sendable {
    private let url: URL
    private let headers: [String: String]
    private let session: URLSession
    /// Where fetched blocks are kept, or nil to keep nothing.
    private let store: MediaBlockStore?
    /// The size of one block, and so of one fetch.
    private let blockSize: Int

    private let lock = NSLock()
    /// Total size, once the server or the store has told us.
    private var totalLength: Int64?
    /// The block most recently read, kept in memory so the many small reads
    /// inside one block do not go back to disk.
    private var windowOffset: Int64 = 0
    private var window = Data()

    init(
        url: URL,
        headers: [String: String] = [:],
        session: URLSession,
        store: MediaBlockStore? = nil,
        blockSize: Int? = nil
    ) {
        self.url = url
        self.headers = headers
        self.session = session
        self.store = store
        self.blockSize = max(1, blockSize ?? store?.blockSize ?? MediaBlockStore.defaultBlockSize)
    }

    /// The file's size, or nil when it is not known and cannot be asked for.
    ///
    /// Answered from the store when the file has been read before, so a clip
    /// already on disk can be opened and scrubbed with no network at all.
    func length() -> Int64? {
        if let remembered = knownLength() { return remembered }
        // Asking for one byte is enough: the answer carries the total.
        _ = fetch(from: 0, count: 1)
        return lock.withLock { totalLength }
    }

    /// Copies up to `count` bytes from `offset` into `buffer`.
    ///
    /// - Returns: how many bytes were copied, zero at the end of the file, or
    ///   -1 when the read could not be made at all. A read is served from one
    ///   block, so it can return less than asked for; the decoder expects that.
    func read(into buffer: UnsafeMutablePointer<UInt8>, at offset: Int64, count: Int) -> Int {
        guard count > 0 else { return 0 }
        if let total = lock.withLock({ totalLength }), offset >= total { return 0 }

        if let copied = copyFromWindow(into: buffer, at: offset, count: count) {
            return copied
        }
        guard loadBlock(containing: offset) else { return -1 }
        if let copied = copyFromWindow(into: buffer, at: offset, count: count) {
            return copied
        }
        // A block that produced nothing at this offset is the end of the file.
        return 0
    }

    /// Serves a read from the block already in hand, if it covers the offset.
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

    /// Brings the block holding `offset` into memory, from the store when it is
    /// there and from the server when it is not.
    private func loadBlock(containing offset: Int64) -> Bool {
        let index = Int(offset / Int64(blockSize))
        let start = Int64(index) * Int64(blockSize)

        // Served only when it is exactly as long as that block should be. A
        // block written short, by a truncated answer or a process that died,
        // would otherwise be read back as though the file simply ended there.
        if let held = store?.block(index, for: url),
           let total = knownLength(),
           held.count == expectedLength(ofBlock: index, total: total)
        {
            lock.withLock {
                windowOffset = start
                window = held
            }
            return true
        }

        guard fetch(from: start, count: blockSize) != nil else { return false }
        // Read back what the fetch actually put in the window: a server that
        // ignored the range left the whole file there, starting at zero.
        let landed = lock.withLock { (offset: windowOffset, data: window) }
        if landed.offset == start {
            keep(landed.data, asBlock: index, from: start)
        }
        return true
    }

    /// Keeps a fetched block, when it is certain to be a whole one.
    ///
    /// A block is only stored once the total is known and the answer is exactly
    /// as long as that block should be. A short answer to a ranged request, or
    /// a server that ignored the range and sent the whole file, would otherwise
    /// be written down as a block and read back later as if it were complete.
    private func keep(_ data: Data, asBlock index: Int, from start: Int64) {
        guard let store, let total = knownLength() else { return }
        let expected = expectedLength(ofBlock: index, total: total)
        guard expected > 0, data.count == expected else { return }

        store.setLength(total, for: url)
        store.store(data, block: index, for: url)
    }

    /// How long block `index` is, given what the whole file weighs. Every block
    /// is a full one but the last.
    private func expectedLength(ofBlock index: Int, total: Int64) -> Int {
        let start = Int64(index) * Int64(blockSize)
        return Int(max(0, min(Int64(blockSize), total - start)))
    }

    /// The total, from this reader or from what the store was told last time.
    ///
    /// Never asks the server. A reader opened on a clip already on disk starts
    /// knowing nothing, and without this it could not tell a whole block from a
    /// short one, so it would refetch everything it already had.
    private func knownLength() -> Int64? {
        if let known = lock.withLock({ totalLength }) { return known }
        guard let remembered = store?.length(for: url) else { return nil }
        lock.withLock { totalLength = remembered }
        return remembered
    }

    /// Fetches a range and keeps it as the block in hand.
    @discardableResult
    private func fetch(from offset: Int64, count: Int) -> Data? {
        var request = URLRequest(url: url)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let last = offset + Int64(count) - 1
        request.setValue("bytes=\(offset)-\(last)", forHTTPHeaderField: "Range")

        let outcome = Mutex<(data: Data, total: Int64?, isRange: Bool)?>(nil)
        let done = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, _ in
            defer { done.signal() }
            guard
                let data,
                let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode)
            else { return }
            outcome.withLock {
                $0 = (data, Self.totalLength(of: http), http.statusCode == 206)
            }
        }
        task.resume()
        done.wait()

        guard let result = outcome.withLock({ $0 }), !result.data.isEmpty else { return nil }
        lock.withLock {
            // A server that ignored the range answered with the whole file, so
            // what came back starts at the beginning however far in we asked
            // for. Labelling it with the offset we wanted would serve the wrong
            // bytes from then on.
            windowOffset = result.isRange ? offset : 0
            window = result.data
            if let total = result.total { totalLength = total }
        }
        return result.data
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
