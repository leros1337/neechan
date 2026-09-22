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
    /// How many blocks to fetch ahead of the one being read.
    ///
    /// Zero for a caller that reads a file straight through, which is already
    /// as far ahead as it can be. Playback sets it, because a demuxer that
    /// only fetches the piece it needs stops dead at every block boundary: one
    /// round trip, during which nothing is decoded and nothing is shown.
    /// Fetching the next few while the current one is being read means they
    /// are on disk by the time they are wanted.
    private let readAheadBlocks: Int

    private let lock = NSLock()
    /// The request being waited on, if any, so it can be given up.
    private let inFlight = Mutex<URLSessionDataTask?>(nil)
    /// Blocks being fetched ahead, by index, so the same one is not asked for
    /// twice and all of them can be dropped at once.
    private let readingAhead = Mutex<[Int: URLSessionDataTask]>([:])
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
        blockSize: Int? = nil,
        readAheadBlocks: Int = 0
    ) {
        self.readAheadBlocks = max(0, readAheadBlocks)
        self.url = url
        self.headers = headers
        self.session = session
        self.store = store
        self.blockSize = max(1, blockSize ?? store?.blockSize ?? MediaBlockStore.defaultBlockSize)
    }

    /// Set once nothing that this reader could fetch is wanted any more.
    private let isGivenUp = Mutex(false)

    /// True once `giveUp()` has been called.
    var wasGivenUp: Bool { isGivenUp.withLock { $0 } }

    /// Says that nothing this reader could fetch is wanted any more.
    ///
    /// Every read from here on fails at once, without touching the network,
    /// and whatever is in flight is cancelled so the connection it held goes
    /// to the clip that is now on screen. For a clip swiped away from while
    /// it was still opening, this is the only lever: until the file has
    /// opened, nothing else has a handle on the read that is waiting.
    func giveUp() {
        isGivenUp.withLock { $0 = true }
        abandonInFlightRequest()
    }

    /// Gives up whatever request is in flight.
    ///
    /// The read that was waiting on it comes back empty-handed, which its
    /// caller treats as a failure and retries. For a seek that is right: the
    /// bytes being waited for are no longer the ones wanted.
    func abandonInFlightRequest() {
        inFlight.withLock { task in
            task?.cancel()
            task = nil
        }
        // Whatever was being fetched ahead was for where the file used to be.
        readingAhead.withLock { tasks in
            for task in tasks.values { task.cancel() }
            tasks.removeAll()
        }
    }

    /// The file's size, or nil when it is not known and cannot be asked for.
    ///
    /// Answered from the store when the file has been read before, so a clip
    /// already on disk can be opened and scrubbed with no network at all.
    func length() -> Int64? {
        if let remembered = knownLength() { return remembered }
        if wasGivenUp { return nil }
        // The answer to any ranged request carries the total, and the first
        // block is what will be asked for next anyway. Asking for one byte
        // first cost a whole round trip per clip, and on a connection already
        // carrying other clips' pieces that round trip queued for seconds.
        _ = loadBlock(containing: 0)
        return lock.withLock { totalLength }
    }

    /// Copies up to `count` bytes from `offset` into `buffer`.
    ///
    /// - Returns: how many bytes were copied, zero at the end of the file, or
    ///   -1 when the read could not be made at all. A read is served from one
    ///   block, so it can return less than asked for; the decoder expects that.
    func read(into buffer: UnsafeMutablePointer<UInt8>, at offset: Int64, count: Int) -> Int {
        guard count > 0 else { return 0 }
        if wasGivenUp { return -1 }
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
            startReadingAhead(after: index)
            return true
        }

        startReadingAhead(after: index)
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
    /// Fetches the next few blocks in the background, so they are already on
    /// disk when the demuxer reaches them.
    ///
    /// Nothing waits for these. A block that does not arrive in time is
    /// fetched the slow way, exactly as it would have been.
    private func startReadingAhead(after index: Int) {
        guard readAheadBlocks > 0, let store, let total = knownLength() else { return }
        let blocks = store.blockCount(forTotal: total)

        for next in (index + 1)...(index + readAheadBlocks) where next < blocks {
            let start = Int64(next) * Int64(blockSize)
            guard start < total else { break }
            // Already here, or already on the way.
            guard store.block(next, for: url) == nil else { continue }
            let isNew = readingAhead.withLock { $0[next] == nil }
            guard isNew else { continue }

            var request = URLRequest(url: url)
            for (name, value) in headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
            let last = min(start + Int64(blockSize) - 1, total - 1)
            request.setValue("bytes=\(start)-\(last)", forHTTPHeaderField: "Range")

            let task = session.dataTask(with: request) { [weak self] data, response, _ in
                guard let self else { return }
                self.readingAhead.withLock { $0[next] = nil }
                guard let data, !data.isEmpty,
                      let http = response as? HTTPURLResponse, http.statusCode == 206
                else { return }
                self.keep(data, asBlock: next, from: start)
            }
            readingAhead.withLock { $0[next] = task }
            task.resume()
        }
    }

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
        if wasGivenUp { return nil }
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

        // Kept so a reader that is no longer wanted can be let go of without
        // waiting for the server. A seek arriving while this is in flight was
        // otherwise answered only once the bytes turned up, seconds after the
        // reader let go of the scrubber.
        inFlight.withLock { current in
            current?.cancel()
            current = task
        }
        defer { inFlight.withLock { $0 = nil } }

        task.resume()
        let started = ContinuousClock.now
        done.wait()
        let took = ContinuousClock.now - started

        // Cancelled by `giveUp()` while waiting: not a failure to retry.
        if wasGivenUp { return nil }

        guard let result = outcome.withLock({ $0 }), !result.data.isEmpty else {
            MediaLog.reader.error(
                """
                nothing came back for \(count, privacy: .public) bytes at \
                \(offset, privacy: .public) after \
                \(took.seconds, format: .fixed(precision: 2), privacy: .public)s
                """
            )
            return nil
        }

        MediaLog.reader.debug(
            """
            fetched \(result.data.count / 1024, privacy: .public) KB at \
            \(offset, privacy: .public) in \
            \(took.seconds, format: .fixed(precision: 2), privacy: .public)s \
            (\(Int(Double(result.data.count) / 1024 / max(took.seconds, 0.001)), privacy: .public) KB/s)
            """
        )
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
