import Foundation
import NeechanAPI

/// Turns the pieces of a part-watched file into the whole thing, fetching only
/// what is missing.
///
/// Watching a clip leaves its blocks on disk. Saving or sharing it then needs
/// one file, and this is what makes that cost the remainder rather than the
/// lot: watch a clip through and saving it costs nothing at all.
public enum MediaFileCompletion {
    /// Fills in whatever is missing and moves the result into the media cache.
    ///
    /// - Returns: where the whole file now lives, or nil when there is nothing
    ///   on disk to build on and the caller should simply download it.
    /// - Parameter onProgress: how far the fill-in has got, counting what was
    ///   already on disk as received, as `(bytes so far, bytes in all)`. Raw
    ///   numbers rather than a progress type: `Downloader` lives in NeechanCore,
    ///   which this package does not depend on, and the caller that has both is
    ///   the one place that can join them. Filling in is often most of a save — a
    ///   clip watched to the end leaves nearly all of itself in the store — and
    ///   without this the capsule sat at nothing until the whole thing was
    ///   suddenly done.
    public static func wholeFile(
        for url: URL,
        referer: URL?,
        cache: MediaCache = .shared,
        store: MediaBlockStore = .shared,
        session: URLSession? = nil,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async -> URL? {
        // The store remembers a file's size only once it has kept a piece of
        // it. No size, no pieces, no head start: a plain download is simpler
        // and reads the file in order. Decided from the store rather than the
        // reader, because asking the reader fetches the first block, which
        // would itself count as a piece.
        guard let total = store.length(for: url), total > 0 else { return nil }
        let blocks = store.blockCount(forTotal: total)
        // Nothing held and everything missing means there is no head start
        // here; a plain download is simpler and reads the file in order.
        guard store.missingBlocks(for: url, total: total).count < blocks else { return nil }

        // Blocks on the way in, bytes on the way out: the capsule above this
        // counts bytes, and only here is the block size known.
        let blockSize = store.blockSize
        var report: (@Sendable (Int, Int) -> Void)?
        if let onProgress {
            report = { done, _ in
                onProgress(bytesFor(blocks: done, of: total, blockSize: blockSize), total)
            }
        }

        let filled = await fillBlocks(
            for: url, referer: referer, store: store, session: session, onProgress: report
        )
        guard filled, let assembled = try? store.assemble(for: url) else { return nil }

        // The pieces have served their purpose once the file is whole.
        guard let adopted = try? await cache.adopt(fileAt: assembled, for: url) else {
            try? FileManager.default.removeItem(at: assembled)
            return nil
        }
        store.remove(url)
        return adopted
    }

    /// Fetches whatever of this file is not on disk yet, and leaves it there.
    ///
    /// The half of completing a file that does not turn it into one. Playback
    /// reads the blocks where they lie, so a clip being watched can have the
    /// rest of itself fetched underneath it and pick the pieces up for free —
    /// but only as long as nobody assembles them and takes them away, which is
    /// why that half belongs to `wholeFile` and not here.
    ///
    /// - Returns: whether the file is now whole in the store.
    /// - Parameter onProgress: `(blocks here, blocks in all)`, counting what was
    ///   already on disk as done. Blocks rather than bytes because the callers
    ///   want different things of them, and only they know which.
    public static func fillBlocks(
        for url: URL,
        referer: URL?,
        store: MediaBlockStore = .shared,
        session: URLSession? = nil,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> Bool {
        let session = session ?? PlaybackSession.shared
        var headers = ["User-Agent": UserAgent.current]
        if let referer { headers["Referer"] = referer.absoluteString }

        // Off the calling actor: the reader blocks by design, and the calls
        // below are the only ones in the app allowed to make it fetch.
        return await Task.detached(priority: .utility) { () -> Bool in
            let reader = MediaRangeReader(
                url: url, headers: headers, session: session, store: store
            )
            guard let total = reader.length(), total > 0 else { return false }

            let blocks = store.blockCount(forTotal: total)
            let missing = store.missingBlocks(for: url, total: total)
            // What is already on disk counts as done: the reader is waiting for
            // a file, not for a download, and saying "10%" about a clip that is
            // nine tenths here would be a lie in the unhelpful direction.
            var done = blocks - missing.count
            onProgress?(done, blocks)

            for index in missing {
                if Task.isCancelled { return false }
                // Reading one byte inside a block is enough to fetch and keep
                // the whole of it, which is how playback fills the store too.
                // The *last* byte, not the first: asking the length already
                // fetched byte zero and the reader keeps it as its window, so a
                // read at the start of block zero would be served from there and
                // the block never written down.
                let start = Int64(index) * Int64(store.blockSize)
                let offset = min(start + Int64(store.blockSize) - 1, total - 1)
                var byte: UInt8 = 0
                let read = withUnsafeMutablePointer(to: &byte) {
                    reader.read(into: $0, at: offset, count: 1)
                }
                // A server that ignores `Range` answers with the whole body,
                // which the reader refuses to keep as a block. Give up rather
                // than pulling the file over and over.
                guard read > 0, store.block(index, for: url) != nil else { return false }
                done += 1
                onProgress?(done, blocks)
            }
            return true
        }.value
    }

    /// How many bytes `blocks` whole blocks come to, never more than the file.
    private static func bytesFor(blocks: Int, of total: Int64, blockSize: Int) -> Int64 {
        min(total, Int64(blocks) * Int64(blockSize))
    }
}
