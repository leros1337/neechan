import Foundation
import NeechanCore
import NeechanMedia

/// A remote media file, brought onto the device whole.
///
/// Video is played by streaming it, which leaves its pieces on disk. Saving or
/// sharing needs one file rather than pieces, and that is what this is for: it
/// fills in whatever is missing and hands back the whole thing, so a clip
/// watched through costs nothing to save.
///
/// Two entry points, because ownership differs and getting it wrong deletes the
/// cache: `resolve` lends the cache's own file, `exportCopy` gives away a copy.
enum LocalMediaFile {
    /// The cache's own file for `url`, fetching whatever it takes to have one.
    ///
    /// **The caller must not delete or move the result.** It is the cache entry
    /// itself, and playback reads it in place.
    ///
    /// - Parameter onProgress: how far getting the file has got — whether that
    ///   means filling in the pieces left by watching it or downloading the lot.
    ///   Not called for a cache hit, which is already instant.
    static func resolve(
        _ url: URL,
        referer: URL?,
        downloader: any MediaDownloading,
        cache: MediaCache = .shared,
        blocks: MediaBlockStore = .shared,
        onProgress: (@Sendable (Downloader.Progress) -> Void)? = nil
    ) async throws -> URL {
        if let cached = await cache.cachedFile(for: url) {
            return cached
        }
        // Watched pieces are a head start: only the rest is fetched.
        if let completed = await MediaFileCompletion.wholeFile(
            for: url, referer: referer, cache: cache, store: blocks,
            onProgress: { received, total in
                onProgress?(Downloader.Progress(bytesReceived: received, bytesExpected: total))
            }
        ) {
            return completed
        }
        let downloaded = try await downloader.download(url, referer: referer, onProgress: onProgress)
        do {
            return try await cache.adopt(fileAt: downloaded, for: url)
        } catch {
            // A cache that cannot take the file is not a reason to lose it: play
            // it from where it landed and let the temporary directory clean up.
            return downloaded
        }
    }

    /// A copy of the whole file, for a caller that will consume and delete it.
    ///
    /// Saving does both: it collects what it is given and removes it afterwards,
    /// and converting a WebM deletes the source once the MP4 exists. Handing
    /// either of those the cache entry would delete the cache entry. On this
    /// file system a copy of a file that is not written to costs almost nothing.
    static func exportCopy(
        _ url: URL,
        referer: URL?,
        downloader: any MediaDownloading,
        cache: MediaCache = .shared,
        blocks: MediaBlockStore = .shared,
        onProgress: (@Sendable (Downloader.Progress) -> Void)? = nil
    ) async throws -> URL {
        let file = try await resolve(
            url,
            referer: referer,
            downloader: downloader,
            cache: cache,
            blocks: blocks,
            onProgress: onProgress
        )
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(file.pathExtension)
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: file, to: copy)
        return copy
    }
}
