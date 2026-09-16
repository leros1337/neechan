import Foundation
import NeechanCore
import NeechanMedia

/// A remote media file, brought onto the device before it is used.
///
/// Video used to be handed to the player as a URL and fetched by the engine's
/// own HTTP client. Cloudflare on `2ch.life` refuses that client — it carries
/// neither the browser-check cookie nor Apple's TLS stack — with a 403 the
/// engine reports as a plain playback failure, while the thread's JSON kept
/// loading through URLSession beside it. Fetching through the app's downloader
/// puts video on the same footing as images, which have always been cached
/// this way, and makes a saved or shared clip a copy rather than a second
/// download.
enum LocalMediaFile {
    /// The file for `url`, from the cache or freshly downloaded into it.
    ///
    /// - Parameter onProgress: how far a download has got, when one is needed.
    ///   Not called for a cache hit.
    static func resolve(
        _ url: URL,
        referer: URL?,
        downloader: any MediaDownloading,
        cache: MediaCache = .shared,
        onProgress: (@Sendable (Downloader.Progress) -> Void)? = nil
    ) async throws -> URL {
        if let cached = await cache.cachedFile(for: url) {
            return cached
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
}
