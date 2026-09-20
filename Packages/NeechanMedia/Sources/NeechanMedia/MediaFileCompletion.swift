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
        let session = session ?? PlaybackSession.shared
        var headers = ["User-Agent": UserAgent.current]
        if let referer { headers["Referer"] = referer.absoluteString }

        // Off the calling actor: the reader blocks by design, and the calls
        // below are the only ones in the app allowed to make it fetch.
        let assembled = await Task.detached(priority: .utility) { () -> URL? in
            // The store remembers a file's size only once it has kept a piece
            // of it. No size, no pieces, no head start: a plain download is
            // simpler and reads the file in order. Decided before the reader
            // is asked anything, because asking it the size now fetches the
            // first block, which would count as a piece.
            guard store.length(for: url) != nil else { return nil }
            let reader = MediaRangeReader(
                url: url, headers: headers, session: session, store: store
            )
            guard let total = reader.length(), total > 0 else { return nil }
            let missing = store.missingBlocks(for: url, total: total)
            // Nothing held and everything missing means there is no head start
            // here; a plain download is simpler and reads the file in order.
            guard missing.count < store.blockCount(forTotal: total) else { return nil }

            let blocks = store.blockCount(forTotal: total)
            // What is already on disk counts as received: the reader is waiting
            // for a file, not for a download, and saying "10%" about a clip that
            // is nine tenths here would be a lie in the unhelpful direction.
            var done = blocks - missing.count
            onProgress?(bytesFor(blocks: done, of: total, blockSize: store.blockSize), total)

            for index in missing {
                // Reading one byte inside a block is enough to fetch and keep
                // the whole of it, which is how playback fills the store too.
                var byte: UInt8 = 0
                let offset = Int64(index) * Int64(store.blockSize)
                let read = withUnsafeMutablePointer(to: &byte) {
                    reader.read(into: $0, at: offset, count: 1)
                }
                guard read > 0 else { return nil }
                done += 1
                onProgress?(bytesFor(blocks: done, of: total, blockSize: store.blockSize), total)
            }
            return try? store.assemble(for: url)
        }.value

        guard let assembled else { return nil }
        // The pieces have served their purpose once the file is whole.
        guard let adopted = try? await cache.adopt(fileAt: assembled, for: url) else {
            try? FileManager.default.removeItem(at: assembled)
            return nil
        }
        store.remove(url)
        return adopted
    }

    /// How many bytes `blocks` whole blocks come to, never more than the file.
    private static func bytesFor(blocks: Int, of total: Int64, blockSize: Int) -> Int64 {
        min(total, Int64(blocks) * Int64(blockSize))
    }
}
